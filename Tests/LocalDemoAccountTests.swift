// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import Network
@testable import ReverbQSO

@MainActor
final class LocalDemoAccountTests: XCTestCase {
    func testRemovingAccountDuringSecondaryLoginCannotRestoreCredentialsOrStartContact() async throws {
        try await assertPendingSecondaryLoginIsInvalidated(signingOut: false)
    }

    func testFinalSignOutDuringSecondaryLoginCannotStartHiddenContact() async throws {
        try await assertPendingSecondaryLoginIsInvalidated(signingOut: true)
    }

    func testFinalSignOutFinishesTeardownBeforeOfferingAnotherLogin() async throws {
        let suite = "SignOutLoginTransitionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = try PendingAccountDirectory(holdInitialFetch: false, holdLogoff: true)
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let directory = EchoLinkDirectoryService(
            configurationProvider: { EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "") },
            client: DirectoryClient(host: "127.0.0.1", port: port),
            saveCredentials: { _, _, _ in true }
        )
        var accountLoginAttempts = 0
        var connectRequests: [String] = []
        let app = AppState(
            sessionDefaults: defaults,
            directoryLoginOperation: { target, callsign, password, active in
                if callsign == "N0AAA" {
                    accountLoginAttempts += 1
                    if accountLoginAttempts == 1 {
                        await target.login(callsign: callsign, password: password, persistAsActive: active)
                    } else { target.isLoggedIn = true }
                } else { target.isLoggedIn = true }
            },
            savedAccountActivator: { _ in true },
            savedAccountCallsigns: { ["N0AAA", "N0BBB"] },
            savedAccountPassword: { _ in "test" },
            savedAccountRemoval: { _ in XCTFail("Signing out must retain saved accounts") },
            directoryFactory: { directory },
            qsoConnectOperation: { service, station in
                connectRequests.append(station.callsign)
                service.session = QSOSession(station: station)
            }
        )
        app.qsoHub.effectiveTransportProvider = { _ in
            .explicit(EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: ""))
        }
        app.currentUser = "N0BOOT"
        app.isLoggedIn = true
        await app.login(callsign: "N0AAA", password: "test")
        let signingOut = Task { await app.logout() }
        await fulfillment(of: [server.logoffStarted], timeout: 2)

        let offeredLoginBeforeTeardown = !app.isLoggedIn
        XCTAssertFalse(offeredLoginBeforeTeardown, "Sign in must stay hidden until the previous account finishes teardown")
        XCTAssertEqual(app.currentUser, "N0AAA")
        await app.login(callsign: "N0BBB", password: "test")
        if !offeredLoginBeforeTeardown {
            XCTAssertEqual(app.currentUser, "N0AAA", "Programmatic login must wait for the old account's teardown")
        }
        await app.connect(to: Station(callsign: "TEST-A", ipAddress: "192.0.2.2"), as: "N0AAA")
        XCTAssertEqual(connectRequests, [], "The signing-out account must not start a fresh contact during teardown")
        server.releaseLogoff()
        await signingOut.value
        if !offeredLoginBeforeTeardown { await app.login(callsign: "N0BBB", password: "test") }

        XCTAssertTrue(app.isLoggedIn)
        XCTAssertEqual(app.currentUser, "N0BBB")
        XCTAssertTrue(app.directoryService.isLoggedIn, "Old account cleanup must not clear the next account's login")
        await app.logout()
    }

    private func assertPendingSecondaryLoginIsInvalidated(signingOut: Bool) async throws {
        let suite = "PendingAccountRemovalTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = try PendingAccountDirectory()
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        var accounts = ["N0AAA": "test", "N0BBB": "test"]
        var credentialWrites: [String] = []
        let directory = EchoLinkDirectoryService(
            configurationProvider: { EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "") },
            client: DirectoryClient(host: "127.0.0.1", port: port),
            saveCredentials: { callsign, password, _ in
                credentialWrites.append(callsign)
                accounts[callsign] = password
                return true
            }
        )
        let app = AppState(
            sessionDefaults: defaults,
            directoryLoginOperation: { target, callsign, password, active in
                if callsign == "N0AAA" { target.isLoggedIn = true }
                else { await target.login(callsign: callsign, password: password, persistAsActive: active) }
            },
            savedAccountActivator: { _ in true },
            savedAccountCallsigns: { accounts.keys.sorted() },
            savedAccountPassword: { accounts[$0] },
            savedAccountRemoval: { accounts.removeValue(forKey: $0) },
            directoryFactory: { directory },
            qsoConnectOperation: { service, station in
                service.session = QSOSession(station: station, state: .connected)
            }
        )
        await app.login(callsign: "N0AAA", password: "test")
        let connecting = Task {
            await app.connect(to: Station(callsign: "TEST-B", ipAddress: "192.0.2.2"), as: "N0BBB")
        }
        await fulfillment(of: [server.fetchStarted], timeout: 2)

        if signingOut { await app.logout() }
        else { await app.removeSavedAccount("N0BBB") }
        server.releaseFetch()
        await connecting.value

        if !signingOut {
            XCTAssertNil(accounts["N0BBB"], "A removed account must stay removed after its suspended login returns")
        }
        XCTAssertEqual(credentialWrites, [], "An obsolete login must be invalidated before it saves credentials")
        XCTAssertFalse(directory.isLoggedIn)
        XCTAssertFalse(app.qsoHub.entries.contains { $0.callsign == "N0BBB" })
        XCTAssertEqual(app.currentUser, signingOut ? "" : "N0AAA")
        XCTAssertEqual(app.isLoggedIn, !signingOut)
        await app.qsoHub.disconnectAll()
        await directory.logout()
        await app.logout()
    }

    func testSigningOutCurrentAccountKeepsAnotherAuthenticatedContactAccessible() async throws {
        let suite = "IndependentAccountSignOutTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(
            sessionDefaults: defaults,
            directoryLoginOperation: { directory, _, _, _ in directory.isLoggedIn = true },
            savedAccountActivator: { _ in true },
            savedAccountCallsigns: { ["N0AAA", "N0BBB"] },
            savedAccountPassword: { _ in "test" },
            savedAccountRemoval: { _ in XCTFail("Signing out must retain saved accounts") }
        )
        await app.login(callsign: "N0BBB", password: "test")
        let retainedDirectory = app.directoryService
        let radio = app.connectionService
        radio.authenticatedCallsign = "N0BBB"
        radio.session = QSOSession(station: Station(callsign: "TEST-B", ipAddress: "192.0.2.2"), state: .connected)
        app.qsoHub.adoptExistingPrimary(as: "N0BBB")
        let contactID = app.qsoHub.activeID
        await app.login(callsign: "N0AAA", password: "test")

        await app.logout()

        XCTAssertTrue(app.isLoggedIn, "Another signed-in contact must remain reachable in the main interface")
        XCTAssertEqual(app.currentUser, "N0BBB")
        XCTAssertTrue(app.directoryService === retainedDirectory)
        XCTAssertTrue(app.directoryService.isLoggedIn)
        XCTAssertEqual(app.qsoHub.activeID, contactID)
        XCTAssertEqual(radio.session?.state, .connected)
        XCTAssertTrue(radio.hasAudioFocus)
        XCTAssertFalse(defaults.bool(forKey: AppState.explicitlySignedOutKey))

        await app.logout()
        XCTAssertFalse(app.isLoggedIn, "Signing out the final authenticated account must return to sign in")
        XCTAssertEqual(app.currentUser, "")
        XCTAssertTrue(app.qsoHub.entries.isEmpty)
        XCTAssertNil(radio.session)
        XCTAssertTrue(defaults.bool(forKey: AppState.explicitlySignedOutKey))
    }

#if targetEnvironment(simulator)
    func testApplicationInactiveReleasesPTTWithoutEndingTheContact() async throws {
        let suite = "BackgroundPTTTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(sessionDefaults: defaults)
        await app.login(callsign: "DEMO", password: "demo")
        let station = try XCTUnwrap(LocalDemoAccount.stations.first { $0.callsign != "*ECHOTEST*" })
        await app.connect(to: station)
        let radio = app.qsoHub.activeService
        radio.sendPTT(active: true)
        XCTAssertEqual(radio.session?.isPTTActive, true)

        app.setApplicationActive(false)

        XCTAssertEqual(radio.session?.isPTTActive, false,
            "Losing foreground must release TX even when no gesture-up arrives")
        XCTAssertEqual(radio.session?.state, .connected,
            "Background receive must keep the contact connected")
        await app.logout()
    }
#endif

    func testTemporaryDirectoryLossDoesNotSignOutTheLocalAccount() async {
        let app = AppState()
        app.currentUser = "N0TEST"
        app.isLoggedIn = true
        app.directoryService.isLoggedIn = false
        app.directoryService.error = DirectoryClientError.timeout
        await app.handleCurrentDirectoryLogout()
        XCTAssertTrue(app.isLoggedIn, "A network timeout must not remove the local account session")
        XCTAssertEqual(app.currentUser, "N0TEST")
        XCTAssertNil(app.loginError)
    }

    func testSavedAccountOpensImmediatelyAndTemporaryFailureStaysSignedIn() async {
        let suite = "SavedAccountTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(sessionDefaults: defaults)
        let started = expectation(description: "restoration started")
        var pending: CheckedContinuation<Void, Never>?
        app.restoreSavedAccount(callsign: "n0test", password: "not-a-real-password") { directory, _, _ in
            started.fulfill()
            await withCheckedContinuation { pending = $0 }
            directory.error = DirectoryClientError.timeout
        }
        XCTAssertTrue(app.isLoggedIn, "The main interface must not wait for network registration")
        XCTAssertEqual(app.currentUser, "N0TEST")
        XCTAssertTrue(app.isAutoLoggingIn)
        await fulfillment(of: [started], timeout: 2)
        pending?.resume()
        for _ in 0..<100 where app.isAutoLoggingIn { await Task.yield() }
        XCTAssertFalse(app.isAutoLoggingIn)
        XCTAssertTrue(app.isLoggedIn)
        XCTAssertEqual(app.directoryRecoveryError, DirectoryClientError.timeout.localizedDescription)
        XCTAssertNil(app.loginError)
        await app.logout()
    }

    func testOlderAccountSwitchCannotReplaceNewerActiveAccount() async {
        let suite = "AccountSwitchTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let startedB = expectation(description: "account B sign-in started")
        let startedC = expectation(description: "account C sign-in started")
        var finishB: CheckedContinuation<Void, Never>?
        var finishC: CheckedContinuation<Void, Never>?
        var activeAccountWrites: [String] = []
        let app = AppState(
            sessionDefaults: defaults,
            directoryLoginOperation: { directory, callsign, _, persistAsActive in
                if callsign == "N0BBB" { startedB.fulfill() }
                if callsign == "N0CCC" { startedC.fulfill() }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if callsign == "N0BBB" { finishB = continuation }
                    if callsign == "N0CCC" { finishC = continuation }
                }
                if persistAsActive { activeAccountWrites.append(callsign) }
                directory.isLoggedIn = true
            },
            savedAccountActivator: { callsign in
                activeAccountWrites.append(callsign)
                return true
            }
        )
        app.currentUser = "N0AAA"
        app.isLoggedIn = true

        let loginB = Task { await app.login(callsign: "N0BBB", password: "test") }
        await fulfillment(of: [startedB], timeout: 1)
        let loginC = Task { await app.login(callsign: "N0CCC", password: "test") }
        await fulfillment(of: [startedC], timeout: 1)

        finishC?.resume()
        await loginC.value
        finishB?.resume()
        await loginB.value

        XCTAssertEqual(app.currentUser, "N0CCC")
        XCTAssertEqual(activeAccountWrites, ["N0CCC"],
            "Only the newest completed account switch may become active for auto-login")
    }

    func testOlderAccountSwitchDoesNotClearNewerAuthenticationState() async {
        let suite = "AccountSwitchTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let startedB = expectation(description: "account B sign-in started")
        let startedC = expectation(description: "account C sign-in started")
        var finishB: CheckedContinuation<Void, Never>?
        var finishC: CheckedContinuation<Void, Never>?
        let app = AppState(
            sessionDefaults: defaults,
            directoryLoginOperation: { directory, callsign, _, _ in
                if callsign == "N0BBB" { startedB.fulfill() }
                if callsign == "N0CCC" { startedC.fulfill() }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if callsign == "N0BBB" { finishB = continuation }
                    if callsign == "N0CCC" { finishC = continuation }
                }
                directory.isLoggedIn = true
            },
            savedAccountActivator: { _ in true }
        )
        app.currentUser = "N0AAA"
        app.isLoggedIn = true

        let loginB = Task { await app.login(callsign: "N0BBB", password: "test") }
        await fulfillment(of: [startedB], timeout: 1)
        let loginC = Task { await app.login(callsign: "N0CCC", password: "test") }
        await fulfillment(of: [startedC], timeout: 1)

        finishB?.resume()
        await loginB.value

        XCTAssertTrue(app.isAuthenticating,
            "Finishing an obsolete sign-in must not hide the newer sign-in's progress")

        finishC?.resume()
        await loginC.value

        XCTAssertFalse(app.isAuthenticating)
        XCTAssertEqual(app.currentUser, "N0CCC")
    }

    func testForegroundRestorationRetriesAndExplicitSignOutCancelsIt() async {
        let suite = "SavedAccountTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(sessionDefaults: defaults)
        app.setApplicationActive(true)
        let restored = expectation(description: "temporary failure recovered")
        var attempts = 0
        app.restoreSavedAccount(callsign: "N0TEST", password: "not-a-real-password") { directory, _, _ in
            attempts += 1
            if attempts == 1 { directory.error = DirectoryClientError.timeout }
            else {
                XCTAssertEqual(app.directoryRecoveryError, DirectoryClientError.timeout.localizedDescription,
                    "Keep the recovery state visible while another attempt is running")
                directory.isLoggedIn = true
                directory.error = nil
                restored.fulfill()
            }
        }
        await fulfillment(of: [restored], timeout: 5)
        XCTAssertTrue(app.isLoggedIn)
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(app.directoryRecoveryError)
        await app.logout()
        XCTAssertTrue(defaults.bool(forKey: AppState.explicitlySignedOutKey))
        app.restoreSavedAccount(callsign: "N0TEST", password: "not-a-real-password") { _, _, _ in
            XCTFail("An explicit sign-out must prevent automatic restoration")
        }
        XCTAssertFalse(app.isLoggedIn)
    }

    func testGenuineCredentialRejectionStillRequiresSignIn() async {
        let suite = "SavedAccountTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(sessionDefaults: defaults)
        app.restoreSavedAccount(callsign: "N0TEST", password: "not-a-real-password") { directory, _, _ in
            directory.error = DirectoryClientError.loginDenied
        }
        for _ in 0..<100 where app.isAutoLoggingIn { await Task.yield() }
        XCTAssertFalse(app.isLoggedIn)
        XCTAssertNotNil(app.loginError)
        XCTAssertTrue(defaults.bool(forKey: AppState.explicitlySignedOutKey))
        await app.logout()
    }

    func testSignOutDuringRestorationCannotResurrectTheAccount() async {
        let suite = "SavedAccountTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(sessionDefaults: defaults)
        let started = expectation(description: "restoration started")
        let returned = expectation(description: "obsolete sign-in returned")
        var pending: CheckedContinuation<Void, Never>?
        app.restoreSavedAccount(callsign: "N0TEST", password: "not-a-real-password") { _, _, _ in
            started.fulfill()
            await withCheckedContinuation { pending = $0 }
            returned.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        await app.logout()
        pending?.resume()
        await fulfillment(of: [returned], timeout: 2)
        await Task.yield()
        XCTAssertFalse(app.isLoggedIn)
        XCTAssertFalse(app.isAutoLoggingIn)
        XCTAssertEqual(app.currentUser, "")
    }

    func testReservedLoginUsesNormalAppAndIsolatesRealSavedAccounts() async throws {
        let originalAccounts = KeychainService.savedCallsigns()
        let originalActive = KeychainService.loadCallsign()
        let app = AppState()
        await app.login(callsign: " demo ", password: "demo")
        XCTAssertTrue(app.isLoggedIn)
        XCTAssertTrue(app.isDemoMode)
        XCTAssertEqual(app.currentUser, "DEMO")
        XCTAssertEqual(app.savedAccounts, ["DEMO"])
        XCTAssertEqual(app.directoryService.stations, LocalDemoAccount.stations)
        XCTAssertNotNil(app.directoryService.lastSuccessfulSnapshotAt)
        let refreshed = await app.directoryService.refresh()
        XCTAssertTrue(refreshed)
        await app.connect(to: LocalDemoAccount.stations[0])
        XCTAssertEqual(app.qsoHub.activeService.session?.state, .connected)
        await app.qsoHub.activeService.sendChat(message: "Hello")
        XCTAssertTrue(app.qsoHub.activeService.incomingChatMessages.contains { $0.isOutgoing && $0.body == "Hello" })

        await app.login(callsign: "DEMO2", password: "demo")
        await app.connect(to: LocalDemoAccount.stations[1])
        XCTAssertEqual(app.qsoHub.entries.count, 2)
        XCTAssertTrue(app.qsoHub.entries.allSatisfy { $0.service.isLocalDemoMode })
        XCTAssertEqual(KeychainService.savedCallsigns(), originalAccounts)
        XCTAssertEqual(KeychainService.loadCallsign(), originalActive)
        await app.logout()
        XCTAssertFalse(app.isLoggedIn)
        XCTAssertFalse(app.isDemoMode)
        XCTAssertFalse(app.connectionService.isLocalDemoMode)
        XCTAssertTrue(app.qsoHub.entries.isEmpty)
        XCTAssertEqual(app.savedAccounts, originalAccounts)
        XCTAssertEqual(KeychainService.loadCallsign(), originalActive)
    }

    func testIncorrectPasswordAndLiveAccountNeverLeaveDemoLocally() async {
        let app = AppState()
        await app.login(callsign: "DEMO", password: "incorrect")
        XCTAssertFalse(app.isLoggedIn)
        XCTAssertFalse(app.isDemoMode)
        XCTAssertNotNil(app.loginError)
        await app.login(callsign: "DEMO", password: "demo")
        await app.login(callsign: "W1AW", password: "not-a-real-password")
        XCTAssertEqual(app.currentUser, "DEMO")
        XCTAssertTrue(app.isDemoMode)
        XCTAssertNotNil(app.loginError)
        await app.logout()
    }

    func testLocalDirectoryNeverSelectsTransportOrSavesCredentials() async throws {
        let directory = EchoLinkDirectoryService(localDemoAccount: "DEMO", configurationProvider: {
            XCTFail("Local directory must not read a network preference")
            return LocalDemoAccount.transport.configuration
        }, saveCredentials: { _, _, _ in
            XCTFail("Local directory must not save credentials")
            return false
        })
        await directory.login(callsign: "DEMO", password: "demo")
        XCTAssertTrue(directory.isLoggedIn)
        let available = await directory.setAvailableForCalls(true)
        XCTAssertTrue(available)
        try await directory.advertiseRelay(address: "192.0.2.1")
        await directory.stopAdvertisingRelay(address: "192.0.2.1")
        let proxy = try await directory.prepareProxySession(callsign: "DEMO")
        XCTAssertNil(proxy)
        await directory.logout()
        XCTAssertFalse(directory.isLoggedIn)
    }

    func testFavoritesAndHistoryReturnToOriginalStoreAfterDemo() {
        let suite = "LocalDemoAccountTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let realStation = Station(callsign: "W1AW", ipAddress: "198.51.100.1")
        let favorites = FavoritesViewModel(defaults: defaults)
        let recents = RecentConnectionsService(defaults: defaults)
        favorites.add(realStation)
        recents.record(station: realStation, duration: 12)
        let originalFavorites = defaults.data(forKey: "org.OpenEchoLink.favorites")
        let originalRecents = defaults.data(forKey: "recentConnections")
        favorites.setDemoMode(true)
        recents.setDemoMode(true)
        favorites.add(LocalDemoAccount.stations[1])
        recents.record(station: LocalDemoAccount.stations[1], duration: 30)
        XCTAssertEqual(defaults.data(forKey: "org.OpenEchoLink.favorites"), originalFavorites)
        XCTAssertEqual(defaults.data(forKey: "recentConnections"), originalRecents)
        favorites.setDemoMode(false)
        recents.setDemoMode(false)
        XCTAssertEqual(favorites.favorites, [realStation])
        XCTAssertEqual(recents.recents.map(\.station), [realStation])
    }

    func testNetworkSettingsAreLocalWhileSignedIntoDemo() async {
        let before = UserDefaults.standard.string(forKey: EchoLinkProxyConfiguration.modeKey)
        let settings = SettingsViewModel(loadSettings: false)
        settings.setDemoMode(true)
        settings.networkMode = .publicProxy
        await settings.refreshPublicProxies()
        XCTAssertEqual(settings.publicProxies.first?.host, "192.0.2.20")
        settings.scheduleProxySettingsSave()
        settings.flushPendingSettingsSave()
        XCTAssertEqual(UserDefaults.standard.string(forKey: EchoLinkProxyConfiguration.modeKey), before)
    }
}

private final class PendingAccountDirectory: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "LocalDemoAccountTests.directory")
    let ready = XCTestExpectation(description: "local account directory ready")
    let fetchStarted = XCTestExpectation(description: "secondary account initial fetch suspended")
    let logoffStarted = XCTestExpectation(description: "old account logoff suspended")
    private let holdInitialFetch: Bool
    private var holdLogoff: Bool
    private var pendingFetch: NWConnection?
    private var pendingLogoff: NWConnection?

    init(holdInitialFetch: Bool = true, holdLogoff: Bool = false) throws {
        self.holdInitialFetch = holdInitialFetch
        self.holdLogoff = holdLogoff
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
    }

    func releaseFetch() {
        queue.async {
            guard let connection = self.pendingFetch else { return }
            self.pendingFetch = nil
            self.respond("@@@\n0\n+++", to: connection)
        }
    }

    func releaseLogoff() {
        queue.async {
            self.holdLogoff = false
            guard let connection = self.pendingLogoff else { return }
            self.pendingLogoff = nil
            self.respond("OK\r\n", to: connection)
        }
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let bytes = buffered + data
            let request = String(decoding: bytes, as: UTF8.self)
            if request == "s" {
                if self.holdInitialFetch {
                    self.pendingFetch = connection
                    self.fetchStarted.fulfill()
                } else { self.respond("@@@\n0\n+++", to: connection) }
                return
            }
            if request.hasPrefix("z"), self.holdLogoff {
                self.pendingLogoff = connection
                self.logoffStarted.fulfill()
                return
            }
            if request.hasPrefix("-LOGIN"), !request.contains("\n\n") {
                self.receive(connection, buffered: bytes)
                return
            }
            let response = request.hasPrefix("-LOGIN")
                ? (request.contains("hashed-password:") ? "LOGIN-RESULT\nresult:success\n\n" : "LOGIN-RESULT\nchallenge:local-test\n\n")
                : "OK\r\n"
            self.respond(response, to: connection)
        }
    }

    private func respond(_ response: String, to connection: NWConnection) {
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
