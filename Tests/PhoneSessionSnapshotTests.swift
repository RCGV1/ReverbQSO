// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class PhoneSessionSnapshotTests: XCTestCase {
    func testUnreachableCompanionPreservesConnectedReceiveState() {
        let snapshot = PhoneSessionSnapshot(dictionary: [
            "callsign": "W1AW",
            "connected": true,
            "isRemoteTransmitting": true
        ])

        let unreachable = snapshot.applyingCompanionReachability(false)

        XCTAssertTrue(unreachable.connected)
        XCTAssertTrue(unreachable.isRemoteTransmitting)
        XCTAssertEqual(unreachable.callsign, "W1AW")
    }

    func testUnreachableCompanionClearsLocalTransmitState() {
        let snapshot = PhoneSessionSnapshot(dictionary: [
            "connected": true,
            "isTransmitting": true
        ])

        XCTAssertFalse(snapshot.applyingCompanionReachability(false).isTransmitting)
    }

    func testReachableCompanionPreservesCompleteSnapshot() {
        let snapshot = PhoneSessionSnapshot(dictionary: [
            "callsign": "W1AW",
            "connected": true,
            "isTransmitting": true,
            "isRemoteTransmitting": true,
            "demo": true
        ])

        let reachable = snapshot.applyingCompanionReachability(true)

        XCTAssertEqual(reachable.callsign, "W1AW")
        XCTAssertTrue(reachable.connected)
        XCTAssertTrue(reachable.isTransmitting)
        XCTAssertTrue(reachable.isRemoteTransmitting)
        XCTAssertTrue(reachable.isDemo)
    }
}
