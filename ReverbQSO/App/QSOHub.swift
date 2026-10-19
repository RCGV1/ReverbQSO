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
    private let networkConfigurationProvider: @MainActor () -> EchoLinkProxyConfiguration
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var initialConnectionIDs: Set<UUID> = []
    private var primarySubscription: AnyCancellable?
    var effectiveTransportProvider: ((String) -> EchoLinkEffectiveTransport?)?
    var configure: ((EchoLinkConnectionService, String) -> Void)?

    init(
        primary: EchoLinkConnectionService,
        networkConfigurationProvider: @escaping @MainActor () -> EchoLinkProxyConfiguration = {
            EchoLinkProxyConfiguration.load()
        },
        connectOperation: @escaping @MainActor (EchoLinkConnectionService, Station) async -> Void = { service, station in
            await service.connect(to: station)
        }
    ) {
        self.primary = primary
        self.networkConfigurationProvider = networkConfigurationProvider
        self.connectOperation = connectOperation
        observeRecordingFailures(in: primary)
        primarySubscription = primary.$session.sink { [weak self, weak primary] session in
            guard session != nil else { return }
            Task { @MainActor [weak self, weak primary] in
                guard let self, let primary,
                      primary.session != nil,
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
        guard primary.session != nil,
              !entries.contains(where: { $0.service === primary }) else { return }
        let id = UUID()
        entries.append(
            Entry(
                id: id,
                callsign: callsign,
                mode: effectiveTransportProvider?(callsign)?.configuration.mode ?? networkConfigurationProvider().mode,
                service: primary,
                modeProvider: { [weak self] in
                    self?.effectiveTransportProvider?(callsign)?.configuration.mode
                        ?? self?.networkConfigurationProvider().mode
                }
            )
        )
        primary.pttPermission = { [weak self] in self?.activeID == id }
        subscriptions[id] = primary.$session.combineLatest(primary.$isReconnecting, primary.$reconnectCandidate).dropFirst()
            .sink { [weak self, weak primary] _, _, _ in
                Task { @MainActor [weak self, weak primary] in
                    guard let self, let primary else { return }
                    if primary.session == nil && !primary.isReconnecting && primary.reconnectCandidate == nil { self.remove(id) }
                    else { self.objectWillChange.send() }
                }
            }
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
        entries.append(entry)
        initialConnectionIDs.insert(id)
        subscriptions[id] = service.$session.combineLatest(service.$isReconnecting, service.$reconnectCandidate).dropFirst()
            .sink { [weak self, weak service] _, _, _ in
                Task { @MainActor [weak self, weak service] in
                    guard let self, let service else { return }
                    if !self.initialConnectionIDs.contains(id) && service.session == nil
                        && !service.isReconnecting && service.reconnectCandidate == nil {
                        self.remove(id)
                    } else {
                        self.objectWillChange.send()
                    }
                }
            }
        select(id)
        let savedResolver = service.resolveStation
        if preservingEndpoint { service.resolveStation = nil }
        await connectOperation(service, station)
        initialConnectionIDs.remove(id)
        if preservingEndpoint { service.resolveStation = savedResolver }
        if service.session == nil && service.reconnectCandidate == nil {
            remove(id)
        }
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
        for entry in entries {
            await entry.service.disconnect()
            entry.service.pttPermission = nil
            entry.service.setBackgroundMuted(false)
        }
        entries.removeAll()
        initialConnectionIDs.removeAll()
        subscriptions.removeAll()
        activeID = nil
    }

    func disconnect(callsign: String) async {
        for entry in entries where entry.callsign == callsign {
            await entry.service.disconnect()
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

    private func remove(_ id: UUID) {
        guard let removed = entries.first(where: { $0.id == id }) else { return }
        removed.service.pttPermission = nil
        removed.service.setBackgroundMuted(false)
        entries.removeAll { $0.id == id }
        initialConnectionIDs.remove(id)
        subscriptions.removeValue(forKey: id)
        if activeID == id {
            activeID = entries.last?.id
        }
        for entry in entries {
            entry.service.setBackgroundMuted(entry.id != activeID)
        }
    }
}
