// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class LiveCaptureBacklogPolicyTests: XCTestCase {
    func testCaptureRequestsTwentyMillisecondsAtEveryHardwareRate() {
        for rate in [8_000.0, 16_000.0, 44_100.0, 48_000.0, 96_000.0] {
            XCTAssertEqual(Double(LiveCaptureBacklogPolicy.tapFrames(sampleRate: rate)) / rate,
                           0.02, accuracy: 0.0001)
        }
        XCTAssertEqual(LiveCaptureBacklogPolicy.tapFrames(sampleRate: .nan), 160)
    }
    func testStalledMainActorCannotAccumulateUnlimitedCaptureTasks() {
        XCTAssertTrue(LiveCaptureBacklogPolicy.canAccept(pending: 0))
        XCTAssertTrue(LiveCaptureBacklogPolicy.canAccept(pending: 7))
        XCTAssertFalse(LiveCaptureBacklogPolicy.canAccept(pending: 8))
        XCTAssertFalse(LiveCaptureBacklogPolicy.canAccept(pending: 100))
    }

    func testOldCaptureIsNotEncodedAsDelayedSpeech() {
        XCTAssertTrue(LiveCaptureBacklogPolicy.isFresh(capturedAt: 10, now: 10.2))
        XCTAssertFalse(LiveCaptureBacklogPolicy.isFresh(capturedAt: 10, now: 10.5))
        XCTAssertFalse(LiveCaptureBacklogPolicy.isFresh(capturedAt: .nan, now: 10))
        XCTAssertFalse(LiveCaptureBacklogPolicy.isFresh(capturedAt: 11, now: 10))
    }
}
