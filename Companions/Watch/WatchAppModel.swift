// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import WatchConnectivity

enum WatchControlMode: String, CaseIterable, Identifiable {
    case onWatch = "On Watch"
    case iPhone = "iPhone"

    var id: String { rawValue }
}

@MainActor
final class WatchAppModel: NSObject, ObservableObject {
    @Published private(set) var directoryService = EchoLinkDirectoryService()
    let connectionService: EchoLinkConnectionService

    @Published var mode: WatchControlMode {
        didSet {
            guard oldValue != mode else { return }
            releasePTT(cancelTimeout: true)
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modePreferenceKey)
        }
    }
    @Published var networkMode: EchoLinkNetworkMode {
        didSet { saveNetworkMode() }
    }
    @Published var callsign: String
    @Published var password = ""
    @Published private(set) var isLoggingIn = false
    @Published private(set) var loginError: String?
    @Published private(set) var connectionError: String?
    @Published private(set) var companionStatus = PhoneSessionSnapshot()
    @Published private(set) var isCompanionReachable = false
    @Published private(set) var companionMessage: String?
    @Published private(set) var phoneFavorites: [Station] = []
    @Published private(set) var phoneRecents: [Station] = []
    @Published private(set) var localRecents: [Station] = []
    @Published private(set) var callCQService: CallCQService?

    private static let modePreferenceKey = "watch.controlMode"
    private static let linkedPhoneCallsignKey = "watch.linkedPhoneCallsign"
    private static let localDemoCallsignKey = "watch.localDemoCallsign"
    private static let networkModePreferenceKey = EchoLinkProxyConfiguration.modeKey
    private static let localRecentsKey = "watch.recentStations"
    private static let phoneFavoritesKey = "watch.phoneFavorites"
    private static let phoneRecentsKey = "watch.phoneRecents"
    private var activePTTMode: WatchControlMode?
    private var activePTTSessionID: UUID?
    private var activePhonePTTHoldID: UUID?
    private var pttWatchdogTask: Task<Void, Never>?
    private var linkedPhoneCallsign: String?
    private var phoneAccountHint: String?
    private var credentialRequestGeneration: Int?
    private var deferredCredentialSync = false
    private var authenticationGeneration = 0
    private var isDemoLogin = false
    private var isSigningOut = false
    private var didRunDemoReconnectProbe = false
    private let phoneAudioPlayer = WatchReceiveAudioPlayer()
    private var phoneAudioSequence = WatchAudioReceiveSequence()
    private var isForeground = false
    private var phoneAudioStopTask: Task<Void, Never>?
    private var audioSessionSubscription: AnyCancellable?

    init(connectionService: EchoLinkConnectionService = EchoLinkConnectionService()) {
        let savedDemoCallsign = UserDefaults.standard.string(forKey: Self.localDemoCallsignKey)
            .flatMap { LocalDemoAccount.isDemoUsername($0) ? $0.uppercased() : nil }
        let savedRealCallsign = KeychainService.loadCallsign()
            .flatMap { LocalDemoAccount.isDemoUsername($0) ? nil : $0 }
        let savedMode = UserDefaults.standard.string(forKey: Self.modePreferenceKey)
            .flatMap(WatchControlMode.init(rawValue:)) ?? .onWatch
        let savedNetworkMode = UserDefaults.standard.string(forKey: Self.networkModePreferenceKey)
            .flatMap(EchoLinkNetworkMode.init(rawValue:))
            ?? (UserDefaults.standard.bool(forKey: EchoLinkProxyConfiguration.enabledKey) ? .customProxy : .direct)
        mode = savedMode
        networkMode = savedNetworkMode == .customProxy ? .direct : savedNetworkMode
        callsign = savedDemoCallsign ?? savedRealCallsign ?? ""
        self.connectionService = connectionService
        linkedPhoneCallsign = UserDefaults.standard.string(forKey: Self.linkedPhoneCallsignKey)
        localRecents = Self.loadStations(forKey: Self.localRecentsKey)
        phoneFavorites = Self.loadStations(forKey: Self.phoneFavoritesKey)
        phoneRecents = Self.loadStations(forKey: Self.phoneRecentsKey)
        super.init()
        audioSessionSubscription = connectionService.$session
            .combineLatest(connectionService.$isReconnecting)
            .sink { [weak self] _, _ in
                // @Published emits from willSet. Re-read the service on the
                // MainActor before deciding whether a deferred account sync
                // may resume.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.reconcileWatchPTTWithSession()
                    let session = self.connectionService.session
                    if session != nil { self.stopPhoneReceiveAudio() }
                    self.reportWatchAudioAvailability(canReceive: session == nil)
                    self.finishDeferredCredentialSyncIfReady()
                }
            }
        saveNetworkMode()

        connectionService.onSessionEnded = { [weak self] station, _ in
            self?.recordLocalRecent(station)
        }

        connectionService.authenticatedCallsign = callsign.isEmpty ? nil : callsign
        connectionService.effectiveTransportProvider = { [weak self] in
            self?.directoryService.effectiveTransport
        }
        connectionService.resolveProxySession = { [weak self] account in
            guard let self else { throw CancellationError() }
            return try await self.directoryService.prepareProxySession(callsign: account)
        }
        connectionService.prepareAutomaticPublicProxyFallback = { [weak self] account in
            guard let self else { throw CancellationError() }
            return try await self.directoryService.prepareAutomaticPublicProxyFallback(callsign: account)
        }
        connectionService.reportUnansweredProxyHandshake = { [weak self] failed in
            await self?.directoryService.reportUnansweredProxyHandshake(failed)
        }
        connectionService.consumeReservedDirectSockets = { [weak self] in
            self?.directoryService.consumePendingCQSocketPair()
        }
        connectionService.prepareRelayDirectory = { [weak self] _, address in
            guard let self else { throw CancellationError() }
            try await self.directoryService.advertiseRelay(address: address)
        }
        connectionService.finishRelayDirectory = { [weak self] _, address in
            await self?.directoryService.stopAdvertisingRelay(address: address)
        }
        connectionService.resolveReconnectStation = { [weak self] station in
            guard let self else { throw CancellationError() }
            if self.isDemoLogin {
                guard await self.directoryService.refresh() else {
                    throw self.directoryService.error
                        ?? ConnectionError.connectionFailed("The local directory refresh did not complete.")
                }
                return StationEndpointResolver.resolveStored(station, from: self.directoryService.stations)
            }
            guard await self.directoryService.refresh() else {
                throw self.directoryService.error ?? ConnectionError.connectionFailed("The directory refresh did not complete.")
            }
            return StationEndpointResolver.resolveStored(station, from: self.directoryService.stations)
        }

        #if DEBUG
        // The native playback regression must not restore accounts or contact
        // the paired phone; these probes exercise receive state entirely offline.
        if ProcessInfo.processInfo.arguments.contains("--watch-companion-audio-probe")
            || ProcessInfo.processInfo.arguments.contains("--watch-companion-model-probe")
            || ProcessInfo.processInfo.arguments.contains("--watch-standalone-ptt-reconnect-probe")
            || ProcessInfo.processInfo.arguments.contains("--watch-stale-command-reply-probe") { return }
        #endif
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }

        if let savedDemoCallsign {
            Task {
                await login(
                    callsign: savedDemoCallsign,
                    password: LocalDemoAccount.password,
                    fromPhone: linkedPhoneCallsign == savedDemoCallsign,
                    demo: true
                )
            }
        } else if let savedRealCallsign,
                  let savedPassword = KeychainService.loadPassword(for: savedRealCallsign),
                  !savedRealCallsign.isEmpty,
                  !savedPassword.isEmpty {
            Task {
                await login(
                    callsign: savedRealCallsign,
                    password: savedPassword,
                    fromPhone: linkedPhoneCallsign == savedRealCallsign
                )
            }
        }
    }

    private func saveNetworkMode() {
        let defaults = UserDefaults.standard
        defaults.set(networkMode.rawValue, forKey: EchoLinkProxyConfiguration.modeKey)
        defaults.set(networkMode == .publicProxy || networkMode == .customProxy, forKey: EchoLinkProxyConfiguration.enabledKey)
    }

    private static func loadStations(forKey key: String) -> [Station] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Station].self, from: data)) ?? []
    }

    private static func saveStations(_ stations: [Station], forKey key: String) {
        guard let data = try? JSONEncoder().encode(stations) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func recordLocalRecent(_ station: Station) {
        localRecents.removeAll { $0.callsign.caseInsensitiveCompare(station.callsign) == .orderedSame }
        localRecents.insert(station, at: 0)
        localRecents = Array(localRecents.prefix(20))
        guard !isDemoLogin else { return }
        Self.saveStations(localRecents, forKey: Self.localRecentsKey)
    }

    private func applyPhoneStations(
        favorites: [WatchStationSnapshot]?,
        recents: [WatchStationSnapshot]?,
        demo: Bool = false
    ) {
        if let favorites {
            phoneFavorites = favorites.map(\.station)
            if !demo { Self.saveStations(phoneFavorites, forKey: Self.phoneFavoritesKey) }
        }
        if let recents {
            phoneRecents = recents.map(\.station)
            if !demo { Self.saveStations(phoneRecents, forKey: Self.phoneRecentsKey) }
        }
    }

    private func activateLocalDemo(callsign: String, generation: Int) async {
        releasePTT(cancelTimeout: true)
        await connectionService.disconnect()
        guard authenticationGeneration == generation else { return }
        await directoryService.logout()
        guard authenticationGeneration == generation else { return }
        guard connectionService.enableLocalDemo(callsign: callsign) else {
            isDemoLogin = false
            loginError = "Sign in failed."
            return
        }
        isDemoLogin = true
        let localDirectory = EchoLinkDirectoryService(localDemoAccount: callsign)
        await localDirectory.login(
            callsign: callsign,
            password: LocalDemoAccount.password,
            persistAsActive: false
        )
        guard authenticationGeneration == generation, localDirectory.isLoggedIn else {
            await localDirectory.logout()
            _ = connectionService.disableLocalDemo()
            if authenticationGeneration == generation {
                isDemoLogin = false
                loginError = localDirectory.error?.localizedDescription ?? "Sign in failed."
            }
            return
        }
        directoryService = localDirectory
        UserDefaults.standard.set(callsign, forKey: Self.localDemoCallsignKey)
        phoneFavorites = Array(LocalDemoAccount.stations.dropFirst().prefix(1))
        phoneRecents = Array(LocalDemoAccount.stations.dropFirst(2).prefix(2))
        localRecents = []
    }

    private func clearLocalDemo() async {
        releasePTT(cancelTimeout: true)
        await connectionService.disconnect()
        _ = connectionService.disableLocalDemo()
        await directoryService.logout()
        directoryService = EchoLinkDirectoryService()
        UserDefaults.standard.removeObject(forKey: Self.localDemoCallsignKey)
        isDemoLogin = false
        phoneFavorites = Self.loadStations(forKey: Self.phoneFavoritesKey)
        phoneRecents = Self.loadStations(forKey: Self.phoneRecentsKey)
        localRecents = Self.loadStations(forKey: Self.localRecentsKey)
    }

    var isWatchLoggedIn: Bool { directoryService.isLoggedIn }
    var isLocalDemoMode: Bool { isDemoLogin && connectionService.isLocalDemoMode }
    var hasWatchSession: Bool { connectionService.session != nil }
    var canUsePhone: Bool { isCompanionReachable && phoneAccountHint?.isEmpty == false }
    var recentStations: [Station] {
        var seen = Set<String>()
        return (phoneRecents + localRecents).filter { seen.insert($0.callsign.uppercased()).inserted }
    }
    func preferredDestination(for station: Station) -> WatchControlMode? {
        if companionStatus.connected {
            if companionStatus.callsign.caseInsensitiveCompare(station.callsign) == .orderedSame {
                return .iPhone
            }
            return isWatchLoggedIn && !hasWatchSession ? .onWatch : nil
        }
        if canUsePhone { return .iPhone }
        return isWatchLoggedIn ? .onWatch : nil
    }
    var phoneCanTransmit: Bool {
        companionStatus.connected && !companionStatus.isRemoteTransmitting
    }

    func login(callsign: String? = nil, password: String? = nil, fromPhone: Bool = false, demo: Bool = false) async {
        guard !isSigningOut else { return }
        let normalizedCallsign = (callsign ?? self.callsign)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let suppliedPassword = password ?? self.password
        guard !normalizedCallsign.isEmpty, !suppliedPassword.isEmpty else {
            loginError = "Enter your callsign and password."
            return
        }

        isLoggingIn = true
        loginError = nil
        self.callsign = normalizedCallsign
        authenticationGeneration += 1
        credentialRequestGeneration = nil
        deferredCredentialSync = false
        let generation = authenticationGeneration
        if LocalDemoAccount.isDemoUsername(normalizedCallsign) {
            guard suppliedPassword == LocalDemoAccount.password else {
                isLoggingIn = false
                loginError = "The callsign or password is incorrect."
                return
            }
            await activateLocalDemo(callsign: normalizedCallsign, generation: generation)
        } else if demo {
        #if DEBUG
            guard normalizedCallsign == "N0DEMO", suppliedPassword == "demo" else {
                isLoggingIn = false
                loginError = "The paired account is unavailable."
                return
            }
            if isDemoLogin { await clearLocalDemo() }
            let demoStations = [
                Station(callsign: "*DEMO*", description: "Paired iPhone demo", ipAddress: "192.0.2.1", type: .conference, nodeNumber: 900001)
            ]
            directoryService.stations = demoStations
            directoryService.filteredStations = demoStations
            directoryService.isLoggedIn = true
            isDemoLogin = true
        #else
            isLoggingIn = false
            loginError = "The paired account is unavailable."
            return
        #endif
        } else {
            if isDemoLogin { await clearLocalDemo() }
            isDemoLogin = false
            await directoryService.login(callsign: normalizedCallsign, password: suppliedPassword)
        }
        guard generation == authenticationGeneration else { return }
        isLoggingIn = false

        if directoryService.isLoggedIn {
            connectionService.authenticatedCallsign = normalizedCallsign
            self.password = ""
            linkedPhoneCallsign = fromPhone ? normalizedCallsign : nil
            UserDefaults.standard.set(linkedPhoneCallsign, forKey: Self.linkedPhoneCallsignKey)
        } else {
            loginError = loginError ?? directoryService.error?.localizedDescription ?? "Sign in failed."
        }
        finishDeferredCredentialSyncIfReady()
    }

    func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        authenticationGeneration += 1
        credentialRequestGeneration = nil
        deferredCredentialSync = false
        isLoggingIn = false
        linkedPhoneCallsign = nil
        phoneAccountHint = nil
        UserDefaults.standard.removeObject(forKey: Self.linkedPhoneCallsignKey)
        releasePTT(cancelTimeout: true)
        if isDemoLogin {
            await clearLocalDemo()
            callsign = KeychainService.loadCallsign()
                .flatMap { LocalDemoAccount.isDemoUsername($0) ? nil : $0 } ?? ""
            password = ""
            loginError = nil
            connectionService.authenticatedCallsign = nil
            return
        }
        await connectionService.disconnect()
        await directoryService.logout()
        connectionService.authenticatedCallsign = nil
        _ = KeychainService.delete()
        callsign = ""
        password = ""
        loginError = nil
    }

    private func requestPhoneCredentials() {
        guard !isSigningOut else { return }
        if isLoggingIn {
            deferredCredentialSync = true
            return
        }
        if connectionService.session != nil || connectionService.isReconnecting {
            deferredCredentialSync = true
            return
        }
        guard WCSession.isSupported(), WCSession.default.isReachable,
              credentialRequestGeneration == nil else { return }
        let generation = authenticationGeneration
        credentialRequestGeneration = generation
        sendCredentialRequest(generation: generation)
    }

    private func finishDeferredCredentialSyncIfReady() {
        guard !isSigningOut,
              !isLoggingIn,
              deferredCredentialSync,
              isCompanionReachable,
              connectionService.session == nil,
              !connectionService.isReconnecting else { return }
        switch WatchCredentialSyncPolicy.disposition(
            phoneAccount: phoneAccountHint,
            linkedPhoneCallsign: linkedPhoneCallsign,
            isWatchLoggedIn: isWatchLoggedIn,
            hasSession: false,
            isReconnecting: false
        ) {
        case .request:
            requestPhoneCredentials()
        case .ignore:
            deferredCredentialSync = false
        case .deferUntilIdle:
            break
        }
    }

    // WatchConnectivity invokes reply handlers on its own queue. Create the
    // handler outside the MainActor so Swift's executor check does not trap.
    private nonisolated func sendCredentialRequest(generation: Int) {
        WCSession.default.sendMessage(["command": "credentials"]) { [weak self] reply in
            let ok = reply["ok"] as? Bool == true
            let callsign = reply["callsign"] as? String
            let password = reply["password"] as? String
            let demo = reply["demo"] as? Bool ?? false
            Task { @MainActor [weak self] in
                await self?.handleCredentialReply(
                    generation: generation, ok: ok, callsign: callsign,
                    password: password, demo: demo
                )
            }
        } errorHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.credentialRequestGeneration == generation else { return }
                self.credentialRequestGeneration = nil
            }
        }
    }

    private func handleCredentialReply(
        generation: Int, ok: Bool, callsign: String?, password: String?,
        demo: Bool
    ) async {
        guard credentialRequestGeneration == generation else { return }
        credentialRequestGeneration = nil
        guard generation == authenticationGeneration else { return }
        guard !isSigningOut else { return }
        guard ok, let callsign, let password, !callsign.isEmpty, !password.isEmpty else {
            return
        }
        switch WatchCredentialSyncPolicy.disposition(
            phoneAccount: phoneAccountHint ?? callsign,
            linkedPhoneCallsign: linkedPhoneCallsign,
            isWatchLoggedIn: isWatchLoggedIn,
            hasSession: connectionService.session != nil,
            isReconnecting: connectionService.isReconnecting
        ) {
        case .deferUntilIdle:
            phoneAccountHint = phoneAccountHint ?? callsign
            deferredCredentialSync = true
            return
        case .ignore:
            deferredCredentialSync = false
            if linkedPhoneCallsign == callsign && isWatchLoggedIn {
                runDemoReconnectProbeIfRequested()
            }
            return
        case .request:
            break
        }

        guard phoneAccountHint == nil
                || phoneAccountHint?.caseInsensitiveCompare(callsign) == .orderedSame else {
            requestPhoneCredentials()
            return
        }
        // Store the paired account as soon as it arrives. Watch directory access
        // may be temporarily unavailable, but the Watch can retry on its own
        // next time it opens, even when the iPhone is out of range.
        let savedOnWatch = demo || LocalDemoAccount.isDemoUsername(callsign)
            || KeychainService.save(callsign: callsign, password: password)
        await login(callsign: callsign, password: password, fromPhone: true, demo: demo)
        if !savedOnWatch {
            companionMessage = "Could not save this account on Watch for independent use."
        }
        runDemoReconnectProbeIfRequested()
    }

    private func runDemoReconnectProbeIfRequested() {
        #if DEBUG
        guard isDemoLogin, !didRunDemoReconnectProbe else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let station: Station?
        if arguments.contains("--simulator-demo-connect-favorite") {
            station = phoneFavorites.first
        } else if arguments.contains("--simulator-demo-connect-recent") {
            station = phoneRecents.first
        } else {
            station = nil
        }
        guard let station else { return }
        didRunDemoReconnectProbe = true
        Task { await connect(to: station, destination: .iPhone, savedStation: true) }
        #endif
    }

    private func handlePhoneAccount(_ account: String?) {
        guard let account, !isSigningOut else { return }
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        phoneAccountHint = normalizedAccount
        if normalizedAccount.isEmpty {
            deferredCredentialSync = false
            applyPhoneStations(favorites: [], recents: [])
            return
        }
        guard isCompanionReachable else { return }
        switch WatchCredentialSyncPolicy.disposition(
            phoneAccount: normalizedAccount,
            linkedPhoneCallsign: linkedPhoneCallsign,
            isWatchLoggedIn: isWatchLoggedIn,
            hasSession: connectionService.session != nil,
            isReconnecting: connectionService.isReconnecting
        ) {
        case .deferUntilIdle:
            deferredCredentialSync = true
        case .request:
            requestPhoneCredentials()
        case .ignore:
            deferredCredentialSync = false
        }
    }

    func connect(to station: Station, destination: WatchControlMode? = nil, savedStation: Bool = false) async {
        connectionError = nil
        let currentStation = StationEndpointResolver.resolve(station, from: directoryService.stations)
        guard !currentStation.isRelayOnly else {
            connectionError = "This station cannot receive calls."
            return
        }
        if currentStation.isConnectionLimitReached {
            connectionError = currentStation.connectionUnavailableReason
            return
        }
        guard let destination = destination ?? preferredDestination(for: station) else {
            connectionError = "Sign in on the Watch or open the paired iPhone app."
            return
        }
        mode = destination
        switch destination {
        case .iPhone:
            guard canUsePhone else {
                connectionError = "Open ReverbQSO on the paired iPhone."
                return
            }
            if companionStatus.connected {
                if companionStatus.callsign.caseInsensitiveCompare(station.callsign) != .orderedSame {
                    connectionError = "Disconnect the iPhone QSO before joining another station there."
                }
                return
            }
            sendPhoneCommand([
                "command": "connect",
                "callsign": station.callsign,
                "nodeNumber": station.nodeNumber
            ])
        case .onWatch:
            guard !isSigningOut, !isLoggingIn else {
                connectionError = isSigningOut
                    ? "Signing out of the Watch account."
                    : "Signing in to the Watch account."
                return
            }
            guard isWatchLoggedIn else {
                connectionError = "Sign in on the Watch to connect here."
                return
            }
            let resolved: Station
            if savedStation {
                if isDemoLogin {
                    guard await directoryService.refresh() else {
                        connectionError = directoryService.error?.localizedDescription
                            ?? "Could not refresh the local station list."
                        return
                    }
                } else {
                    guard await directoryService.refresh() else {
                        connectionError = directoryService.error?.localizedDescription ?? "Could not refresh the station list."
                        return
                    }
                }
                guard let current = StationEndpointResolver.resolveStored(station, from: directoryService.stations) else {
                    connectionError = "This station is offline now."
                    return
                }
                resolved = current
            } else {
                resolved = StationEndpointResolver.resolve(station, from: directoryService.stations)
            }
            await connectionService.connect(to: resolved)
            connectionError = connectionService.error?.localizedDescription
        }
    }

    func beginCallCQ(preferences: CallCQPreferences) {
        let service = CallCQService(backendFactory: { [weak self] preferences in
            guard let self else {
                return FailingCallCQBackend(error: CallCQBackendError.transportUnavailable)
            }
            if self.isLocalDemoMode {
                return DemoCallCQBackend(
                    stations: LocalDemoAccount.stations,
                    policy: CallAccessPolicyStore.load(demo: true)
                )
            }
            do {
                return try await self.directoryService.makeLiveCallCQBackend(
                    callsign: self.callsign,
                    preferences: preferences,
                    recentCallsigns: self.localRecents.filter { $0.type != .conference }.map(\.callsign),
                    policy: CallAccessPolicyStore.load()
                )
            } catch {
                return FailingCallCQBackend(error: error)
            }
        })
        callCQService = service
        Task { await service.start(preferences: preferences) }
    }

    func cancelCallCQ() async {
        await callCQService?.cancel()
        callCQService = nil
    }

    func connectToCallCQMatch(_ station: Station) async {
        await cancelCallCQ()
        connectionError = nil
        await connectionService.connect(to: station, preservingEndpoint: true)
        connectionError = connectionService.error?.localizedDescription
    }

    func disconnectOnWatch() async {
        releasePTT(cancelTimeout: true)
        await connectionService.disconnect()
    }

    @discardableResult
    func beginPTT() -> Bool {
        if hasWatchSession { return beginPTT(in: .onWatch) }
        if companionStatus.connected { return beginPTT(in: .iPhone) }
        return false
    }

    @discardableResult
    func beginPTT(on destination: WatchControlMode) -> Bool {
        beginPTT(in: destination)
    }

    func endPTT() {
        releasePTT(cancelTimeout: true)
    }

    func beginTimedPTT() throws {
        guard beginPTT() else { throw WatchPTTIntentError.transmitUnavailable }
    }

    func disconnectPhoneSession() {
        guard isCompanionReachable, let sessionID = companionStatus.sessionID else {
            companionMessage = "Bring iPhone nearby to control its session."
            return
        }
        sendPhoneCommand(["command": "disconnect", "sessionID": sessionID.uuidString])
        companionMessage = "Disconnecting iPhone session…"
    }

    private func beginPTT(in mode: WatchControlMode) -> Bool {
        reconcileWatchPTTWithSession()
        guard activePTTMode == nil else { return true }

        switch mode {
        case .onWatch:
            guard connectionService.canTransmit,
                  let sessionID = connectionService.session?.id else { return false }
            activePTTMode = .onWatch
            activePTTSessionID = sessionID
            connectionService.sendPTT(active: true)
        case .iPhone:
            guard isCompanionReachable, phoneCanTransmit,
                  let sessionID = companionStatus.sessionID else { return false }
            activePTTMode = .iPhone
            activePTTSessionID = sessionID
            let holdID = UUID()
            activePhonePTTHoldID = holdID
            sendPhoneCommand(["command": "ptt", "active": true,
                "sessionID": sessionID.uuidString, "holdID": holdID.uuidString])
            guard activePTTMode == .iPhone else { return false }
        }
        schedulePTTWatchdog()
        return true
    }

    private func reconcileWatchPTTWithSession() {
        guard activePTTMode == .onWatch else { return }
        guard let heldSessionID = activePTTSessionID,
              let session = connectionService.session,
              session.id == heldSessionID,
              session.isPTTActive else {
            clearPTTLatch()
            return
        }
    }

    private func clearPTTLatch() {
        pttWatchdogTask?.cancel()
        pttWatchdogTask = nil
        activePTTMode = nil
        activePTTSessionID = nil
        activePhonePTTHoldID = nil
    }

    private func releasePTT(cancelTimeout: Bool, expectedSessionID: UUID? = nil) {
        // A delayed watchdog for an old QSO must not release a newer hold.
        if let expectedSessionID, activePTTSessionID != expectedSessionID { return }
        if cancelTimeout {
            pttWatchdogTask?.cancel()
        }
        pttWatchdogTask = nil
        guard let mode = activePTTMode else { return }
        let sessionID = activePTTSessionID
        let holdID = activePhonePTTHoldID
        activePTTMode = nil
        activePTTSessionID = nil
        activePhonePTTHoldID = nil

        switch mode {
        case .onWatch:
            guard let sessionID, connectionService.session?.id == sessionID else { return }
            connectionService.sendPTT(active: false)
        case .iPhone:
            guard let sessionID, let holdID else { return }
            sendPhoneCommand(["command": "ptt", "active": false,
                "sessionID": sessionID.uuidString, "holdID": holdID.uuidString])
        }
    }

    private func schedulePTTWatchdog() {
        pttWatchdogTask?.cancel()
        let expectedMode = activePTTMode
        let expectedSessionID = activePTTSessionID
        let expectedHoldID = activePhonePTTHoldID
        pttWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.activePTTMode == expectedMode,
                  self.activePTTSessionID == expectedSessionID,
                  self.activePhonePTTHoldID == expectedHoldID else { return }
            self.releasePTT(cancelTimeout: false, expectedSessionID: expectedSessionID)
        }
    }

    private func sendPhoneCommand(_ command: [String: Any]) {
        guard WCSession.isSupported(), WCSession.default.isReachable else {
            companionMessage = "iPhone is not reachable."
            if (command["active"] as? Bool) == true {
                clearFailedPhonePTTStart(expectedHoldID: activePhonePTTHoldID)
            }
            return
        }
        dispatchPhoneCommand(
            command,
            startsPTT: (command["active"] as? Bool) == true,
            connects: (command["command"] as? String) == "connect"
        )
    }

    private nonisolated func dispatchPhoneCommand(_ command: [String: Any], startsPTT: Bool, connects: Bool) {
        let holdID = (command["holdID"] as? String).flatMap(UUID.init(uuidString:))
        let expectedSessionID = (command["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        WCSession.default.sendMessage(command) { [weak self] reply in
            let hasStatus = ["callsign", "connected", "isTransmitting", "isRemoteTransmitting"]
                .contains { reply[$0] != nil }
            let snapshot = hasStatus ? PhoneSessionSnapshot(dictionary: reply) : nil
            let favorites = WatchStationSnapshot.list(from: reply["favorites"])
            let recents = WatchStationSnapshot.list(from: reply["recents"])
            let demo = reply["demo"] as? Bool ?? false
            let account = reply["activeAccount"] as? String
            let message = reply["error"] as? String
            let startAccepted = !startsPTT || reply["ok"] as? Bool == true
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.applyPhoneCommandSnapshot(snapshot,
                    expectedSessionID: expectedSessionID, holdID: holdID, startsPTT: startsPTT) else { return }
                self.applyPhoneStations(
                    favorites: favorites,
                    recents: recents,
                    demo: demo || account.map(LocalDemoAccount.isDemoUsername) == true
                )
                self.companionMessage = message
                if connects { self.connectionError = message }
                if !startAccepted { self.clearFailedPhonePTTStart(expectedHoldID: holdID) }
            }
        } errorHandler: { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.applyPhoneCommandSnapshot(nil,
                    expectedSessionID: expectedSessionID, holdID: holdID, startsPTT: startsPTT) else { return }
                self.companionMessage = message
                if connects { self.connectionError = message }
                if startsPTT { self.clearFailedPhonePTTStart(expectedHoldID: holdID) }
            }
        }
    }

    private func applyPhoneCommandSnapshot(_ snapshot: PhoneSessionSnapshot?,
        expectedSessionID: UUID?, holdID: UUID?, startsPTT: Bool) -> Bool {
        guard expectedSessionID == nil || expectedSessionID == companionStatus.sessionID else { return false }
        if startsPTT {
            guard let holdID, holdID == activePhonePTTHoldID else { return false }
        } else if let holdID, let currentHold = activePhonePTTHoldID, holdID != currentHold {
            return false
        }
        if let snapshot { apply(snapshot) }
        return true
    }

    private func clearFailedPhonePTTStart(expectedHoldID: UUID? = nil) {
        guard activePTTMode == .iPhone,
              expectedHoldID == nil || expectedHoldID == activePhonePTTHoldID else { return }
        clearPTTLatch()
    }

    private func applyCompanionReachability(_ reachable: Bool) {
        isCompanionReachable = reachable
        if reachable {
            reportWatchAudioAvailability()
            if companionStatus.connected {
                companionMessage = nil
            }
            requestPhoneCredentials()
            return
        }
        clearFailedPhonePTTStart()
        companionStatus = companionStatus.applyingCompanionReachability(false)
    }

    private func apply(_ snapshot: PhoneSessionSnapshot) {
        if activePTTMode == .iPhone, activePTTSessionID != snapshot.sessionID {
            releasePTT(cancelTimeout: true)
        }
        if companionStatus.sessionID != snapshot.sessionID || !snapshot.connected
            || !snapshot.watchAudioOutputEnabled {
            stopPhoneReceiveAudio()
        }
        companionStatus = snapshot
        isCompanionReachable = WCSession.default.isReachable
        if !isCompanionReachable {
            clearFailedPhonePTTStart()
            companionStatus = companionStatus.applyingCompanionReachability(false)
        }
        if snapshot.connected {
            companionMessage = nil
        } else if activePTTMode == .iPhone {
            releasePTT(cancelTimeout: true)
        }
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        if !active { stopPhoneReceiveAudio(); endPTT() }
        reportWatchAudioAvailability()
    }

    private func reportWatchAudioAvailability(canReceive: Bool? = nil) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        let expectedSessionID = companionStatus.sessionID
        let expectedHoldID = activePhonePTTHoldID
        WCSession.default.sendMessage([
            "command": "watchAudioReady",
            "active": isForeground && (canReceive ?? (connectionService.session == nil))
        ], replyHandler: { [weak self] reply in
            let snapshot = PhoneSessionSnapshot(dictionary: reply)
            Task { @MainActor [weak self] in
                self?.applyWatchAudioAvailabilitySnapshot(snapshot,
                    expectedSessionID: expectedSessionID, expectedHoldID: expectedHoldID)
            }
        }, errorHandler: nil)
    }

    @discardableResult
    private func applyWatchAudioAvailabilitySnapshot(_ snapshot: PhoneSessionSnapshot,
        expectedSessionID: UUID?, expectedHoldID: UUID?) -> Bool {
        guard expectedSessionID == companionStatus.sessionID,
              expectedHoldID == activePhonePTTHoldID else { return false }
        apply(snapshot)
        return true
    }

    private func stopPhoneReceiveAudio() {
        phoneAudioStopTask?.cancel()
        phoneAudioStopTask = nil
        phoneAudioPlayer.stop()
        phoneAudioSequence = WatchAudioReceiveSequence()
    }

    private func receivePhoneAudio(_ data: Data) -> Bool {
        guard isForeground, connectionService.session == nil, companionStatus.connected,
              let frame = WatchAudioFrame.decode(data) else { return false }
        var candidateSequence = phoneAudioSequence
        guard candidateSequence.accept(frame, expectedStreamID: companionStatus.sessionID),
              phoneAudioPlayer.play(frame.datagram) else { return false }
        phoneAudioSequence = candidateSequence
        phoneAudioStopTask?.cancel()
        phoneAudioStopTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.phoneAudioPlayer.stop()
            self?.phoneAudioStopTask = nil
        }
        return true
    }

    #if DEBUG
    func runStalePhoneCommandReplyProbe() {
        let priorSnapshot = companionStatus
        let currentSession = UUID()
        let currentHold = UUID()
        companionStatus = Self.probeSnapshot(sessionID: currentSession)
        activePTTMode = .iPhone
        activePTTSessionID = currentSession
        activePhonePTTHoldID = currentHold
        let oldSession = UUID()
        let accepted = applyPhoneCommandSnapshot(Self.probeSnapshot(sessionID: oldSession),
            expectedSessionID: oldSession, holdID: UUID(), startsPTT: true)
        let staleSameSession = applyPhoneCommandSnapshot(Self.probeSnapshot(sessionID: currentSession),
            expectedSessionID: currentSession, holdID: UUID(), startsPTT: true)
        let staleRelease = applyPhoneCommandSnapshot(Self.probeSnapshot(sessionID: oldSession),
            expectedSessionID: oldSession, holdID: UUID(), startsPTT: false)
        let staleAvailability = applyWatchAudioAvailabilitySnapshot(Self.probeSnapshot(sessionID: oldSession),
            expectedSessionID: oldSession, expectedHoldID: nil)
        let availabilityBeforeNewHold = applyWatchAudioAvailabilitySnapshot(Self.probeSnapshot(sessionID: currentSession),
            expectedSessionID: currentSession, expectedHoldID: nil)
        let passed = !accepted && !staleSameSession && !staleRelease
            && !staleAvailability && !availabilityBeforeNewHold && companionStatus.sessionID == currentSession
            && activePTTMode == .iPhone && activePhonePTTHoldID == currentHold
        NSLog("WATCH_STALE_COMMAND_REPLY_PROBE %@ accepted=%@ staleAvailability=%@ availabilityBeforeNewHold=%@ currentHoldPreserved=%@",
            passed ? "passed" : "failed", accepted ? "true" : "false",
            staleAvailability ? "true" : "false", availabilityBeforeNewHold ? "true" : "false",
            activePhonePTTHoldID == currentHold ? "true" : "false")
        clearPTTLatch()
        companionStatus = priorSnapshot
    }

    /// Reproduces the Watch PTT latch behavior when the service session ends
    /// independently of the model's disconnect action. Uses only the local
    /// demo fixture in a simulator and makes no network or microphone calls.
    func runStandalonePTTReconnectProbe() async {
#if targetEnvironment(simulator)
        guard connectionService.enableLocalDemo(callsign: "DEMO") else {
            NSLog("WATCH_STANDALONE_PTT_RECONNECT_PROBE failed reason=local_demo_enable")
            return
        }
        guard let station = LocalDemoAccount.stations.first(where: { $0.callsign == "N0DEMO-R" }) else {
            _ = connectionService.disableLocalDemo()
            NSLog("WATCH_STANDALONE_PTT_RECONNECT_PROBE failed reason=fixture_missing")
            return
        }

        await connectionService.connect(to: station)
        guard let firstSessionID = connectionService.session?.id,
              connectionService.session?.state == .connected else {
            let error = connectionService.error?.localizedDescription ?? "no connected session"
            await connectionService.disconnect()
            _ = connectionService.disableLocalDemo()
            NSLog("WATCH_STANDALONE_PTT_RECONNECT_PROBE failed firstConnect=%@",
                  error as NSString)
            return
        }
        let firstBeginAccepted = beginPTT(on: .onWatch)
        let firstSessionPTTActive = connectionService.session?.isPTTActive == true
        await connectionService.disconnect()

        // The session publisher schedules its model observer in a MainActor
        // task. Let that task run before attempting the replacement session.
        try? await Task.sleep(for: .milliseconds(50))
        let disconnected = connectionService.session == nil
        await connectionService.connect(to: station)
        guard let secondSessionID = connectionService.session?.id,
              connectionService.session?.state == .connected else {
            let error = connectionService.error?.localizedDescription ?? "no replacement session"
            endPTT()
            await connectionService.disconnect()
            _ = connectionService.disableLocalDemo()
            NSLog("WATCH_STANDALONE_PTT_RECONNECT_PROBE failed secondConnect=%@",
                  error as NSString)
            return
        }

        let serviceCanTransmitBeforeRetry = connectionService.canTransmit
        let secondBeginAccepted = beginPTT(on: .onWatch)
        let secondSessionPTTActive = connectionService.session?.isPTTActive == true
        releasePTT(cancelTimeout: false, expectedSessionID: firstSessionID)
        let replacementSurvivedOldRelease = connectionService.session?.isPTTActive == true
        endPTT()
        let finalSessionPTTInactive = connectionService.session?.isPTTActive == false
        let passed = firstBeginAccepted
            && firstSessionPTTActive
            && disconnected
            && firstSessionID != secondSessionID
            && serviceCanTransmitBeforeRetry
            && secondBeginAccepted
            && secondSessionPTTActive
            && replacementSurvivedOldRelease
            && finalSessionPTTInactive
        NSLog("WATCH_STANDALONE_PTT_RECONNECT_PROBE %@ firstAccepted=%@ firstServicePTT=%@ disconnected=%@ newSession=%@ canTransmit=%@ retryAccepted=%@ retryServicePTT=%@ oldReleaseSafe=%@ finalPTTInactive=%@",
              passed ? "passed" : "failed",
              (firstBeginAccepted ? "true" : "false") as NSString,
              (firstSessionPTTActive ? "true" : "false") as NSString,
              (disconnected ? "true" : "false") as NSString,
              (firstSessionID != secondSessionID ? "true" : "false") as NSString,
              (serviceCanTransmitBeforeRetry ? "true" : "false") as NSString,
              (secondBeginAccepted ? "true" : "false") as NSString,
              (secondSessionPTTActive ? "true" : "false") as NSString,
              (replacementSurvivedOldRelease ? "true" : "false") as NSString,
              (finalSessionPTTInactive ? "true" : "false") as NSString)

        await connectionService.disconnect()
        _ = connectionService.disableLocalDemo()
#else
        NSLog("WATCH_STANDALONE_PTT_RECONNECT_PROBE skipped reason=simulator_only")
#endif
    }

    /// Exercises the WatchConnectivity receive delegate without activating WCSession.
    /// Each invocation enters through the real delegate method from a worker queue.
    func runModelAudioReceiveProbe() async {
        let priorForeground = isForeground
        let priorSnapshot = companionStatus
        let target = WatchAudioProbeTarget(model: self)
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        var offMainCallbacks = 0
        var callbacks = 0
        var acceptedFrames = 0
        var rejectedFrames = 0
        var expectedRejections = 0
        var foregroundRejections = 0
        var resumedFrames = 0
        let playbackBaseline = phoneAudioPlayer.completedPlaybackBufferCount

        stopPhoneReceiveAudio()
        isForeground = true
        companionStatus = Self.probeSnapshot(sessionID: firstSessionID)
        NSLog("WATCH_MODEL_PROBE started session=%@", firstSessionID.uuidString)

        for sequence in 0..<300 {
            let result = await submitModelProbeFrame(
                streamID: firstSessionID,
                sequence: UInt64(sequence),
                sentAt: Date(),
                target: target
            )
            callbacks += 1
            if result.offMain { offMainCallbacks += 1 }
            if result.accepted { acceptedFrames += 1 } else { rejectedFrames += 1 }
            if sequence.isMultiple(of: 50) {
                NSLog("WATCH_MODEL_PROBE progress frames=%ld accepted=%ld rejected=%ld offMain=%ld",
                      sequence + 1, acceptedFrames, rejectedFrames, offMainCallbacks)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let firstPhaseAccepted = acceptedFrames
        NSLog("WATCH_MODEL_PROBE first_phase accepted=%ld rejected=%ld callbacks=%ld offMain=%ld",
              firstPhaseAccepted, rejectedFrames,
              phoneAudioPlayer.completedPlaybackBufferCount - playbackBaseline,
              offMainCallbacks)

        // receivePhoneAudio's one-second idle stop must reset the player and
        // sequence before a resumed stream can be accepted.
        try? await Task.sleep(for: .milliseconds(1_200))
        for sequence in 300..<315 {
            let result = await submitModelProbeFrame(
                streamID: firstSessionID,
                sequence: UInt64(sequence),
                sentAt: Date(),
                target: target
            )
            callbacks += 1
            if result.offMain { offMainCallbacks += 1 }
            if result.accepted { resumedFrames += 1; acceptedFrames += 1 }
            else { rejectedFrames += 1 }
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Match the production snapshot transition's stop behavior without
        // reading WCSession reachability or sending an application message.
        stopPhoneReceiveAudio()
        companionStatus = Self.probeSnapshot(sessionID: secondSessionID)

        let wrongStream = await submitModelProbeFrame(
            streamID: firstSessionID, sequence: 400, sentAt: Date(), target: target
        )
        callbacks += 1
        if wrongStream.offMain { offMainCallbacks += 1 }
        if !wrongStream.accepted { expectedRejections += 1; rejectedFrames += 1 }

        let stale = await submitModelProbeFrame(
            streamID: secondSessionID, sequence: 401,
            sentAt: Date(timeIntervalSinceNow: -2), target: target
        )
        callbacks += 1
        if stale.offMain { offMainCallbacks += 1 }
        if !stale.accepted { expectedRejections += 1; rejectedFrames += 1 }

        let duplicateData = Self.probeFrameData(
            streamID: secondSessionID, sequence: 402, sentAt: Date()
        )
        let duplicateFirst = await submitModelProbeData(duplicateData, target: target)
        callbacks += 1
        if duplicateFirst.offMain { offMainCallbacks += 1 }
        if duplicateFirst.accepted { acceptedFrames += 1 } else { rejectedFrames += 1 }
        let duplicateSecond = await submitModelProbeData(duplicateData, target: target)
        callbacks += 1
        if duplicateSecond.offMain { offMainCallbacks += 1 }
        if !duplicateSecond.accepted { expectedRejections += 1; rejectedFrames += 1 }

        var sequence: UInt64 = 403
        for cycle in 0..<3 {
            isForeground = false
            stopPhoneReceiveAudio()
            let background = await submitModelProbeFrame(
                streamID: secondSessionID, sequence: sequence, sentAt: Date(), target: target
            )
            callbacks += 1
            sequence += 1
            if background.offMain { offMainCallbacks += 1 }
            if !background.accepted {
                foregroundRejections += 1
                rejectedFrames += 1
            }

            isForeground = true
            let foreground = await submitModelProbeFrame(
                streamID: secondSessionID, sequence: sequence, sentAt: Date(), target: target
            )
            callbacks += 1
            sequence += 1
            if foreground.offMain { offMainCallbacks += 1 }
            if foreground.accepted { acceptedFrames += 1 } else { rejectedFrames += 1 }
            try? await Task.sleep(for: .milliseconds(20))
            NSLog("WATCH_MODEL_PROBE foreground_cycle=%ld backgroundRejected=%@ foregroundAccepted=%@",
                  cycle + 1, (!background.accepted ? "true" : "false") as NSString,
                  (foreground.accepted ? "true" : "false") as NSString)
        }

        let malformed = await submitModelProbeData(Data([0xFF]), target: target)
        callbacks += 1
        if malformed.offMain { offMainCallbacks += 1 }
        if !malformed.accepted { expectedRejections += 1; rejectedFrames += 1 }

        let playedBuffers = phoneAudioPlayer.completedPlaybackBufferCount - playbackBaseline
        let passed = firstPhaseAccepted == 300
            && resumedFrames == 15
            && expectedRejections == 4
            && foregroundRejections == 3
            && callbacks == 326
            && offMainCallbacks == callbacks
            && playedBuffers >= 200
        NSLog("WATCH_MODEL_PROBE %@ firstAccepted=%ld resumed=%ld rejected=%ld expectedRejected=%ld backgroundRejected=%ld callbacks=%ld offMain=%ld played=%ld",
              passed ? "passed" : "failed", firstPhaseAccepted, resumedFrames,
              rejectedFrames, expectedRejections, foregroundRejections,
              callbacks, offMainCallbacks, playedBuffers)

        isForeground = priorForeground
        stopPhoneReceiveAudio()
        companionStatus = priorSnapshot
    }

    private static func probeSnapshot(sessionID: UUID) -> PhoneSessionSnapshot {
        PhoneSessionSnapshot(dictionary: [
            "callsign": "N0PROBE",
            "connected": true,
            "sessionID": sessionID.uuidString,
            "watchAudioOutputEnabled": true
        ])
    }

    private static func probeFrameData(streamID: UUID, sequence: UInt64, sentAt: Date) -> Data {
        let datagramSequence = UInt8(truncatingIfNeeded: sequence)
        var datagram = Data([0x80, 100, 0, datagramSequence, 0, 0, 0, 0, 0, 0, 0, 1])
        datagram.append(Data(repeating: 0xD5, count: 160))
        let frame = WatchAudioFrame(
            version: 1,
            streamID: streamID,
            sequence: sequence,
            sentAt: sentAt,
            datagram: datagram
        )
        return (try? JSONEncoder().encode(frame)) ?? Data()
    }

    private func submitModelProbeFrame(
        streamID: UUID,
        sequence: UInt64,
        sentAt: Date,
        target: WatchAudioProbeTarget
    ) async -> (accepted: Bool, offMain: Bool) {
        await submitModelProbeData(
            Self.probeFrameData(streamID: streamID, sequence: sequence, sentAt: sentAt),
            target: target
        )
    }

    private func submitModelProbeData(
        _ data: Data,
        target: WatchAudioProbeTarget
    ) async -> (accepted: Bool, offMain: Bool) {
        let (reply, offMain) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let callbackWasOffMain = !Thread.isMainThread
                target.model.session(
                    WCSession.default,
                    didReceiveMessageData: data,
                    replyHandler: { reply in
                        continuation.resume(returning: (reply, callbackWasOffMain))
                    }
                )
            }
        }
        return (reply == Data([1]), offMain)
    }
    #endif
}

#if DEBUG
/// Allows the debug probe to call the nonisolated delegate entry from a worker queue.
private final class WatchAudioProbeTarget: @unchecked Sendable {
    let model: WatchAppModel

    init(model: WatchAppModel) { self.model = model }
}

#endif

extension WatchAppModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping (Data) -> Void) {
        let reply = WatchAudioReply(handler: replyHandler)
        Task { @MainActor [weak self] in
            reply.handler(Data([self?.receivePhoneAudio(messageData) == true ? 1 : 0]))
        }
    }
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let snapshot = PhoneSessionSnapshot(dictionary: session.receivedApplicationContext)
        let reachable = session.isReachable
        let account = session.receivedApplicationContext["activeAccount"] as? String
        let favorites = WatchStationSnapshot.list(from: session.receivedApplicationContext["favorites"])
        let recents = WatchStationSnapshot.list(from: session.receivedApplicationContext["recents"])
        Task { @MainActor [weak self] in
            self?.apply(snapshot)
            self?.applyCompanionReachability(reachable)
            self?.applyPhoneStations(
                favorites: favorites,
                recents: recents,
                demo: snapshot.isDemo || account.map(LocalDemoAccount.isDemoUsername) == true
            )
            self?.handlePhoneAccount(account)
            if let error { self?.companionMessage = error.localizedDescription }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let snapshot = PhoneSessionSnapshot(dictionary: applicationContext)
        let account = applicationContext["activeAccount"] as? String
        let favorites = WatchStationSnapshot.list(from: applicationContext["favorites"])
        let recents = WatchStationSnapshot.list(from: applicationContext["recents"])
        Task { @MainActor [weak self] in
            self?.apply(snapshot)
            self?.applyPhoneStations(
                favorites: favorites,
                recents: recents,
                demo: snapshot.isDemo || account.map(LocalDemoAccount.isDemoUsername) == true
            )
            self?.handlePhoneAccount(account)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.applyCompanionReachability(reachable)
        }
    }
}

private struct WatchAudioReply: @unchecked Sendable {
    let handler: (Data) -> Void
}
