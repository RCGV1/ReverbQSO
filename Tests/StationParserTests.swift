// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class StationParserTests: XCTestCase {
    func testExplicitOnlineStatusOverridesBusyWordsInDescription() throws {
        for description in ["Busy Bee Net [0/20] [ON 12:34]", "Hilltop not busy overnight [ON: 12:34]"] {
            let raw = Data("@@@\n1\nK1OPEN-R\n\(description)\n123\n192.0.2.1\n+++".utf8)
            let station = try XCTUnwrap(StationParser.parseDirectory(raw: raw).first)
            XCTAssertFalse(station.isBusy, description)
            XCTAssertNil(station.connectionUnavailableReason, description)
        }
    }

    func testDirectoryBusyStatusWithTimeIsRecognized() throws {
        let raw = Data("@@@\n2\nK1FULL-R\nHilltop [20/20] [BUSY 12:34]\n123\n192.0.2.1\nK1OPEN-L\nMetro [39/20] [ON 12:34]\n456\n192.0.2.2\n+++".utf8)
        let stations = StationParser.parseDirectory(raw: raw)
        let full = try XCTUnwrap(stations.first)
        XCTAssertTrue(full.isBusy)
        XCTAssertTrue(full.isConnectionLimitReached)
        let open = try XCTUnwrap(stations.last)
        XCTAssertFalse(open.isBusy)
        XCTAssertNil(open.connectionUnavailableReason)
    }

    func testDirectoryRelayMarkerBeforeStatusIdentifiesNonCallableStation() throws {
        let raw = Data("@@@\n2\nK1ABC\nMobile [r] [ON 12:34]\n123\n192.0.2.1\nK2ABC-R\nHilltop [ON 12:34]\n456\n192.0.2.2\n+++".utf8)
        let stations = StationParser.parseDirectory(raw: raw)
        XCTAssertEqual(stations.count, 2)
        XCTAssertTrue(try XCTUnwrap(stations.first).isRelayOnly)
        XCTAssertFalse(try XCTUnwrap(stations.last).isRelayOnly)
    }

    func testSavedStationUsesCurrentRelayEligibilityAndPersistsMarker() throws {
        let saved = Station(callsign: "K1ABC", ipAddress: "192.0.2.1", nodeNumber: 123)
        let relay = Station(callsign: "K1ABC", description: "Mobile [R] [ON 12:34]", ipAddress: "192.0.2.2", nodeNumber: 123)
        let restored = try JSONDecoder().decode(Station.self, from: JSONEncoder().encode(relay))
        XCTAssertTrue(restored.isRelayOnly)
        XCTAssertTrue(try XCTUnwrap(StationEndpointResolver.resolveStored(saved, from: [relay])).isRelayOnly)
        XCTAssertFalse(try XCTUnwrap(StationEndpointResolver.resolveStored(relay, from: [saved])).isRelayOnly)
        XCTAssertFalse(Station(callsign: "K2ABC-R", description: "Repeater [ON 12:34]", ipAddress: "192.0.2.3").isRelayOnly)
    }

    func testStationTypeDecodesLegacyAndUserRawValues() throws {
        XCTAssertEqual(try JSONDecoder().decode(Station.StationType.self, from: Data("\"L\"".utf8)), .link)
        XCTAssertEqual(try JSONDecoder().decode(Station.StationType.self, from: Data("\"U\"".utf8)), .user)
    }
    func testSavedStationReconnectUsesCurrentDirectoryAddress() {
        let saved = Station(callsign: "K1ABC-R", ipAddress: "192.0.2.10", nodeNumber: 12345)
        let current = Station(callsign: "K1ABC-R", ipAddress: "198.51.100.20", nodeNumber: 12345)

        let resolved = StationEndpointResolver.resolve(saved, from: [current])

        XCTAssertEqual(resolved.ipAddress, "198.51.100.20")
    }

    func testSavedStationWithoutNodeNumberMatchesCallsign() {
        let saved = Station(callsign: "k1abc-l", ipAddress: "192.0.2.10")
        let current = Station(callsign: "K1ABC-L", ipAddress: "198.51.100.20", nodeNumber: 456)

        XCTAssertEqual(
            StationEndpointResolver.resolve(saved, from: [current]).ipAddress,
            "198.51.100.20"
        )
    }

    func testSavedStationFallsBackWhenDirectoryHasNoMatch() {
        let saved = Station(callsign: "K1ABC-R", ipAddress: "192.0.2.10", nodeNumber: 12345)
        let unrelated = Station(callsign: "K2XYZ-R", ipAddress: "198.51.100.20", nodeNumber: 67890)

        XCTAssertEqual(StationEndpointResolver.resolve(saved, from: [unrelated]), saved)
    }

    func testStoredReconnectRejectsStationMissingFromCurrentDirectory() {
        let saved = Station(callsign: "K1ABC-R", ipAddress: "192.0.2.10", nodeNumber: 12345)
        let unrelated = Station(callsign: "K2XYZ-R", ipAddress: "198.51.100.20", nodeNumber: 67890)

        XCTAssertNil(StationEndpointResolver.resolveStored(saved, from: [unrelated]))
    }

    func testStoredReconnectUsesCurrentAddressAndBusyStatus() {
        let saved = Station(callsign: "K1ABC-R", ipAddress: "192.0.2.10", nodeNumber: 12345)
        let current = Station(callsign: "K1ABC-R", ipAddress: "198.51.100.20", isBusy: true, nodeNumber: 12345)

        let resolved = StationEndpointResolver.resolveStored(saved, from: [current])

        XCTAssertEqual(resolved?.ipAddress, "198.51.100.20")
        XCTAssertEqual(resolved?.isBusy, true)
    }

    func testNodeNumberDoesNotSelectAnotherCallsign() {
        let saved = Station(callsign: "K1ABC-R", ipAddress: "192.0.2.10", nodeNumber: 12345)
        let unrelated = Station(callsign: "K2XYZ-R", ipAddress: "198.51.100.20", nodeNumber: 12345)
        let current = Station(callsign: "K1ABC-R", ipAddress: "203.0.113.30", nodeNumber: 54321)

        XCTAssertEqual(
            StationEndpointResolver.resolve(saved, from: [unrelated, current]).ipAddress,
            "203.0.113.30"
        )
    }

    private func parseSingle(_ line: String) -> Station? {
        let raw = Data((line + "\n").utf8)
        return StationParser.parseDirectory(raw: raw).first
    }

    // MARK: - Valid Lines

    func testParseLinkStation() {
        let line = "L W6ABC 192.168.1.100 5200"
        let station = parseSingle(line)

        XCTAssertNotNil(station)
        XCTAssertEqual(station?.callsign, "W6ABC")
        XCTAssertEqual(station?.ipAddress, "192.168.1.100")
        XCTAssertEqual(station?.port, 5200)
        XCTAssertEqual(station?.type, .link)
        XCTAssertFalse(station?.isBusy ?? true)
    }

    func testParseRepeaterStation() {
        let line = "R W6DEF-R 10.0.0.1 5200"
        let station = parseSingle(line)

        XCTAssertNotNil(station)
        XCTAssertEqual(station?.callsign, "W6DEF-R")
        XCTAssertEqual(station?.type, .repeater)
        XCTAssertFalse(station?.isBusy ?? true)
    }

    func testParseConferenceStation() {
        let line = "C *BAYNET* 172.16.0.50 5200"
        let station = parseSingle(line)

        XCTAssertNotNil(station)
        XCTAssertEqual(station?.callsign, "*BAYNET*")
        XCTAssertEqual(station?.type, .conference)
        XCTAssertFalse(station?.isBusy ?? true)
    }

    func testParseBusyStation() {
        let line = "X W6GHI 10.1.1.1 5200"
        let station = parseSingle(line)

        XCTAssertNotNil(station)
        XCTAssertEqual(station?.callsign, "W6GHI")
        XCTAssertTrue(station?.isBusy ?? false)
    }

    func testParseBusyRepeaterInferred() {
        let line = "X KJ6ABC-R 10.2.2.2 5200"
        let station = parseSingle(line)

        XCTAssertNotNil(station)
        XCTAssertEqual(station?.type, .repeater)
        XCTAssertTrue(station?.isBusy ?? false)
    }

    // MARK: - Tab-Separated Format

    func testParseTabSeparatedLine() {
        let line = "W6ABC\t192.168.1.100\tSan Francisco, CA"
        let station = parseSingle(line)

        XCTAssertNotNil(station)
        XCTAssertEqual(station?.callsign, "W6ABC")
        XCTAssertEqual(station?.ipAddress, "192.168.1.100")
        XCTAssertEqual(station?.description, "San Francisco, CA")
        XCTAssertEqual(station?.type, .user)
    }

    func testParseTabSeparatedRepeater() {
        let line = "W6ABC-R\t10.0.0.1\tHilltop Repeater"
        let station = parseSingle(line)

        XCTAssertNotNil(station)
        XCTAssertEqual(station?.type, .repeater)
        XCTAssertEqual(station?.description, "Hilltop Repeater")
    }

    // MARK: - Malformed Input

    func testParseEmptyLine() {
        XCTAssertNil(parseSingle(""))
    }

    func testParseWhitespaceLine() {
        XCTAssertNil(parseSingle("   \n"))
    }

    func testParseSingleWord() {
        // A single word with no tabs and fewer than 4 space-separated parts
        XCTAssertNil(parseSingle("HELLO"))
    }

    func testParseTwoWords() {
        XCTAssertNil(parseSingle("L W6ABC"))
    }

    func testParseInvalidPort() {
        // Port is not a number, and there are no tabs, so this should fail
        XCTAssertNil(parseSingle("L W6ABC 10.0.0.1 notaport"))
    }

    // MARK: - Batch Parsing

    func testParseAllMultipleLines() {
        let text = """
        L W6ABC 192.168.1.1 5200
        R W6DEF-R 192.168.1.2 5200
        C *CONF* 192.168.1.3 5200
        X W6GHI 192.168.1.4 5200

        """
        let stations = StationParser.parseDirectory(raw: Data(text.utf8))

        XCTAssertEqual(stations.count, 4)
        XCTAssertEqual(stations[0].type, .link)
        XCTAssertEqual(stations[1].type, .repeater)
        XCTAssertEqual(stations[2].type, .conference)
        XCTAssertTrue(stations[3].isBusy)
    }

    func testParseAllSkipsBlanks() {
        let text = """

        L W6ABC 1.2.3.4 5200

        L W6DEF 5.6.7.8 5200

        """
        let stations = StationParser.parseDirectory(raw: Data(text.utf8))
        XCTAssertEqual(stations.count, 2)
    }

    func testParseCountedDirectoryFormatWithCRLF() {
        let text = "@@@\r\n2\r\nW6ABC-L\r\nHilltop Link\r\n123456\r\n192.168.1.100\r\nN0CALL-R\r\nCounty Repeater\r\n654321\r\n10.0.0.5\r\n+++"
        let stations = StationParser.parseDirectory(raw: Data(text.utf8))

        XCTAssertEqual(stations.count, 2)
        guard stations.count == 2 else { return }
        XCTAssertEqual(stations[0].callsign, "W6ABC-L")
        XCTAssertEqual(stations[0].type, .link)
        XCTAssertEqual(stations[1].callsign, "N0CALL-R")
        XCTAssertEqual(stations[1].type, .repeater)
    }

    func testCountedDirectoryWithIntMaxCountParsesAvailableStation() {
        let text = "@@@\n\(Int.max)\nW6ABC\nSan Francisco\n123456\n192.0.2.10\n+++"

        let stations = StationParser.parseDirectory(raw: Data(text.utf8))

        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(stations.first?.callsign, "W6ABC")
    }

    func testParseCountedDirectoryClassifiesUnsuffixedCallsignAsUser() {
        let text = "@@@\n1\nW6ABC\nSan Francisco\n123456\n192.0.2.10\n+++"

        let stations = StationParser.parseDirectory(raw: Data(text.utf8))

        XCTAssertEqual(stations.first?.type, .user)
    }

    func testParseCountedDirectoryFormatWithZeroStationsReturnsEmptyList() {
        let text = "@@@\n0\n+++"
        let stations = StationParser.parseDirectory(raw: Data(text.utf8))

        XCTAssertTrue(stations.isEmpty)
    }

    func testParseCountedDirectoryFormatWithZeroStationsAndCRLFReturnsEmptyList() {
        let text = "@@@\r\n0\r\n+++"
        let stations = StationParser.parseDirectory(raw: Data(text.utf8))

        XCTAssertTrue(stations.isEmpty)
    }

    func testEmptyCountedDirectoryRequiresTerminatorImmediatelyAfterCount() {
        XCTAssertFalse(StationParser.isValidEmptyCountedDirectory(raw: Data("@@@\n0\nUnexpected station data\n+++".utf8)))
        XCTAssertFalse(StationParser.isValidEmptyCountedDirectory(raw: Data("@@@\n0\n+++ in prose".utf8)))
    }

    func testValidEmptyCountedDirectoryRecognizesLFAndCRLFResponses() {
        XCTAssertTrue(StationParser.isValidEmptyCountedDirectory(raw: Data("@@@\n0\n+++".utf8)))
        XCTAssertTrue(StationParser.isValidEmptyCountedDirectory(raw: Data("@@@\r\n0\r\n+++".utf8)))
        XCTAssertFalse(StationParser.isValidEmptyCountedDirectory(raw: Data("@@@\n2\nW6ABC\nDesc\n1\n1.2.3.4\n+++".utf8)))
    }
}

final class ProxySettingsPersistenceTests: XCTestCase {
    func testAutomaticPublicProxyClearsAnOldPreferredServer() {
        let suite = "ProxySettingsPersistenceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("stale.example.org", forKey: EchoLinkProxyConfiguration.publicHostKey)

        XCTAssertTrue(ProxySettingsPersistence.save(
            mode: .publicProxy,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            publicProxy: nil,
            password: "",
            defaults: defaults,
            savePassword: { _ in XCTFail("Public proxy must not save a password"); return false }
        ))
        let configuration = EchoLinkProxyConfiguration.load(defaults: defaults)
        XCTAssertEqual(configuration.mode, .publicProxy)
        XCTAssertEqual(configuration.host, "")
        XCTAssertEqual(configuration.password, "PUBLIC")
    }

    func testRelayModeDoesNotSaveProxyPasswordOrEnableLegacyProxyFlag() {
        let suite = "ProxySettingsPersistenceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var savedPassword = false

        XCTAssertTrue(ProxySettingsPersistence.save(
            mode: .relay,
            host: "",
            port: 8100,
            publicProxy: nil,
            password: "",
            defaults: defaults,
            savePassword: { _ in savedPassword = true; return true }
        ))
        XCTAssertFalse(savedPassword)
        XCTAssertFalse(defaults.bool(forKey: EchoLinkProxyConfiguration.enabledKey))
        XCTAssertEqual(EchoLinkProxyConfiguration.load(defaults: defaults).mode, .relay)
        XCTAssertFalse(EchoLinkProxyConfiguration.load(defaults: defaults).isEnabled)
    }

    func testFailedKeychainSaveLeavesPreviouslySelectedModeAndHostIntact() {
        let suite = "ProxySettingsPersistenceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(EchoLinkNetworkMode.direct.rawValue, forKey: EchoLinkProxyConfiguration.modeKey)
        defaults.set("old.example.org", forKey: EchoLinkProxyConfiguration.hostKey)

        let saved = ProxySettingsPersistence.save(
            mode: .customProxy,
            host: "new.example.org",
            port: 8100,
            publicProxy: nil,
            password: "secret",
            defaults: defaults,
            savePassword: { _ in false }
        )

        XCTAssertFalse(saved)
        XCTAssertEqual(defaults.string(forKey: EchoLinkProxyConfiguration.modeKey), EchoLinkNetworkMode.direct.rawValue)
        XCTAssertEqual(defaults.string(forKey: EchoLinkProxyConfiguration.hostKey), "old.example.org")
    }
}
