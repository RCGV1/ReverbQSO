// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class EchoLinkPTTTransitionTests: XCTestCase {
    func testPressDuringReleaseQueuesRestartWithoutCancellingRelease() {
        XCTAssertTrue(
            EchoLinkPTTTransition.shouldQueuePress(
                isPTTActive: true,
                releaseInProgress: true
            )
        )
    }

    func testOrdinaryPressStartsImmediately() {
        XCTAssertFalse(
            EchoLinkPTTTransition.shouldQueuePress(
                isPTTActive: false,
                releaseInProgress: false
            )
        )
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
@MainActor
final class QSOActivityUpdateQueueTests: XCTestCase {
    func testNewerStateSupersedesWaitingUpdatesWithoutOverlapping() async {
        let firstStarted = expectation(description: "First ActivityKit update started")
        var releaseFirst: CheckedContinuation<Void, Never>?
        var processed: [Int] = []
        let queue = LatestActivityUpdateQueue<Int> { value in
            processed.append(value)
            if value == 1 {
                firstStarted.fulfill()
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                }
            }
        }

        queue.submit(1)
        await fulfillment(of: [firstStarted], timeout: 2)
        queue.submit(2)
        queue.submit(3)
        XCTAssertEqual(processed, [1])

        releaseFirst?.resume()
        await queue.waitUntilIdle()
        XCTAssertEqual(processed, [1, 3])
    }
}
#endif
