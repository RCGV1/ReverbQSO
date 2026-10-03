// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import GameController
import XCTest
@testable import ReverbQSO

@MainActor
final class SpacePTTReleaseMonitorTests: XCTestCase {
    func testHardwareReleaseEndsHoldWhenSwiftUIKeyUpIsMissing() {
        let monitor = SpacePTTReleaseMonitor.shared
        var transmitting = true
        let subscription = monitor.releases.sink { transmitting = false }

        // No SwiftUI key-up callback is delivered after the hold begins.
        monitor.keyChanged(.spacebar, isPressed: false)

        XCTAssertFalse(transmitting)
        withExtendedLifetime(subscription) {}
    }

    func testPressesRepeatsAndOtherKeyReleasesDoNotEndHold() {
        let monitor = SpacePTTReleaseMonitor.shared
        var transmitting = true
        let subscription = monitor.releases.sink { transmitting = false }
        monitor.keyChanged(.spacebar, isPressed: true)
        monitor.keyChanged(.spacebar, isPressed: true)
        monitor.keyChanged(.keyA, isPressed: false)
        XCTAssertTrue(transmitting)
        withExtendedLifetime(subscription) {}
    }
}
