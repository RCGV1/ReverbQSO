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
        requestTask?.cancel()
        requestTask = nil
        state = .idle
        await backend?.cancel()
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
        cancelled = false
        do {
            if usesDirectSockets {
                directSocketPair = try directory.reserveDirectCQSocketPair()
            }
            if let address = registration.internetAddress,
               !CallCQIPv4Resolver.isIPv4(address) {
                registration = registration.replacingInternetAddress(
                    try await CallCQIPv4Resolver.resolve(address)
                )
            }
            try await client.register(registration, password: password)
            guard !cancelled else {
                // A cancel can overtake an in-flight registration. Cancel once
                // more after registration completes so no late queue entry remains.
                await sendCleanupCancel()
                throw CancellationError()
            }
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
                    await sendCleanupCancel()
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
            await sendCleanupCancel()
            throw error
        }
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        directSocketPair?.close()
        directSocketPair = nil
        await sendCleanupCancel()
    }

    /// Cleanup must outlive cancellation of the request task that detected it.
    private func sendCleanupCancel() async {
        let callsign = registration.callsign
        let localPassword = password
        let httpClient = client
        await Task { await httpClient.cancel(callsign: callsign, password: localPassword) }.value
    }

    private static func stationType(for callsign: String) -> Station.StationType {
        let normalized = callsign.uppercased()
        if normalized.hasSuffix("-L") { return .link }
        if normalized.hasSuffix("-R") { return .repeater }
        return normalized.hasPrefix("*") ? .conference : .user
    }
}
