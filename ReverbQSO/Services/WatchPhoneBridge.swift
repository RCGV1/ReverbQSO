// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) && !targetEnvironment(macCatalyst)
import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchPhoneBridge: NSObject, WCSessionDelegate {
    private struct Reply: @unchecked Sendable {
        let handler: ([String: Any]) -> Void

        func call(_ value: [String: Any]) { handler(value) }
    }

    private let primaryConnectionService: EchoLinkConnectionService
    private weak var appState: AppState?
    private let activeAccount: () -> String?
    private let simulatorDemoCredentials: Bool
    private var cancellables = Set<AnyCancellable>()
    private var activeServiceCancellables = Set<AnyCancellable>()
    private weak var observedService: EchoLinkConnectionService?
    private var pttTimeoutTask: Task<Void, Never>?
    private weak var pttService: EchoLinkConnectionService?
    private var pttSessionID: UUID?

    private var activeService: EchoLinkConnectionService {
        appState?.qsoHub.activeService ?? primaryConnectionService
    }

    init(connectionService: EchoLinkConnectionService, appState: AppState, demoCredentials: Bool = false) {
        self.primaryConnectionService = connectionService
        self.appState = appState
        self.activeAccount = { [weak appState] in
            guard let appState, appState.isLoggedIn else { return nil }
            return appState.currentUser
        }
        self.simulatorDemoCredentials = demoCredentials
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()

        observeActiveService()
        appState.qsoHub.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.observeActiveService()
                    self?.publishStatus()
                }
            }
            .store(in: &cancellables)
        appState.$isLoggedIn.combineLatest(appState.$currentUser, appState.$isDemoMode)
            .sink { [weak self] _, _, _ in
                Task { @MainActor [weak self] in self?.publishStatus() }
            }
            .store(in: &cancellables)
        appState.favoritesViewModel.$favorites
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.publishStatus() }
            }
            .store(in: &cancellables)
        appState.recentConnectionsService.$recents
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.publishStatus() }
            }
            .store(in: &cancellables)
    }

    private func compactStation(_ station: Station) -> [String: Any] {
        [
            "callsign": station.callsign,
            "nodeNumber": station.nodeNumber,
            "type": station.type.rawValue,
            "description": String(station.description.prefix(120))
        ]
    }

    private func observeActiveService() {
        let service = activeService
        guard observedService !== service else { return }
        if let pttService, pttService !== service {
            if pttService.session?.id == pttSessionID {
                pttService.sendPTT(active: false)
            }
            clearPTTLatch()
        }
        observedService = service
        activeServiceCancellables.removeAll()
        service.$session
            .combineLatest(service.$isRemoteTransmitting)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.publishStatus() }
            }
            .store(in: &activeServiceCancellables)
    }

    private func clearPTTLatch() {
        pttTimeoutTask?.cancel()
        pttTimeoutTask = nil
        pttService = nil
        pttSessionID = nil
    }

    private func status() -> [String: Any] {
        let service = activeService
        let session = service.session
        let connected = session?.state == .connected
        let isLocalDemo = appState?.isDemoMode == true
        if isLocalDemo {
            let favorites = LocalDemoAccount.stations.dropFirst().prefix(1).map(compactStation)
            let recents = LocalDemoAccount.stations.dropFirst(2).prefix(2).map(compactStation)
            return [
                "callsign": connected ? (session?.station.callsign ?? "") : "",
                "activeAccount": activeAccount() ?? "",
                "demo": true,
                "favorites": Array(favorites),
                "recents": Array(recents),
                "connected": connected,
                "isTransmitting": connected && (session?.isPTTActive ?? false),
                "isRemoteTransmitting": connected && service.isRemoteTransmitting
            ]
        }
        #if DEBUG
        let favorites = simulatorDemoCredentials
            ? [compactStation(SimulatorDemoData.stations[1])]
            : (appState?.favoritesViewModel.favorites.prefix(20).map(compactStation) ?? [])
        let recents = simulatorDemoCredentials
            ? [compactStation(SimulatorDemoData.stations[2]), compactStation(SimulatorDemoData.stations[3])]
            : (appState?.recentConnectionsService.recents.prefix(20).map { compactStation($0.station) } ?? [])
        #else
        let favorites = appState?.favoritesViewModel.favorites.prefix(20).map(compactStation) ?? []
        let recents = appState?.recentConnectionsService.recents.prefix(20).map { compactStation($0.station) } ?? []
        #endif
        return [
            "callsign": connected ? (session?.station.callsign ?? "") : "",
            "activeAccount": activeAccount() ?? "",
            "demo": false,
            "favorites": favorites,
            "recents": recents,
            "connected": connected,
            "isTransmitting": connected && (session?.isPTTActive ?? false),
            "isRemoteTransmitting": connected && service.isRemoteTransmitting
        ]
    }

    private func publishStatus() {
        if pttSessionID != nil && pttService?.session?.id != pttSessionID {
            clearPTTLatch()
        }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired else { return }
        try? WCSession.default.updateApplicationContext(status())
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in self?.publishStatus() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let command = message["command"] as? String
        let active = message["active"] as? Bool
        let requestedCallsign = message["callsign"] as? String
        let requestedNodeNumber = message["nodeNumber"] as? Int
        let reply = Reply(handler: replyHandler)
        Task { @MainActor [weak self] in
            guard let self else {
                reply.call(["ok": false, "error": "The iPhone app is unavailable."])
                return
            }
            switch command {
            case "ptt":
                guard let active else {
                    reply.call(["ok": false, "error": "Transmitting is unavailable."])
                    return
                }
                if active {
                    let service = self.activeService
                    guard service.session?.state == .connected, service.canTransmit else {
                        reply.call(["ok": false, "error": "Transmitting is unavailable."])
                        return
                    }
                    self.clearPTTLatch()
                    self.pttService = service
                    let sessionID = service.session?.id
                    self.pttSessionID = sessionID
                    service.sendPTT(active: true)
                    self.pttTimeoutTask = Task { @MainActor [weak self, weak service] in
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled, let self, let service,
                              self.pttService === service,
                              self.pttSessionID == sessionID,
                              service.session?.id == sessionID else { return }
                        service.sendPTT(active: false)
                        self.clearPTTLatch()
                    }
                } else {
                    if let service = self.pttService, service.session?.id == self.pttSessionID {
                        service.sendPTT(active: false)
                    }
                    self.clearPTTLatch()
                }
                self.publishStatus()
                reply.call(self.status().merging(["ok": true]) { _, new in new })
            case "disconnect":
                let service = self.activeService
                guard service.session?.state == .connected else {
                    reply.call(["ok": false, "error": "No active QSO."])
                    return
                }
                if self.pttService === service {
                    service.sendPTT(active: false)
                    self.clearPTTLatch()
                }
                await service.disconnect()
                self.publishStatus()
                reply.call(self.status().merging(["ok": true]) { _, new in new })
            case "status":
                reply.call(self.status().merging(["ok": true]) { _, new in new })
            case "connect":
                guard let appState = self.appState, appState.isLoggedIn else {
                    reply.call(["ok": false, "error": "Sign in on iPhone before connecting."])
                    return
                }
                guard let requestedCallsign,
                      !requestedCallsign.isEmpty,
                      requestedCallsign.count <= 32,
                      let requestedNodeNumber,
                      requestedNodeNumber >= 0 else {
                    reply.call(["ok": false, "error": "Invalid station request."])
                    return
                }
                guard appState.qsoHub.entries.isEmpty else {
                    reply.call(["ok": false, "error": "Disconnect the active iPhone QSO first."])
                    return
                }
                guard let station = appState.directoryService.stations.first(where: {
                    $0.callsign.caseInsensitiveCompare(requestedCallsign) == .orderedSame
                        && (requestedNodeNumber == 0 || $0.nodeNumber == requestedNodeNumber)
                }), !station.isBusy else {
                    reply.call(["ok": false, "error": "Station is unavailable in the current iPhone directory."])
                    return
                }
                await appState.connect(to: station)
                guard let connectedSession = self.activeService.session,
                      connectedSession.station.callsign.caseInsensitiveCompare(station.callsign) == .orderedSame,
                      connectedSession.station.nodeNumber == station.nodeNumber else {
                    reply.call(["ok": false, "error": appState.qsoHub.lastError ?? "Could not connect to station."])
                    return
                }
                self.publishStatus()
                reply.call(self.status().merging(["ok": true]) { _, new in new })
            case "credentials":
                guard let callsign = self.activeAccount(), !callsign.isEmpty else {
                    reply.call(["ok": false, "error": "No active iPhone sign-in."])
                    return
                }
                if LocalDemoAccount.isDemoUsername(callsign) {
                    guard self.appState?.isDemoMode == true else {
                        reply.call(["ok": false, "error": "The iPhone account changed. Sign in again."])
                        return
                    }
                    reply.call([
                        "ok": true,
                        "callsign": callsign,
                        "password": LocalDemoAccount.password,
                        "demo": true
                    ])
                    return
                }
                #if DEBUG
                if self.simulatorDemoCredentials {
                    guard callsign == SimulatorDemoData.callsign else {
                        reply.call(["ok": false, "error": "The paired demo uses N0DEMO."])
                        return
                    }
                    reply.call(["ok": true, "callsign": callsign, "password": SimulatorDemoData.password, "demo": true])
                    return
                }
                #endif
                guard let password = KeychainService.loadPassword(for: callsign), !password.isEmpty else {
                    reply.call(["ok": false, "error": "Sign in on iPhone again to share this account."])
                    return
                }
                reply.call(["ok": true, "callsign": callsign, "password": password])
            default:
                reply.call(["ok": false, "error": "Unknown watch command."])
            }
        }
    }
}
#endif
