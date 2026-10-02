// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class LocalDemoAccountTests: XCTestCase {
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
