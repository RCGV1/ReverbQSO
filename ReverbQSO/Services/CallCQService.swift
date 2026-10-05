// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine

@MainActor
protocol CallCQBackend {
    func waitForMatch(preferences: CallCQPreferences) async throws -> Station
    func cancel() async
}

@MainActor
final class CallCQService: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var state: CallCQState = .idle

    private var backend: (any CallCQBackend)?
    private let backendFactory: ((CallCQPreferences) async -> any CallCQBackend)?
    private var requestTask: Task<Station, Error>?
    private var cleanupTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(backend: any CallCQBackend) {
        self.backend = backend
        self.backendFactory = nil
    }

    init(backendFactory: @escaping (CallCQPreferences) async -> any CallCQBackend) {
        self.backend = nil
        self.backendFactory = backendFactory
    }

    func start(preferences: CallCQPreferences) async {
        guard state != .waiting else { return }
        generation &+= 1
        let requestGeneration = generation
        state = .waiting

        // CQ cancel is keyed only by callsign. Do not let its response race
        // a replacement register for the same account.
        await cleanupTask?.value
        guard requestGeneration == generation, state == .waiting else { return }

        let activeBackend: any CallCQBackend
        if let backendFactory {
            activeBackend = await backendFactory(preferences)
        } else {
            activeBackend = backend!
        }
        guard requestGeneration == generation, state == .waiting else {
            await activeBackend.cancel()
            return
        }
        backend = activeBackend
        let task = Task { try await activeBackend.waitForMatch(preferences: preferences) }
        requestTask = task
        do {
            let station = try await task.value
            guard requestGeneration == generation, !Task.isCancelled, state == .waiting else { return }
            state = .matched(station)
        } catch is CancellationError {
            if requestGeneration == generation, state == .waiting { state = .idle }
        } catch {
            if requestGeneration == generation, state == .waiting {
                state = .failed(error.localizedDescription)
            }
        }
        if requestGeneration == generation { requestTask = nil }
    }

    func cancel() async {
        generation &+= 1
        let oldRequest = requestTask
        let oldBackend = backend
        let predecessor = cleanupTask
        oldRequest?.cancel()
        requestTask = nil
        let cleanup = Task {
            await predecessor?.value
            await oldBackend?.cancel()
            _ = await oldRequest?.result
        }
        cleanupTask = cleanup
        state = .idle
        await cleanup.value
    }

    func reset() {
        guard state != .waiting else { return }
        state = .idle
    }
}

@MainActor
struct FailingCallCQBackend: CallCQBackend {
    let error: Error

    func waitForMatch(preferences: CallCQPreferences) async throws -> Station { throw error }
    func cancel() async {}
}

@MainActor
final class LiveCallCQBackend: CallCQBackend {
    private var registration: CallCQRegistration
    private let password: String
    private let directory: EchoLinkDirectoryService
    private let policy: CallAccessPolicy
    private let client: any CallCQClientProtocol
    private let pollDelay: Duration
    private let usesDirectSockets: Bool
    private var directSocketPair: DirectCQSocketPair?
    private var cancelled = false
    private var operationTask: Task<Station, Error>?

    init(registration: CallCQRegistration, password: String, directory: EchoLinkDirectoryService,
         policy: CallAccessPolicy, client: any CallCQClientProtocol = CallCQHTTPClient(),
         pollDelay: Duration = .seconds(10), usesDirectSockets: Bool = false) {
        self.registration = registration
        self.password = password
        self.directory = directory
        self.policy = policy
        self.client = client
        self.pollDelay = pollDelay
        self.usesDirectSockets = usesDirectSockets
    }

    func waitForMatch(preferences: CallCQPreferences) async throws -> Station {
        try Task.checkCancellation()
        // A backend replaced before its start task ran is retired permanently.
        // Retries use a fresh backend, coordinated by the directory service.
        guard !cancelled, operationTask == nil else { throw CancellationError() }
        let operation = Task { try await self.findMatch(preferences: preferences) }
        operationTask = operation
        defer { operationTask = nil }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func findMatch(preferences: CallCQPreferences) async throws -> Station {
        var availabilityRevision: UInt64?
        var registrationStarted = false
        do {
            try Task.checkCancellation()
            if usesDirectSockets {
                directSocketPair = try directory.reserveDirectCQSocketPair()
            }
            if !directory.isAvailableForCalls {
                let revision = directory.availabilityRevision &+ 1
                guard await directory.setAvailableForCalls(true) else {
                    throw directory.error ?? CallCQBackendError.transportUnavailable
                }
                availabilityRevision = revision
            }
            // Public proxy preferences may have no host. Availability recovery
            // can also replace the tunnel, so read its actual endpoint now.
            if let address = try await directory.currentCQProxyAddress() {
                registration = registration.replacingInternetAddress(address)
            }
            if let address = registration.internetAddress,
               !CallCQIPv4Resolver.isIPv4(address) {
                registration = registration.replacingInternetAddress(
                    try await CallCQIPv4Resolver.resolve(address)
                )
            }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            registrationStarted = true
            try await client.register(registration, password: password)
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            while !cancelled {
                try await Task.sleep(for: pollDelay)
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                switch try await client.find(callsign: registration.callsign, password: password) {
                case .waiting:
                    continue
                case .matched(let callsign, let internetAddress):
                    guard !cancelled else { throw CancellationError() }
                    let listed = directory.stations.first {
                        $0.callsign.caseInsensitiveCompare(callsign) == .orderedSame
                    }
                    var station = listed ?? Station(
                        callsign: callsign,
                        ipAddress: internetAddress,
                        type: Self.stationType(for: callsign)
                    )
                    station.ipAddress = internetAddress
                    if policy.rejection(for: station, direction: .outgoing, countryCode: station.callSignCountryCode) != nil {
                        throw CallCQBackendError.server("The matched station is blocked by Call Restrictions.")
                    }
                    // Remove the matched queue entry before handing the socket reservation to QSO.
                    await sendCleanupCancel(registered: registrationStarted, availabilityRevision: availabilityRevision)
                    registrationStarted = false
                    availabilityRevision = nil
                    try Task.checkCancellation()
                    guard !cancelled else { throw CancellationError() }
                    if let directSocketPair {
                        directory.holdMatchedCQSocketPair(directSocketPair)
                        self.directSocketPair = nil
                    }
                    return station
                }
            }
            throw CancellationError()
        } catch {
            cancelled = true
            directSocketPair?.close()
            directSocketPair = nil
            await sendCleanupCancel(registered: registrationStarted, availabilityRevision: availabilityRevision)
            throw error
        }
    }

    func cancel() async {
        cancelled = true
        let operation = operationTask
        operation?.cancel()
        // The operation owns cleanup, including a register or find already
        // in flight. Waiting here avoids duplicate and late callsign cancels.
        _ = await operation?.result
    }

    /// Cleanup must outlive cancellation of the request task that detected it.
    private func sendCleanupCancel(registered: Bool, availabilityRevision: UInt64?) async {
        let callsign = registration.callsign
        let localPassword = password
        let httpClient = client
        let directory = directory
        await Task {
            if registered { await httpClient.cancel(callsign: callsign, password: localPassword) }
            if let availabilityRevision, directory.availabilityRevision == availabilityRevision {
                _ = await directory.setAvailableForCalls(false)
            }
        }.value
    }

    private static func stationType(for callsign: String) -> Station.StationType {
        let normalized = callsign.uppercased()
        if normalized.hasSuffix("-L") { return .link }
        if normalized.hasSuffix("-R") { return .repeater }
        return normalized.hasPrefix("*") ? .conference : .user
    }
}
