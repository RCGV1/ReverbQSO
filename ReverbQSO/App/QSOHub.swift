// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation

/// Owns concurrent calls and keeps microphone and receive audio on one selected QSO.
@MainActor
final class QSOHub: ObservableObject {
    @MainActor struct Entry: Identifiable {
        let id: UUID
        let callsign: String
        let service: EchoLinkConnectionService
        private let fallbackMode: EchoLinkNetworkMode
        private let modeProvider: @MainActor () -> EchoLinkNetworkMode?

        var station: Station? { service.session?.station ?? service.reconnectCandidate }
        var mode: EchoLinkNetworkMode { modeProvider() ?? fallbackMode }

        init(
            id: UUID,
            callsign: String,
            mode: EchoLinkNetworkMode,
            service: EchoLinkConnectionService,
            modeProvider: @escaping @MainActor () -> EchoLinkNetworkMode?
        ) {
            self.id = id
            self.callsign = callsign
            self.service = service
            self.fallbackMode = mode
            self.modeProvider = modeProvider
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var activeID: UUID?
    @Published var lastError: String?
    @Published var recordingError: String?

    private let primary: EchoLinkConnectionService
    private let connectOperation: @MainActor (EchoLinkConnectionService, Station) async -> Void
    private let disconnectOperation: @MainActor (EchoLinkConnectionService) async -> Void
    private let networkConfigurationProvider: @MainActor () -> EchoLinkProxyConfiguration
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var initialConnectionIDs: Set<UUID> = []
    private var connectedEntryIDs: Set<UUID> = []
    private var previousActiveIDs: [UUID: UUID] = [:]
    private var primarySubscription: AnyCancellable?
    var effectiveTransportProvider: ((String) -> EchoLinkEffectiveTransport?)?
    var configure: ((EchoLinkConnectionService, String) -> Void)?

    init(
        primary: EchoLinkConnectionService,
        networkConfigurationProvider: @escaping @MainActor () -> EchoLinkProxyConfiguration = {
            EchoLinkProxyConfiguration.load()
        },
        disconnectOperation: @escaping @MainActor (EchoLinkConnectionService) async -> Void = { service in
            await service.disconnect()
        },
        connectOperation: @escaping @MainActor (EchoLinkConnectionService, Station) async -> Void = { service, station in
            await service.connect(to: station)
        }
    ) {
        self.primary = primary
        self.networkConfigurationProvider = networkConfigurationProvider
        self.connectOperation = connectOperation
        self.disconnectOperation = disconnectOperation
        observeRecordingFailures(in: primary)
        primarySubscription = primary.$session.sink { [weak self, weak primary] session in
            guard let self, let primary, let session,
                  session.state == .connecting || session.state == .connected,
                  !self.entries.contains(where: { $0.service === primary }) else { return }
            Task { @MainActor [weak self, weak primary] in
                guard let self, let primary,
                      primary.session?.id == session.id,
                      !self.entries.contains(where: { $0.service === primary }) else { return }
                self.adoptExistingPrimary(as: primary.localCallsign)
            }
        }
    }

    var activeService: EchoLinkConnectionService {
        entries.first(where: { $0.id == activeID })?.service ?? primary
    }

    func service(for sessionID: UUID) -> EchoLinkConnectionService? {
        entries.first(where: { $0.service.session?.id == sessionID })?.service
    }

    func entry(for id: UUID) -> Entry? { entries.first(where: { $0.id == id }) }

    func adoptExistingPrimary(as callsign: String) {
        guard let session = primary.session,
              session.state == .connecting || session.state == .connected,
              !entries.contains(where: { $0.service === primary }) else { return }
        let id = UUID()
        let entry = Entry(
            id: id,
            callsign: callsign,
            mode: effectiveTransportProvider?(callsign)?.configuration.mode ?? networkConfigurationProvider().mode,
            service: primary,
            modeProvider: { [weak self] in
                self?.effectiveTransportProvider?(callsign)?.configuration.mode
                    ?? self?.networkConfigurationProvider().mode
            }
        )
        entries.append(entry)
        primary.pttPermission = { [weak self] in self?.activeID == id }
        observeSession(in: entry)
        if activeID == nil {
            select(id)
        } else {
            primary.setBackgroundMuted(true)
        }
    }

    func connect(to station: Station, as callsign: String, preservingEndpoint: Bool = false) async -> EchoLinkConnectionService {
        lastError = nil
        let configuredTransport = effectiveTransportProvider?(callsign)?.configuration ?? networkConfigurationProvider()
        guard configuredTransport.mode != .automatic else {
            lastError = "Sign in again to select an Automatic connection method."
            return EchoLinkConnectionService(networkConfigurationProvider: { configuredTransport })
        }
        // A new call replaces this account's ended presentation, not an active contact.
        for entry in entries where entry.callsign.caseInsensitiveCompare(callsign) == .orderedSame
            && !initialConnectionIDs.contains(entry.id)
            && !entry.service.isReconnecting
            && entry.service.session == nil {
            remove(entry.id)
        }
        if entries.contains(where: { $0.mode == .direct && (initialConnectionIDs.contains($0.id) || $0.service.isReconnecting
            || ($0.service.session != nil && $0.service.session?.state != .disconnected)) })
            && configuredTransport.mode == .direct {
            lastError = "Direct mode supports one active QSO because EchoLink requires UDP ports 5198 and 5199. Select Relay or sign in through a proxy before starting another QSO."
            return EchoLinkConnectionService(networkConfigurationProvider: { configuredTransport })
        }
        if entries.contains(where: { $0.callsign.caseInsensitiveCompare(callsign) == .orderedSame }) {
            lastError = "This callsign already has an active QSO. Select another signed-in callsign for a second QSO."
            return EchoLinkConnectionService(networkConfigurationProvider: { configuredTransport })
        }
        let usePrimary = primary.session == nil && !entries.contains(where: { $0.service === primary })
        let service: EchoLinkConnectionService
        let mode: EchoLinkNetworkMode
        if usePrimary {
            service = primary
            mode = configuredTransport.mode
        } else {
            mode = configuredTransport.mode
            service = EchoLinkConnectionService(networkConfigurationProvider: { configuredTransport })
        }

        service.authenticatedCallsign = callsign
        configure?(service, callsign)
        observeRecordingFailures(in: service)
        let id = UUID()
        let entry = Entry(id: id, callsign: callsign, mode: mode, service: service,
            modeProvider: { [weak self] in
                self?.effectiveTransportProvider?(callsign)?.configuration.mode
            })
        service.pttPermission = { [weak self] in
            guard let self, self.activeID == id else { return false }
            return !self.entries.contains { $0.id != id && $0.service.session?.isPTTActive == true }
        }
        previousActiveIDs[id] = activeID
        entries.append(entry)
        initialConnectionIDs.insert(id)
        observeSession(in: entry)
        select(id)
        let savedResolver = service.resolveStation
        if preservingEndpoint { service.resolveStation = nil }
        await connectOperation(service, station)
        if preservingEndpoint && !entries.contains(where: { $0.id != id && $0.service === service }) {
            service.resolveStation = savedResolver
        }
        guard entries.contains(where: { $0.id == id && $0.service === service }) else { return service }
        initialConnectionIDs.remove(id)
        refreshPresentation(for: id)
        if let error = service.error {
            lastError = error.localizedDescription
        }
        return service
    }

    func select(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        for entry in entries where entry.id != id {
            if entry.service.session?.isPTTActive == true {
                entry.service.sendPTT(active: false)
            }
        }
        activeID = id
        for entry in entries {
            entry.service.setBackgroundMuted(entry.id != id)
        }
    }

    /// Stop only this account's unfinished attempt when iOS expires its execution time.
    func cancelPendingConnection(as callsign: String, excluding existingEntryIDs: Set<UUID> = []) {
        for entry in entries where !existingEntryIDs.contains(entry.id)
            && entry.callsign.caseInsensitiveCompare(callsign) == .orderedSame {
            entry.service.cancelPendingConnection()
        }
    }

    func disconnectAll() async {
        // A captured service may be reused by a new entry while teardown is suspended.
        let capturedEntries = entries
        for entry in capturedEntries {
            guard entries.contains(where: { $0.id == entry.id && $0.service === entry.service }) else { continue }
            await disconnectOperation(entry.service)
            guard entries.contains(where: { $0.id == entry.id && $0.service === entry.service }) else { continue }
            remove(entry.id)
        }
    }

    func disconnect(callsign: String) async {
        for entry in entries where entry.callsign == callsign {
            await disconnectOperation(entry.service)
            if entry.service.session == nil && !entry.service.isReconnecting
                && entry.service.reconnectCandidate == nil {
                remove(entry.id)
            }
        }
    }

    private func observeRecordingFailures(in service: EchoLinkConnectionService) {
        service.onRecordingFailure = { [weak self] message in
            self?.recordingError = message
        }
    }

    private func observeSession(in entry: Entry) {
        let id = entry.id
        let service = entry.service
        subscriptions[id] = service.$session.combineLatest(service.$isReconnecting, service.$reconnectCandidate)
            .sink { [weak self, weak service] session, _, _ in
                guard let self, let service,
                      self.entries.contains(where: { $0.id == id && $0.service === service }) else { return }
                // Published sends before the property changes, including rapid connect/drop transitions.
                if session?.state == .connected {
                    self.connectedEntryIDs.insert(id)
                    self.previousActiveIDs.removeValue(forKey: id)
                }
                Task { @MainActor [weak self] in
                    self?.refreshPresentation(for: id)
                }
            }
    }

    private func refreshPresentation(for id: UUID) {
        guard let entry = entry(for: id) else { return }
        let service = entry.service
        guard !initialConnectionIDs.contains(id) else {
            objectWillChange.send()
            return
        }
        let failedInitialConnection = !connectedEntryIDs.contains(id)
            && service.session?.state != .connecting && !service.isReconnecting
        if failedInitialConnection {
            if let error = service.error { lastError = error.localizedDescription }
            remove(id)
        } else if service.session == nil && !service.isReconnecting && service.reconnectCandidate == nil {
            remove(id)
        } else {
            objectWillChange.send()
        }
    }

    private func remove(_ id: UUID) {
        guard let removed = entries.first(where: { $0.id == id }) else { return }
        let previousActiveID = previousActiveIDs.removeValue(forKey: id)
        removed.service.pttPermission = nil
        removed.service.setBackgroundMuted(false)
        entries.removeAll { $0.id == id }
        initialConnectionIDs.remove(id)
        connectedEntryIDs.remove(id)
        subscriptions.removeValue(forKey: id)
        if activeID == id {
            activeID = entries.first(where: { $0.id == previousActiveID })?.id ?? entries.last?.id
        }
        for entry in entries {
            entry.service.setBackgroundMuted(entry.id != activeID)
        }
    }
}
