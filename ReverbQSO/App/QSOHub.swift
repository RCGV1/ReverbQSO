// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation

/// Owns concurrent calls and keeps microphone and receive audio on one selected QSO.
@MainActor
final class QSOHub: ObservableObject {
    @MainActor struct Entry: Identifiable {
        let id: UUID
        let callsign: String
        let mode: EchoLinkNetworkMode
        let service: EchoLinkConnectionService

        var station: Station? { service.session?.station }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var activeID: UUID?
    @Published var lastError: String?

    private let primary: EchoLinkConnectionService
    private let connectOperation: @MainActor (EchoLinkConnectionService, Station) async -> Void
    private let networkConfigurationProvider: @MainActor () -> EchoLinkProxyConfiguration
    private var subscriptions: [UUID: AnyCancellable] = [:]
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
        primarySubscription = primary.$session.sink { [weak self, weak primary] session in
            guard session != nil else { return }
            Task { @MainActor [weak self, weak primary] in
                guard let self, let primary,
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
                service: primary
            )
        )
        primary.pttPermission = { [weak self] in self?.activeID == id }
        subscriptions[id] = primary.$session.dropFirst().sink { [weak self] session in
            Task { @MainActor [weak self] in
                if session == nil { self?.remove(id) }
                else { self?.objectWillChange.send() }
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
        if entries.contains(where: { $0.mode == .direct }) && configuredTransport.mode == .direct {
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
        let id = UUID()
        let entry = Entry(id: id, callsign: callsign, mode: mode, service: service)
        service.pttPermission = { [weak self] in
            guard let self, self.activeID == id else { return false }
            return !self.entries.contains { $0.id != id && $0.service.session?.isPTTActive == true }
        }
        entries.append(entry)
        subscriptions[id] = service.$session.dropFirst().sink { [weak self] session in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if session == nil {
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
        if preservingEndpoint { service.resolveStation = savedResolver }
        if service.session == nil {
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
        subscriptions.removeAll()
        activeID = nil
    }

    func disconnect(callsign: String) async {
        for entry in entries where entry.callsign == callsign {
            await entry.service.disconnect()
        }
    }

    private func remove(_ id: UUID) {
        guard let removed = entries.first(where: { $0.id == id }) else { return }
        removed.service.pttPermission = nil
        removed.service.setBackgroundMuted(false)
        entries.removeAll { $0.id == id }
        subscriptions.removeValue(forKey: id)
        if activeID == id {
            activeID = entries.last?.id
        }
        for entry in entries {
            entry.service.setBackgroundMuted(entry.id != activeID)
        }
    }
}
