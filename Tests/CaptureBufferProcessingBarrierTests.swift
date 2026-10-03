// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class CaptureBufferProcessingBarrierTests: XCTestCase {
    func testCompletedDSPDoesNotRejectFreshSpeechDuringTwoHundredMillisecondDeliveryStall() {
        for rate in [8_000.0, 16_000.0, 44_100.0, 48_000.0, 96_000.0] {
            let barrier = CaptureBufferProcessingBarrier()
            let interval = Double(LiveCaptureBacklogPolicy.tapFrames(sampleRate: rate)) / rate
            var codecSamples = 0
            for callback in 0..<10 {
                let capturedAt = Double(callback) * interval
                XCTAssertTrue(LiveCaptureBacklogPolicy.isFresh(capturedAt: capturedAt, now: 0.2))
                XCTAssertTrue(barrier.enter(), "Fresh callback \(callback) rejected at \(rate) Hz")
                barrier.finishDSP()
                codecSamples += 160
            }
            XCTAssertEqual(codecSamples, 1_600)
            XCTAssertEqual(barrier.snapshot.pendingDSP, 0)
            XCTAssertEqual(barrier.snapshot.pendingDelivery, 10)
            XCTAssertEqual(barrier.snapshot.rejectedBuffers, 0)
            for _ in 0..<10 { barrier.leave() }
        }
    }

    func testDSPAndDeliveryEachRemainBounded() {
        let dsp = CaptureBufferProcessingBarrier()
        for _ in 0..<LiveCaptureBacklogPolicy.maximumPendingBuffers { XCTAssertTrue(dsp.enter()) }
        XCTAssertFalse(dsp.enter())
        for _ in 0..<LiveCaptureBacklogPolicy.maximumPendingBuffers { dsp.finishDSP(); dsp.leave() }

        let delivery = CaptureBufferProcessingBarrier()
        for _ in 0..<LiveCaptureBacklogPolicy.maximumPendingDeliveries {
            XCTAssertTrue(delivery.enter())
            delivery.finishDSP()
        }
        XCTAssertFalse(delivery.enter())
        XCTAssertEqual(delivery.snapshot.rejectedBuffers, 1)
        delivery.leave()
        XCTAssertTrue(delivery.enter())
        delivery.finishDSP()
        for _ in 0..<LiveCaptureBacklogPolicy.maximumPendingDeliveries { delivery.leave() }
    }

    func testReleaseWaitsForDSPAndDeliveryAndRejectsNewAdmissions() async {
        let barrier = CaptureBufferProcessingBarrier()
        XCTAssertTrue(barrier.enter())
        let drained = expectation(description: "DSP and delivery drained")
        let completion = ReleaseCompletion()
        let release = Task {
            await barrier.sealAndWait()
            await completion.markFinished()
            drained.fulfill()
        }
        while !barrier.snapshot.isSealed { await Task.yield() }
        XCTAssertFalse(barrier.enter())
        XCTAssertEqual(barrier.snapshot.pendingDSP, 1)
        XCTAssertEqual(barrier.snapshot.pendingDelivery, 1)
        barrier.finishDSP()
        XCTAssertEqual(barrier.snapshot.pendingDSP, 0)
        XCTAssertEqual(barrier.snapshot.pendingDelivery, 1)
        // Give a mistakenly resumed waiter time to execute before checking.
        try? await Task.sleep(for: .milliseconds(20))
        let prematurelyFinished = await completion.finished
        XCTAssertFalse(prematurelyFinished, "DSP completion cannot overtake MainActor delivery")
        barrier.leave()
        await fulfillment(of: [drained], timeout: 1)
        await release.value
        XCTAssertEqual(barrier.snapshot.pendingDelivery, 0)
    }

    func testEmptySealedBarrierReturnsImmediatelyAndStaysClosed() async {
        let barrier = CaptureBufferProcessingBarrier()
        await barrier.sealAndWait()
        XCTAssertFalse(barrier.enter())
        XCTAssertTrue(barrier.snapshot.isSealed)
        XCTAssertEqual(barrier.snapshot.rejectedBuffers, 0)
    }
}

private actor ReleaseCompletion {
    private(set) var finished = false
    func markFinished() { finished = true }
}
