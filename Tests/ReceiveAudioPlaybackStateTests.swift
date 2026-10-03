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
}
