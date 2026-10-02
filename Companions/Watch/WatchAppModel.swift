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
    let connectionService = EchoLinkConnectionService()

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
    private var pttWatchdogTask: Task<Void, Never>?
    private var linkedPhoneCallsign: String?
    private var phoneAccountHint: String?
    private var credentialRequestInFlight = false
    private var authenticationGeneration = 0
    private var isDemoLogin = false
    private var didRunDemoReconnectProbe = false

    override init() {
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
        linkedPhoneCallsign = UserDefaults.standard.string(forKey: Self.linkedPhoneCallsignKey)
        localRecents = Self.loadStations(forKey: Self.localRecentsKey)
        phoneFavorites = Self.loadStations(forKey: Self.phoneFavoritesKey)
        phoneRecents = Self.loadStations(forKey: Self.phoneRecentsKey)
        super.init()
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
    }

    func signOut() async {
        authenticationGeneration += 1
        isLoggingIn = false
        linkedPhoneCallsign = nil
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
        guard WCSession.isSupported(), WCSession.default.isReachable,
              !credentialRequestInFlight else { return }
        credentialRequestInFlight = true
        sendCredentialRequest(generation: authenticationGeneration)
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
            Task { @MainActor [weak self] in self?.credentialRequestInFlight = false }
        }
    }

    private func handleCredentialReply(
        generation: Int, ok: Bool, callsign: String?, password: String?,
        demo: Bool
    ) async {
        credentialRequestInFlight = false
        guard generation == authenticationGeneration else { return }
        guard ok, let callsign, let password, !callsign.isEmpty, !password.isEmpty else {
            return
        }
        guard phoneAccountHint == nil || phoneAccountHint == callsign else {
            if phoneAccountHint?.isEmpty == false { requestPhoneCredentials() }
            return
        }
        if linkedPhoneCallsign == callsign && isWatchLoggedIn {
            runDemoReconnectProbeIfRequested()
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
        guard let account else { return }
        phoneAccountHint = account
        if account.isEmpty {
            applyPhoneStations(favorites: [], recents: [])
        } else if isCompanionReachable && (linkedPhoneCallsign != account || !isWatchLoggedIn) {
            requestPhoneCredentials()
        }
    }

    func connect(to station: Station, destination: WatchControlMode? = nil, savedStation: Bool = false) async {
        connectionError = nil
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
        let backend: any CallCQBackend
        if isLocalDemoMode {
            backend = DemoCallCQBackend(
                stations: LocalDemoAccount.stations,
                policy: CallAccessPolicyStore.load(demo: true)
            )
        } else {
            do {
                backend = try directoryService.makeLiveCallCQBackend(
                    callsign: callsign,
                    preferences: preferences,
                    recentCallsigns: localRecents.filter { $0.type != .conference }.map(\.callsign),
                    policy: CallAccessPolicyStore.load()
                )
            } catch {
                backend = FailingCallCQBackend(error: error)
            }
        }
        let service = CallCQService(backend: backend)
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
        guard isCompanionReachable else {
            companionMessage = "Bring iPhone nearby to control its session."
            return
        }
        sendPhoneCommand(["command": "disconnect"])
        companionMessage = "Disconnecting iPhone session…"
    }

    private func beginPTT(in mode: WatchControlMode) -> Bool {
        guard activePTTMode == nil else { return true }

        switch mode {
        case .onWatch:
            guard connectionService.canTransmit else { return false }
            activePTTMode = .onWatch
            connectionService.sendPTT(active: true)
        case .iPhone:
            guard isCompanionReachable, phoneCanTransmit else { return false }
            activePTTMode = .iPhone
            sendPhoneCommand(["command": "ptt", "active": true])
        }
        schedulePTTWatchdog()
        return true
    }

    private func releasePTT(cancelTimeout: Bool) {
        if cancelTimeout {
            pttWatchdogTask?.cancel()
        }
        pttWatchdogTask = nil
        guard let mode = activePTTMode else { return }
        activePTTMode = nil

        switch mode {
        case .onWatch:
            connectionService.sendPTT(active: false)
        case .iPhone:
            sendPhoneCommand(["command": "ptt", "active": false])
        }
    }

    private func schedulePTTWatchdog() {
        pttWatchdogTask?.cancel()
        pttWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.releasePTT(cancelTimeout: false)
        }
    }

    private func sendPhoneCommand(_ command: [String: Any]) {
        guard WCSession.isSupported(), WCSession.default.isReachable else {
            companionMessage = "iPhone is not reachable."
            if (command["active"] as? Bool) == true { activePTTMode = nil }
            return
        }
        dispatchPhoneCommand(
            command,
            startsPTT: (command["active"] as? Bool) == true,
            connects: (command["command"] as? String) == "connect"
        )
    }

    private nonisolated func dispatchPhoneCommand(_ command: [String: Any], startsPTT: Bool, connects: Bool) {
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
                if let snapshot { self?.apply(snapshot) }
                self?.applyPhoneStations(
                    favorites: favorites,
                    recents: recents,
                    demo: demo || account.map(LocalDemoAccount.isDemoUsername) == true
                )
                self?.companionMessage = message
                if connects { self?.connectionError = message }
                if !startAccepted { self?.clearFailedPhonePTTStart() }
            }
        } errorHandler: { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.companionMessage = message
                if connects { self?.connectionError = message }
                if startsPTT { self?.clearFailedPhonePTTStart() }
            }
        }
    }

    private func clearFailedPhonePTTStart() {
        guard activePTTMode == .iPhone else { return }
        pttWatchdogTask?.cancel()
        pttWatchdogTask = nil
        activePTTMode = nil
    }

    private func applyCompanionReachability(_ reachable: Bool) {
        isCompanionReachable = reachable
        if reachable {
            requestPhoneCredentials()
            return
        }
        clearFailedPhonePTTStart()
        companionStatus.isTransmitting = false
        companionStatus.isRemoteTransmitting = false
    }

    private func apply(_ snapshot: PhoneSessionSnapshot) {
        companionStatus = snapshot
        isCompanionReachable = WCSession.default.isReachable
        if !isCompanionReachable {
            clearFailedPhonePTTStart()
            companionStatus.isTransmitting = false
            companionStatus.isRemoteTransmitting = false
        }
        if snapshot.connected {
            companionMessage = nil
        } else if activePTTMode == .iPhone {
            releasePTT(cancelTimeout: true)
        }
    }
}

struct PhoneSessionSnapshot: Sendable {
    var callsign = ""
    var connected = false
    var isTransmitting = false
    var isRemoteTransmitting = false
    var isDemo = false

    init() {}

    init(dictionary: [String: Any]) {
        callsign = dictionary["callsign"] as? String ?? ""
        connected = dictionary["connected"] as? Bool ?? false
        isTransmitting = dictionary["isTransmitting"] as? Bool ?? false
        isRemoteTransmitting = dictionary["isRemoteTransmitting"] as? Bool ?? false
        isDemo = dictionary["demo"] as? Bool ?? false
    }
}

struct WatchStationSnapshot: Sendable {
    let callsign: String
    let nodeNumber: Int
    let type: String
    let description: String

    init?(dictionary: [String: Any]) {
        guard let callsign = dictionary["callsign"] as? String,
              !callsign.isEmpty,
              let nodeNumber = dictionary["nodeNumber"] as? Int,
              let type = dictionary["type"] as? String,
              Station.StationType(rawValue: type) != nil else { return nil }
        self.callsign = callsign
        self.nodeNumber = nodeNumber
        self.type = type
        description = dictionary["description"] as? String ?? ""
    }

    var station: Station {
        Station(
            callsign: callsign,
            description: description,
            ipAddress: "",
            type: Station.StationType(rawValue: type) ?? .user,
            nodeNumber: nodeNumber
        )
    }

    static func list(from value: Any?) -> [WatchStationSnapshot]? {
        guard let rows = value as? [[String: Any]] else { return nil }
        return rows.compactMap(WatchStationSnapshot.init(dictionary:))
    }
}

extension WatchAppModel: WCSessionDelegate {
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
