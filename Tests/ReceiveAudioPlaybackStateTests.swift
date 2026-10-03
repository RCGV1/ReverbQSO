// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class ReceiveAudioPlaybackStateTests: XCTestCase {
    func testLoudReceivePreservesWaveformInsteadOfHardClipping() {
        var gain = ReceivePlaybackGain()
        let output = gain.process([30_000, 15_000, -30_000, -15_000])
        XCTAssertLessThanOrEqual(abs(output[0]), 0.951)
        XCTAssertEqual(output[1] / output[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(output[2], -output[0], accuracy: 0.0001)
    }

    func testQuietReceiveRetainsBoostAndLimiterRecoversSmoothly() {
        var gain = ReceivePlaybackGain()
        XCTAssertEqual(gain.process([1_000])[0], Float(1_000) / 32768 * 2.5, accuracy: 0.0001)
        _ = gain.process([32_000])
        let afterLoud = gain.process([1_000])[0]
        XCTAssertLessThan(afterLoud, Float(1_000) / 32768 * 2.5)
        for _ in 0..<50 { _ = gain.process([Int16](repeating: 1_000, count: 640)) }
        XCTAssertEqual(gain.process([1_000])[0], Float(1_000) / 32768 * 2.5, accuracy: 0.0001)
        gain.reset()
        XCTAssertEqual(gain.process([1_000])[0], Float(1_000) / 32768 * 2.5, accuracy: 0.0001)
    }

    func testPlaybackBacklogIsBoundedAndStaleCompletionsCannotClearNewAudio() {
        var queue = ReceivePlaybackQueue()
        let oldGeneration = queue.reserve(640)
        _ = queue.reserve(640)
        _ = queue.reserve(640)
        XCTAssertTrue(queue.needsReset(adding: 640))
        queue.reset()
        let newGeneration = queue.reserve(640)
        queue.complete(640, generation: oldGeneration)
        XCTAssertEqual(queue.queuedSamples, 640)
        queue.complete(640, generation: newGeneration)
        XCTAssertEqual(queue.queuedSamples, 0)
    }

    func testNormalPlaybackCompletionFreesCapacityWithoutReset() {
        var queue = ReceivePlaybackQueue()
        let generation = queue.reserve(640)
        XCTAssertFalse(queue.needsReset(adding: 640))
        queue.complete(640, generation: generation)
        XCTAssertFalse(queue.needsReset(adding: queue.maximumSamples))
    }
    func testDelayedCompletionsDoNotTrimHealthyRenderedPlayback() {
        var queue = ReceivePlaybackQueue()
        var end = 0
        var completions: [(time: Double, count: Int, generation: UInt64)] = []
        for index in 0..<100 {
            let now = Double(index) * 0.08
            let rendered = max(0, Int((now - 0.04) * 8_000))
            for completion in completions where completion.time <= now {
                queue.complete(completion.count, generation: completion.generation)
            }
            completions.removeAll { $0.time <= now }
            let remaining = max(0, end - rendered)
            XCTAssertFalse(queue.needsReset(adding: 640, remainingSamples: remaining))
            end = max(end, rendered) + 640
            let generation = queue.reserve(640)
            completions.append((Double(end) / 8_000 + 0.04 + 0.16, 640, generation))
        }
    }

    func testActualRenderedBacklogStillRequiresTrim() {
        var queue = ReceivePlaybackQueue()
        _ = queue.reserve(640)
        XCTAssertTrue(queue.needsReset(adding: 640, remainingSamples: 1_920))
        XCTAssertFalse(queue.needsReset(adding: 640, remainingSamples: 320))
    }

}
