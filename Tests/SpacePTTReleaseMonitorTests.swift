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
    func testPhysicalHoldStartsAndEndsWithoutSwiftUIFocusCallbacks() {
        let monitor = SpacePTTReleaseMonitor.shared
        monitor.spaceChanged(isPressed: false, canStart: false)
        var transmitting = false
        var starts = 0
        let down = monitor.presses.sink { transmitting = true; starts += 1 }
        let up = monitor.releases.sink { transmitting = false }
        monitor.spaceChanged(isPressed: true, canStart: true)
        XCTAssertTrue(transmitting)
        monitor.spaceChanged(isPressed: true, canStart: true)
        XCTAssertEqual(starts, 1)
        monitor.spaceChanged(isPressed: false, canStart: false)
        XCTAssertFalse(transmitting)
        withExtendedLifetime((down, up)) {}
    }

    func testSpaceStartedInTextInputCannotStartPTTUntilReleased() {
        let monitor = SpacePTTReleaseMonitor.shared
        monitor.spaceChanged(isPressed: false, canStart: false)
        var starts = 0
        let down = monitor.presses.sink { starts += 1 }
        monitor.spaceChanged(isPressed: true, canStart: false)
        monitor.spaceChanged(isPressed: true, canStart: true)
        XCTAssertEqual(starts, 0)
        monitor.spaceChanged(isPressed: false, canStart: false)
        monitor.spaceChanged(isPressed: true, canStart: true)
        XCTAssertEqual(starts, 1)
        monitor.spaceChanged(isPressed: false, canStart: false)
        withExtendedLifetime(down) {}
    }

    func testOnlyOneRadioCanOwnPhysicalSpaceHold() {
        let monitor = SpacePTTReleaseMonitor.shared
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(monitor.claim(first))
        XCTAssertFalse(monitor.claim(second))
        monitor.release(second)
        XCTAssertFalse(monitor.claim(second))
        monitor.release(first)
        XCTAssertTrue(monitor.claim(second))
        monitor.release(second)
    }

    func testOnlyCurrentOwnerCanCancelHeldSpaceForPresentation() {
        let monitor = SpacePTTReleaseMonitor.shared
        let currentOwner = UUID()
        let otherRadio = UUID()
        var pressCount = 0
        var releaseCount = 0
        let presses = monitor.presses.sink { pressCount += 1 }
        let releases = monitor.releases.sink { releaseCount += 1 }
        defer {
            monitor.release(currentOwner)
            monitor.release(otherRadio)
            monitor.spaceChanged(isPressed: false, canStart: false)
        }

        monitor.spaceChanged(isPressed: false, canStart: false)
        releaseCount = 0
        monitor.spaceChanged(isPressed: true, canStart: true)
        XCTAssertEqual(pressCount, 1)
        XCTAssertTrue(monitor.claim(currentOwner))

        monitor.cancelHold(for: otherRadio)
        XCTAssertEqual(releaseCount, 0, "A different radio must not cancel the current owner's transmission")
        XCTAssertFalse(monitor.claim(otherRadio))

        monitor.cancelHold(for: currentOwner)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertTrue(monitor.claim(otherRadio), "Presentation cancellation must release ownership")

        monitor.spaceChanged(isPressed: true, canStart: true)
        XCTAssertEqual(pressCount, 1, "A held physical key must not restart PTT after cancellation")

        withExtendedLifetime((presses, releases)) {}
    }

}
