// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class QSOHubTests: XCTestCase {
    func testBackgroundExpirationPreservesExistingAndOtherAccountAttempts() async {
        let mode = EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
        let hub = QSOHub(primary: EchoLinkConnectionService(), networkConfigurationProvider: { mode },
            connectOperation: { service, station in service.session = QSOSession(station: station) })
        let existing = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let existingIDs = Set(hub.entries.map(\.id))
        let otherAccount = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")
        hub.cancelPendingConnection(as: "n0aaa", excluding: existingIDs)
        XCTAssertEqual(existing.session?.state, .connecting)
        XCTAssertEqual(otherAccount.session?.state, .connecting)
        hub.cancelPendingConnection(as: "n0bbb", excluding: existingIDs)
        XCTAssertNil(otherAccount.session)
        XCTAssertEqual(existing.session?.state, .connecting)
        await hub.disconnectAll()
    }

    func testAutomaticDirectAccountsShareTheDirectPortConcurrencyLimit() async {
        let preference = EchoLinkProxyConfiguration(mode: .automatic, host: "", port: 8100, password: "PUBLIC")
        let effective = EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "")
        let selection = EchoLinkEffectiveTransport(preference: preference, configuration: effective, relayAddress: nil)
        let hub = QSOHub(primary: EchoLinkConnectionService(), networkConfigurationProvider: { preference }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })
        hub.effectiveTransportProvider = { _ in selection }
        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let rejected = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")
        XCTAssertEqual(hub.entries.map(\.mode), [.direct])
        XCTAssertNil(rejected.session)
        XCTAssertTrue(hub.lastError?.contains("Direct mode supports one active QSO") == true)
    }

    func testAccountsUseTheirFrozenEffectiveModesAfterPreferenceChanges() async {
        let automatic = EchoLinkProxyConfiguration(mode: .automatic, host: "", port: 8100, password: "PUBLIC")
        let currentPreference = EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "")
        let hub = QSOHub(primary: EchoLinkConnectionService(), networkConfigurationProvider: { currentPreference }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })
        hub.effectiveTransportProvider = { account in
            let mode: EchoLinkNetworkMode = account == "N0AAA" ? .relay : .publicProxy
            return EchoLinkEffectiveTransport(preference: automatic,
                configuration: EchoLinkProxyConfiguration(mode: mode, host: "proxy.example", port: 8100, password: "PUBLIC"),
                relayAddress: mode == .relay ? "198.51.100.7" : nil)
        }
        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        _ = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")
        XCTAssertEqual(hub.entries.map(\.mode), [.relay, .publicProxy])
    }

    func testTwoCallsKeepSeparateServicesAndOnlySelectedCallCanTransmit() async {
        let primary = EchoLinkConnectionService()
        let relay = EchoLinkProxyConfiguration(
            mode: .relay,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: ""
        )
        let hub = QSOHub(primary: primary, networkConfigurationProvider: { relay }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })
        let firstStation = Station(callsign: "TEST-A", ipAddress: "127.0.0.1")
        let secondStation = Station(callsign: "TEST-B", ipAddress: "127.0.0.2")

        let first = await hub.connect(to: firstStation, as: "N0AAA")
        let second = await hub.connect(to: secondStation, as: "N0BBB")

        XCTAssertTrue(first === primary)
        XCTAssertFalse(second === primary)
        XCTAssertEqual(hub.entries.count, 2)
        XCTAssertEqual(hub.entries[1].mode, .relay)
        XCTAssertEqual(first.localCallsign, "N0AAA")
        XCTAssertEqual(second.localCallsign, "N0BBB")
        XCTAssertFalse(first.canTransmit)
        XCTAssertTrue(second.canTransmit)
        XCTAssertFalse(first.hasAudioFocus)
        XCTAssertTrue(second.hasAudioFocus)

        hub.select(hub.entries[0].id)
        XCTAssertTrue(first.canTransmit)
        XCTAssertFalse(second.canTransmit)
        XCTAssertTrue(first.hasAudioFocus)
        XCTAssertFalse(second.hasAudioFocus)
    }

    func testSecondDirectCallIsRejectedInsteadOfSilentlyUsingRelay() async {
        let direct = EchoLinkProxyConfiguration(
            mode: .direct,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: ""
        )
        let hub = QSOHub(
            primary: EchoLinkConnectionService(),
            networkConfigurationProvider: { direct },
            connectOperation: { service, station in
                service.installSimulatorDemoSession(station: station)
            }
        )

        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let rejected = await hub.connect(
            to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"),
            as: "N0AAA"
        )

        XCTAssertEqual(hub.entries.count, 1)
        XCTAssertNil(rejected.session)
        XCTAssertEqual(hub.entries.map(\.mode), [.direct])
        XCTAssertTrue(hub.lastError?.contains("Direct mode supports one active QSO") == true)
    }

    func testAdoptsExternallyCreatedPrimaryAlongsideExistingCall() async {
        let primary = EchoLinkConnectionService()
        primary.authenticatedCallsign = "N0PRIMARY"
        primary.installSimulatorDemoSession(
            station: Station(callsign: "PRIMARY", ipAddress: "127.0.0.1")
        )
        let relay = EchoLinkProxyConfiguration(
            mode: .relay,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: ""
        )
        let hub = QSOHub(primary: primary, networkConfigurationProvider: { relay }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })

        let secondary = await hub.connect(
            to: Station(callsign: "SECONDARY", ipAddress: "127.0.0.2"),
            as: "N0SECONDARY"
        )
        await Task.yield()

        XCTAssertEqual(hub.entries.count, 2)
        XCTAssertTrue(hub.entries.contains { $0.service === primary && $0.callsign == "N0PRIMARY" })
        XCTAssertTrue(hub.entries.contains { $0.service === secondary && $0.callsign == "N0SECONDARY" })
        XCTAssertTrue(hub.activeService === secondary)
        XCTAssertFalse(primary.canTransmit)
        XCTAssertTrue(secondary.canTransmit)
    }

    func testSecondAccountKeepsSelectedProxyTransport() async {
        let proxy = EchoLinkProxyConfiguration(
            mode: .publicProxy,
            host: "proxy.example",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: "PUBLIC"
        )
        let hub = QSOHub(primary: EchoLinkConnectionService(), networkConfigurationProvider: { proxy }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })
        _ = await hub.connect(
            to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"),
            as: "N0AAA"
        )
        _ = await hub.connect(
            to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"),
            as: "N0BBB"
        )

        XCTAssertEqual(hub.entries.map(\.mode), [.publicProxy, .publicProxy])
    }

    func testSecondProxyCallForSameAccountIsRejectedInsteadOfUsingRelay() async {
        let proxy = EchoLinkProxyConfiguration(
            mode: .publicProxy,
            host: "proxy.example",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: "PUBLIC"
        )
        let hub = QSOHub(
            primary: EchoLinkConnectionService(),
            networkConfigurationProvider: { proxy },
            connectOperation: { service, station in
                service.installSimulatorDemoSession(station: station)
            }
        )

        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let rejected = await hub.connect(
            to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"),
            as: "n0aaa"
        )

        XCTAssertEqual(hub.entries.count, 1)
        XCTAssertNil(rejected.session)
        XCTAssertEqual(hub.entries.map(\.mode), [.publicProxy])
        XCTAssertTrue(hub.lastError?.contains("already has an active QSO") == true)
    }

    func testSecondRelayCallForSameAccountIsRejected() async {
        let relay = EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
        let hub = QSOHub(
            primary: EchoLinkConnectionService(),
            networkConfigurationProvider: { relay },
            connectOperation: { service, station in service.installSimulatorDemoSession(station: station) }
        )

        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let rejected = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "n0aaa")

        XCTAssertEqual(hub.entries.count, 1)
        XCTAssertNil(rejected.session)
        XCTAssertTrue(hub.lastError?.contains("already has an active QSO") == true)
    }

    func testReusedPrimaryCannotBypassActiveCallsignCheck() async {
        let relay = EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
        let hub = QSOHub(
            primary: EchoLinkConnectionService(),
            networkConfigurationProvider: { relay },
            connectOperation: { service, station in service.installSimulatorDemoSession(station: station) }
        )
        let first = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        _ = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")
        await first.disconnect()
        for _ in 0..<10 where hub.entries.count > 1 { await Task.yield() }

        XCTAssertEqual(hub.entries.count, 1)
        let rejected = await hub.connect(to: Station(callsign: "TEST-C", ipAddress: "127.0.0.3"), as: "N0BBB")
        XCTAssertNil(rejected.session)
        XCTAssertEqual(hub.entries.count, 1)
        XCTAssertTrue(hub.lastError?.contains("already has an active QSO") == true)
    }

    func testFailedConnectionDoesNotRemainInHub() async {
        let primary = EchoLinkConnectionService()
        let hub = QSOHub(primary: primary, connectOperation: { _, _ in })

        _ = await hub.connect(
            to: Station(callsign: "UNREACHABLE", ipAddress: "127.0.0.1"),
            as: "N0TEST"
        )

        XCTAssertTrue(hub.entries.isEmpty)
        XCTAssertNil(hub.activeID)
    }
}

@MainActor
final class ConnectionAttemptLifetimeTests: XCTestCase {
    func testCompletionEndsAssertionExactlyOnce() {
        var endings = 0
        var expirations = 0
        var expire: (@MainActor @Sendable () -> Void)?
        let lifetime = ConnectionAttemptLifetime { expirations += 1 }
        lifetime.begin { handler in
            expire = handler
            return { endings += 1 }
        }
        lifetime.end()
        lifetime.end()
        expire?()
        XCTAssertEqual(endings, 1)
        XCTAssertEqual(expirations, 0)
    }

    func testExpirationCancelsBeforeEndingAssertion() {
        var events: [String] = []
        var expire: (@MainActor @Sendable () -> Void)?
        let lifetime = ConnectionAttemptLifetime { events.append("cancel") }
        lifetime.begin { handler in
            expire = handler
            return { events.append("end") }
        }
        expire?()
        expire?()
        lifetime.end()
        XCTAssertEqual(events, ["cancel", "end"])
    }

    func testSynchronousExpirationStillEndsReturnedAssertion() {
        var endings = 0
        var expirations = 0
        let lifetime = ConnectionAttemptLifetime { expirations += 1 }
        lifetime.begin { handler in
            handler()
            return { endings += 1 }
        }
        lifetime.end()
        XCTAssertEqual(expirations, 1)
        XCTAssertEqual(endings, 1)
    }

    func testUnavailableAssertionStillAllowsNormalCompletion() {
        var expired = false
        let lifetime = ConnectionAttemptLifetime { expired = true }
        lifetime.begin { _ in nil }
        lifetime.end()
        XCTAssertFalse(expired)
    }
}
