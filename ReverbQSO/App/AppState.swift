// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI

/// Central application state shared across the app via the environment.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published State

    @Published var isLoggedIn: Bool = false
    @Published var isAutoLoggingIn: Bool = false
    @Published var currentUser: String = ""
    @Published var loginError: String?
    @Published private(set) var isDemoMode = false
    @Published private(set) var savedAccounts: [String] = KeychainService.savedCallsigns()

    // MARK: - Services

    @Published private(set) var directoryService: EchoLinkDirectoryService
    let connectionService: EchoLinkConnectionService
    let qsoHub: QSOHub
    let favoritesViewModel = FavoritesViewModel()
    let recentConnectionsService = RecentConnectionsService()
    let conferenceHostService = EchoLinkConferenceHostService()
    private var isApplicationActive = false
    private var isAuthenticating = false
    private var isSigningOut = false
    private var accountDirectories: [String: EchoLinkDirectoryService] = [:]
    private var autoLoginTask: Task<Void, Never>?
    private var authenticationGeneration: UInt64 = 0
#if targetEnvironment(macCatalyst)
    private var macMenuBarBridge: MacMenuBarBridge?
    private var macMessageNotifier: MacMessageNotifier?
#endif
#if os(iOS) && !targetEnvironment(macCatalyst)
    private let qsoActivityController = QSOActivityController()
    private var watchPhoneBridge: WatchPhoneBridge?
#endif

    // MARK: - Initialization

    init() {
        let proxySessionStore = EchoLinkProxySessionStore()
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            directoryService = EchoLinkDirectoryService(fetchStationsForRefresh: {
                SimulatorDemoData.stations
            })
            connectionService = EchoLinkConnectionService()
            qsoHub = QSOHub(primary: connectionService)
            directoryService.stations = SimulatorDemoData.stations
            directoryService.isLoggedIn = true
            currentUser = SimulatorDemoData.callsign
            savedAccounts = [SimulatorDemoData.callsign]
            isLoggedIn = !["login", "register"].contains(SimulatorDemoData.screen)
            connectionService.authenticatedCallsign = SimulatorDemoData.callsign
            if SimulatorDemoData.startsInQSO {
                let station = SimulatorDemoData.screen == "dtmf"
                    ? SimulatorDemoData.stations[1]
                    : SimulatorDemoData.stations[0]
                connectionService.installSimulatorDemoSession(station: station)
                qsoHub.adoptExistingPrimary(as: SimulatorDemoData.callsign)
                connectionService.incomingChatMessages = SimulatorDemoData.messages
                connectionService.activeNodeParticipants = SimulatorDemoData.participants
            }
            favoritesViewModel.add(SimulatorDemoData.stations[1])
            #if !targetEnvironment(macCatalyst)
            watchPhoneBridge = WatchPhoneBridge(connectionService: connectionService, appState: self, demoCredentials: true)
            if SimulatorDemoData.startsInQSO && ProcessInfo.processInfo.arguments.contains("--simulator-demo-multiple-qso") {
                Task { @MainActor in
                    _ = await qsoHub.connect(to: SimulatorDemoData.stations[2], as: SimulatorDemoData.callsign)
                }
            }
            #endif
            if ProcessInfo.processInfo.arguments.contains("--simulator-demo-incoming-call")
                || ProcessInfo.processInfo.arguments.contains("--simulator-demo-answered-call") {
                conferenceHostService.installSimulatorDemoIncomingCall(callsign: "K6DEMO")
                if ProcessInfo.processInfo.arguments.contains("--simulator-demo-answered-call") {
                    Task { @MainActor in await conferenceHostService.acceptPendingCall() }
                }
            }
            if recentConnectionsService.recents.isEmpty {
                recentConnectionsService.record(station: SimulatorDemoData.stations[2], duration: 462)
                recentConnectionsService.record(station: SimulatorDemoData.stations[3], duration: 94)
            }
            #if targetEnvironment(macCatalyst)
            macMenuBarBridge = MacMenuBarBridge(qsoHub: qsoHub, conferenceHost: conferenceHostService)
            macMessageNotifier = MacMessageNotifier(qsoHub: qsoHub, conferenceHost: conferenceHostService)
            #endif
            return
        }
#endif
        directoryService = EchoLinkDirectoryService(proxySessionStore: proxySessionStore)
        connectionService = EchoLinkConnectionService()
        qsoHub = QSOHub(primary: connectionService)
        qsoHub.effectiveTransportProvider = { [weak self] account in
            guard let self else { return nil }
            if self.isDemoMode { return LocalDemoAccount.transport }
            return (self.accountDirectories[account] ?? self.directoryService).effectiveTransport
        }
        qsoHub.configure = { [weak self] service, callsign in
            guard let self else { return }
            if self.isDemoMode {
                _ = service.enableLocalDemo(callsign: callsign)
            } else {
                _ = service.disableLocalDemo()
            }
            service.isConferenceHostActive = { [weak self] in
                guard let self else { return false }
                return self.conferenceHostService.isRunning || self.conferenceHostService.isStarting
            }
            service.resolveStation = { [weak self] station in
                guard let self else { return station }
                let directory = self.accountDirectories[callsign] ?? self.directoryService
                return StationEndpointResolver.resolve(station, from: directory.stations)
            }
            service.resolveReconnectStation = { [weak self] station in
                guard let self else { return nil }
                let directory = self.accountDirectories[callsign] ?? self.directoryService
                guard await directory.refresh() else {
                    throw directory.error ?? ConnectionError.connectionFailed("The directory refresh did not complete.")
                }
                return StationEndpointResolver.resolveStored(station, from: directory.stations)
            }
            service.effectiveTransportProvider = { [weak self] in
                guard let self else { return nil }
                return (self.accountDirectories[callsign] ?? self.directoryService).effectiveTransport
            }
            service.resolveProxySession = { [weak self] account in
                guard let self else { throw CancellationError() }
                let directory = self.accountDirectories[account] ?? self.directoryService
                return try await directory.prepareProxySession(callsign: account)
            }
            service.consumeReservedDirectSockets = { [weak self] in
                guard let self else { return nil }
                return (self.accountDirectories[callsign] ?? self.directoryService)
                    .consumePendingCQSocketPair()
            }
            service.prepareRelayDirectory = { [weak self] account, address in
                guard let self else { throw CancellationError() }
                let directory = self.accountDirectories[account] ?? self.directoryService
                try await directory.advertiseRelay(address: address)
            }
            service.finishRelayDirectory = { [weak self] account, address in
                guard let self else { return }
                let directory = self.accountDirectories[account] ?? self.directoryService
                await directory.stopAdvertisingRelay(address: address)
            }
            service.onSessionEnded = { [weak self] station, duration in
                self?.recentConnectionsService.record(station: station, duration: duration)
            }
        }
        connectionService.isConferenceHostActive = { [weak self] in
            guard let self else { return false }
            return self.conferenceHostService.isRunning || self.conferenceHostService.isStarting
        }

        if let callsign = KeychainService.loadCallsign() {
            currentUser = callsign
        }

        connectionService.resolveStation = { [weak self] station in
            guard let self else { return station }
            return StationEndpointResolver.resolve(station, from: self.directoryService.stations)
        }
        connectionService.resolveReconnectStation = { [weak self] station in
            guard let self else { return nil }
            guard await self.directoryService.refresh() else {
                throw self.directoryService.error
                    ?? ConnectionError.connectionFailed("The directory refresh did not complete.")
            }
            return StationEndpointResolver.resolveStored(
                station,
                from: self.directoryService.stations
            )
        }
        connectionService.effectiveTransportProvider = { [weak self] in
            guard let self else { return nil }
            let account = self.connectionService.authenticatedCallsign ?? self.currentUser
            return (self.accountDirectories[account] ?? self.directoryService).effectiveTransport
        }
        connectionService.resolveProxySession = { [weak self] callsign in
            guard let self else { throw CancellationError() }
            let directory = self.accountDirectories[callsign] ?? self.directoryService
            return try await directory.prepareProxySession(callsign: callsign)
        }
        connectionService.consumeReservedDirectSockets = { [weak self] in
            guard let self else { return nil }
            let account = self.connectionService.authenticatedCallsign ?? self.currentUser
            return (self.accountDirectories[account] ?? self.directoryService)
                .consumePendingCQSocketPair()
        }
        connectionService.prepareRelayDirectory = { [weak self] account, address in
            guard let self else { throw CancellationError() }
            let directory = self.accountDirectories[account] ?? self.directoryService
            try await directory.advertiseRelay(address: address)
        }
        connectionService.finishRelayDirectory = { [weak self] account, address in
            guard let self else { return }
            let directory = self.accountDirectories[account] ?? self.directoryService
            await directory.stopAdvertisingRelay(address: address)
        }

        // Wire session-ended recording to recents
        connectionService.onSessionEnded = { [weak self] station, duration in
            self?.recentConnectionsService.record(station: station, duration: duration)
        }

#if os(iOS) && !targetEnvironment(macCatalyst)
        PTTIntentBridge.shared.qsoHub = qsoHub
        qsoActivityController.observe(qsoHub)
        watchPhoneBridge = WatchPhoneBridge(connectionService: connectionService, appState: self)
#endif

#if targetEnvironment(macCatalyst)
        macMenuBarBridge = MacMenuBarBridge(qsoHub: qsoHub, conferenceHost: conferenceHostService)
        macMessageNotifier = MacMessageNotifier(qsoHub: qsoHub, conferenceHost: conferenceHostService)
#endif
        // Unit-test hosts must not sign in to EchoLink using credentials left
        // in the simulator. Live transport tests authenticate explicitly.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            attemptAutoLogin()
        }
    }

    // MARK: - Authentication Actions

    func login(callsign: String, password: String) async {
        let normalized = LocalDemoAccount.normalizedUsername(callsign)
        if LocalDemoAccount.isDemoUsername(normalized) {
            guard password == LocalDemoAccount.password else {
                loginError = "Incorrect callsign or password."
                return
            }
            await loginLocalDemo(callsign: normalized)
            return
        }
        guard !isDemoMode else {
            loginError = "Sign out before signing in with a different account."
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            let demoCallsign = callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard [SimulatorDemoData.callsign, "N1DEMO"].contains(demoCallsign),
                  password == SimulatorDemoData.password else {
                loginError = "Use N0DEMO or N1DEMO with demo in simulator preview."
                return
            }
            loginError = nil
            currentUser = demoCallsign
            if !savedAccounts.contains(demoCallsign) { savedAccounts.append(demoCallsign) }
            isLoggedIn = true
            directoryService.isLoggedIn = true
            directoryService.stations = SimulatorDemoData.stations
            return
        }
#endif
        isAuthenticating = true
        defer { isAuthenticating = false }
        authenticationGeneration &+= 1
        let generation = authenticationGeneration
        loginError = nil
        let target = accountDirectories[normalized]
            ?? (currentUser == normalized || !isLoggedIn ? directoryService : EchoLinkDirectoryService())
        await target.login(callsign: normalized, password: password)
        guard authenticationGeneration == generation, !isDemoMode else { return }

        if target.isLoggedIn {
            if currentUser != normalized
                && (conferenceHostService.isPersonalMode || conferenceHostService.isStarting) {
                await conferenceHostService.stop()
            }
            directoryService.stopForegroundRefreshing()
            accountDirectories[normalized] = target
            directoryService = target
            currentUser = normalized
            savedAccounts = KeychainService.savedCallsigns()
            isLoggedIn = true
            if connectionService.session == nil {
                connectionService.authenticatedCallsign = normalized
            }
            startDirectoryRefreshIfEligible()
        } else {
            loginError = target.error?.localizedDescription
                ?? "Login failed. Check your callsign and password."
            // Reauthenticating the active directory retires its old session.
            // Keep the app's signed-in state aligned with that service even
            // though the directory publisher fired while login was in flight.
            if target === directoryService && !target.isLoggedIn {
                isLoggedIn = false
                await qsoHub.disconnectAll()
            }
        }
    }

    func switchAccount(to callsign: String) async {
        if isDemoMode {
            guard savedAccounts.contains(callsign) else { return }
            await loginLocalDemo(callsign: callsign)
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            if savedAccounts.contains(callsign) { currentUser = callsign }
            return
        }
#endif
        guard callsign != currentUser,
              let password = KeychainService.loadPassword(for: callsign) else { return }
        await login(callsign: callsign, password: password)
    }

    func connect(
        to station: Station,
        as requestedCallsign: String? = nil,
        preservingEndpoint: Bool = false
    ) async {
        let callsign = requestedCallsign ?? currentUser
        if isDemoMode {
            guard isLoggedIn, savedAccounts.contains(callsign),
                  let localStation = StationEndpointResolver.resolveStored(station, from: LocalDemoAccount.stations) else {
                qsoHub.lastError = "This station is unavailable."
                return
            }
            if conferenceHostService.isRunning || conferenceHostService.isStarting {
                await conferenceHostService.stop()
            }
            _ = await qsoHub.connect(to: localStation, as: callsign, preservingEndpoint: preservingEndpoint)
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            _ = await qsoHub.connect(to: station, as: callsign, preservingEndpoint: preservingEndpoint)
            return
        }
#endif
        if conferenceHostService.isPersonalMode || conferenceHostService.isStarting {
            await conferenceHostService.stop()
        }
        guard savedAccounts.contains(callsign) || callsign == currentUser else {
            qsoHub.lastError = "Add \(callsign) in Settings before connecting."
            return
        }
        if accountDirectories[callsign]?.isLoggedIn != true {
            guard let password = KeychainService.loadPassword(for: callsign) else {
                qsoHub.lastError = "Sign in to \(callsign) again in Settings."
                return
            }
            let directory = EchoLinkDirectoryService()
            await directory.login(callsign: callsign, password: password, persistAsActive: callsign == currentUser)
            guard directory.isLoggedIn else {
                qsoHub.lastError = directory.error?.localizedDescription ?? "Could not sign in as \(callsign)."
                return
            }
            accountDirectories[callsign] = directory
        }
        qsoHub.lastError = nil
        _ = await qsoHub.connect(to: station, as: callsign, preservingEndpoint: preservingEndpoint)
    }

    func makeCallCQBackend(preferences: CallCQPreferences) async -> any CallCQBackend {
        if isDemoMode {
            return DemoCallCQBackend(
                stations: LocalDemoAccount.stations,
                policy: CallAccessPolicyStore.load(demo: true)
            )
        }
        if conferenceHostService.isRunning || conferenceHostService.isStarting {
            if conferenceHostService.isRunning && conferenceHostService.isPersonalMode {
                await stopPersonalCalls()
            } else {
                return FailingCallCQBackend(error: CallCQBackendError.conferenceHostingActive)
            }
        }
        do {
            return try directoryService.makeLiveCallCQBackend(
                callsign: currentUser,
                preferences: preferences,
                recentCallsigns: recentConnectionsService.recents
                    .filter { $0.station.type != .conference }
                    .map { $0.station.callsign },
                policy: CallAccessPolicyStore.load()
            )
        } catch {
            return FailingCallCQBackend(error: error)
        }
    }

    func connectToCallCQMatch(_ station: Station) async {
        await connect(to: station, as: currentUser, preservingEndpoint: true)
    }

    /// Opens this station to one incoming EchoLink call while the app can receive traffic.
    func startPersonalCalls() async {
        guard isLoggedIn, directoryService.isLoggedIn, qsoHub.entries.isEmpty else { return }
        await conferenceHostService.startPersonal(
            callsign: currentUser,
            directory: directoryService,
            outbound: connectionService
        )
    }

    func stopPersonalCalls() async {
        guard conferenceHostService.isPersonalMode || conferenceHostService.isStarting else { return }
        await conferenceHostService.stop()
    }

    func handleCurrentDirectoryLogout() async {
        guard isLoggedIn, !directoryService.isLoggedIn,
              !isAuthenticating, !isAutoLoggingIn, !isSigningOut else { return }
        directoryService.stopForegroundRefreshing()
        isLoggedIn = false
        loginError = "EchoLink sign-in ended. Sign in again to continue."
        await conferenceHostService.stop()
        await qsoHub.disconnectAll()
    }

    func removeSavedAccount(_ callsign: String) async {
        if isDemoMode {
            await qsoHub.disconnect(callsign: callsign)
            savedAccounts.removeAll { $0 == callsign }
            if savedAccounts.isEmpty { await logout() }
            else if currentUser == callsign { await loginLocalDemo(callsign: savedAccounts[0]) }
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            await qsoHub.disconnect(callsign: callsign)
            savedAccounts.removeAll { $0 == callsign }
            if currentUser == callsign { currentUser = savedAccounts.first ?? "" }
            return
        }
#endif
        if callsign == currentUser {
            let removedCallsign = currentUser
            await logout()
            KeychainService.remove(callsign: removedCallsign)
            savedAccounts = KeychainService.savedCallsigns()
            if let next = savedAccounts.first {
                await switchAccount(to: next)
            }
            return
        }
        await qsoHub.disconnect(callsign: callsign)
        if let directory = accountDirectories.removeValue(forKey: callsign) {
            await directory.logout()
            await directory.closeProxySession()
        }
        KeychainService.remove(callsign: callsign)
        savedAccounts = KeychainService.savedCallsigns()
    }

    func logout() async {
        isSigningOut = true
        defer { isSigningOut = false }
        authenticationGeneration &+= 1
        autoLoginTask?.cancel()
        autoLoginTask = nil
        await conferenceHostService.stop()
        if isDemoMode {
            await qsoHub.disconnectAll()
            await connectionService.disconnect()
            _ = connectionService.disableLocalDemo()
            connectionService.authenticatedCallsign = nil
            directoryService.stopForegroundRefreshing()
            await directoryService.logout()
            accountDirectories.removeAll()
            directoryService = EchoLinkDirectoryService()
            isDemoMode = false
            favoritesViewModel.setDemoMode(false)
            recentConnectionsService.setDemoMode(false)
            savedAccounts = KeychainService.savedCallsigns()
            currentUser = ""
            isLoggedIn = false
            isAutoLoggingIn = false
            loginError = nil
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            await connectionService.disconnect()
            isLoggedIn = false
            directoryService.isLoggedIn = false
            return
        }
#endif
        let oldCallsign = currentUser
        directoryService.stopForegroundRefreshing()
        await directoryService.logout()
        await qsoHub.disconnect(callsign: currentUser)
        if connectionService.authenticatedCallsign == oldCallsign {
            await connectionService.disconnect()
        }
        await directoryService.closeProxySession()
        accountDirectories.removeValue(forKey: oldCallsign)
        if connectionService.authenticatedCallsign == oldCallsign {
            connectionService.authenticatedCallsign = nil
        }
        savedAccounts = KeychainService.savedCallsigns()
        isLoggedIn = false
        currentUser = ""
        loginError = nil
    }

    func setApplicationActive(_ active: Bool) {
        isApplicationActive = active
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled { return }
#endif
        if active {
            startDirectoryRefreshIfEligible()
        } else {
            directoryService.stopForegroundRefreshing()
        }
    }

    private func startDirectoryRefreshIfEligible() {
        guard isApplicationActive, isLoggedIn, directoryService.isLoggedIn else { return }
        directoryService.startForegroundRefreshing()
    }

    // MARK: - Auto-login

    private func loginLocalDemo(callsign: String) async {
        guard !isSigningOut else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        loginError = nil
        if !isDemoMode {
            isSigningOut = true
            authenticationGeneration &+= 1
            autoLoginTask?.cancel()
            autoLoginTask = nil
            await conferenceHostService.stop()
            await qsoHub.disconnectAll()
            await connectionService.disconnect()
            var directories = Array(accountDirectories.values)
            if !directories.contains(where: { $0 === directoryService }) { directories.append(directoryService) }
            for directory in directories {
                directory.stopForegroundRefreshing()
                await directory.logout()
                await directory.closeProxySession()
            }
            accountDirectories.removeAll()
            isAutoLoggingIn = false
            isDemoMode = true
            isSigningOut = false
            savedAccounts = []
            favoritesViewModel.setDemoMode(true)
            recentConnectionsService.setDemoMode(true)
            if favoritesViewModel.favorites.isEmpty {
                favoritesViewModel.add(LocalDemoAccount.stations[0])
                favoritesViewModel.add(LocalDemoAccount.stations[1])
            }
            if recentConnectionsService.recents.isEmpty {
                recentConnectionsService.record(station: LocalDemoAccount.stations[3], duration: 94)
            }
        }
        directoryService.stopForegroundRefreshing()
        let directory = accountDirectories[callsign] ?? EchoLinkDirectoryService(localDemoAccount: callsign)
        accountDirectories[callsign] = directory
        directoryService = directory
        currentUser = callsign
        if !savedAccounts.contains(callsign) { savedAccounts.append(callsign) }
        if connectionService.session == nil {
            _ = connectionService.enableLocalDemo(callsign: callsign)
        }
        isLoggedIn = true
        startDirectoryRefreshIfEligible()
    }

    /// If credentials are stored, silently attempt login on app launch.
    private func attemptAutoLogin() {
        guard
            let callsign = KeychainService.loadCallsign(), !callsign.isEmpty,
            let password = KeychainService.loadPassword(), !password.isEmpty
        else { return }

        guard !LocalDemoAccount.isDemoUsername(callsign) else { return }
        isAutoLoggingIn = true
        let directory = directoryService
        let generation = authenticationGeneration
        autoLoginTask = Task {
            await directory.login(callsign: callsign, password: password)
            guard !Task.isCancelled, authenticationGeneration == generation, !isDemoMode else { return }
            isAutoLoggingIn = false
            if directoryService.isLoggedIn {
                currentUser = callsign
                accountDirectories[callsign] = directoryService
                savedAccounts = KeychainService.savedCallsigns()
                isLoggedIn = true
                connectionService.authenticatedCallsign = callsign
                startDirectoryRefreshIfEligible()
            }
            // If auto-login fails, just show the login screen -- no error shown
        }
    }
}

#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
/// Explicit launch argument for isolated visual QA. No credentials or live
/// EchoLink endpoints are used in this mode.
enum SimulatorDemoData {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--simulator-demo")
    static let isRemoteTalking = ProcessInfo.processInfo.arguments.contains("--simulator-demo-rx")
    static let screen = ProcessInfo.processInfo.arguments
        .first { $0.hasPrefix("--simulator-demo-screen=") }
        .map { String($0.dropFirst("--simulator-demo-screen=".count)) } ?? "qso"
    static let startsInQSO = ["qso", "chat", "activity", "participants", "audio", "dtmf", "rx"]
        .contains(screen)
    static let callsign = "N0DEMO"
    static let password = "demo"

    static let stations: [Station] = [
        Station(callsign: "*DEMO*", description: "Regional conference · evening net and announcements", ipAddress: "192.0.2.1", type: .conference, nodeNumber: 900001),
        Station(callsign: "N0DEMO-R", description: "Hilltop repeater with a long description to test narrow rows", ipAddress: "192.0.2.2", type: .repeater, nodeNumber: 900002),
        Station(callsign: "N0TEST-L", description: "Portable link", ipAddress: "192.0.2.3", type: .link, nodeNumber: 900003),
        Station(callsign: "W6SAMPLE", description: "Field operator", ipAddress: "192.0.2.4", type: .user, nodeNumber: 900004)
    ] + (5...90).map { index in
        Station(
            callsign: String(format: "N0SIM%03d", index),
            description: index.isMultiple(of: 3) ? "Long station status for directory scrolling and search" : "Demo station",
            ipAddress: "192.0.2.\(index)",
            type: Station.StationType.allCases[index % Station.StationType.allCases.count],
            isBusy: index.isMultiple(of: 7),
            nodeNumber: 900000 + index
        )
    }

    static let participants: [ActiveNodeParticipant] = (1...80).map { index in
        ActiveNodeParticipant(
            callsign: String(format: "N0USER%02d", index),
            displayName: index.isMultiple(of: 5) ? "N0USER\(index) · mobile operator with a longer name" : nil,
            isTransmitting: index == 1 && isRemoteTalking,
            lastActivity: Date()
        )
    }

    static let messages: [ChatMessage] = (1...120).map { index in
        ChatMessage(
            sender: index.isMultiple(of: 4) ? callsign : "N0USER\(index % 80 + 1)",
            body: index.isMultiple(of: 10)
                ? "Demo announcement \(index): This longer station message tests wrapping, scrolling, and the amount of room left for radio controls on a small display."
                : "Demo message \(index) about the ongoing QSO.",
            timestamp: Date().addingTimeInterval(Double(index - 120) * 45),
            isOutgoing: index.isMultiple(of: 4)
        )
    }
}
#endif
