// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) && !targetEnvironment(macCatalyst)
import XCTest
@testable import ReverbQSO

@MainActor
final class PTTIntentSelectionTests: XCTestCase {
    func testShortcutFollowsSelectedQSOAndRejectsItsDisconnectedSession() async {
        let primary = EchoLinkConnectionService()
        let relay = EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
        let hub = QSOHub(primary: primary, networkConfigurationProvider: { relay }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })
        let first = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "192.0.2.1"), as: "N0AAA")
        let second = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "192.0.2.2"), as: "N0BBB")
        let bridge = PTTIntentBridge()
        bridge.qsoHub = hub
        XCTAssertTrue(bridge.connectionService === second)
        second.session?.state = .disconnected
        XCTAssertThrowsError(try bridge.toggle())
        XCTAssertFalse(first.session?.isPTTActive == true)

        hub.select(hub.entries[0].id)
        XCTAssertTrue(bridge.connectionService === first)
    }
}
#endif
