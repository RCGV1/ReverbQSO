// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class ReceiveAudioPlaybackStateTests: XCTestCase {
    func testConcealmentKeepsRecentSyntheticSpeechWithoutCrowdingReceivedVoice() {
        let queue = ReceivePlaybackQueue()
        let concealed = (0..<1_280).map(Int16.init)
        XCTAssertEqual(Array(queue.retainedConcealment(concealed, receivedSamples: 640, remainingSamples: 0)),
                       Array(concealed.suffix(640)))
        XCTAssertEqual(Array(queue.retainedConcealment(concealed, receivedSamples: 640, remainingSamples: 320)),
                       Array(concealed.suffix(320)))
        XCTAssertTrue(queue.retainedConcealment(concealed, receivedSamples: 640, remainingSamples: 800).isEmpty)
    }

    func testSingleLostPacketRetainsFullConcealmentWithinRecoveryBudget() {
        let queue = ReceivePlaybackQueue()
        let concealed = [Int16](repeating: 1, count: 640)
        XCTAssertEqual(Array(queue.retainedConcealment(concealed, receivedSamples: 640, remainingSamples: 0)), concealed)
        XCTAssertEqual(Array(queue.retainedConcealment(concealed, receivedSamples: 640, remainingSamples: -342)), concealed)
        XCTAssertTrue(queue.retainedConcealment([], receivedSamples: 640, remainingSamples: 0).isEmpty)
    }

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

    func testOverflowPreservesNewestUnrenderedAudioAndDiscardsOnlyExcess() {
        var history = ReceivePlaybackHistory()
        let old = (0..<1_411).map(Float.init)
        let incoming = (10_000..<10_641).map(Float.init)
        history.append(old, startingAt: 0)
        let replacement = history.boundedReplacement(adding: incoming, maximumSamples: 1_936)
        XCTAssertEqual(replacement.discardedSamples, 116)
        XCTAssertEqual(replacement.samples, Array(old.suffix(1_295)) + incoming)
    }

    func testPlaybackHistoryPrunesConsumedSamplesWithoutReplayingThem() {
        var history = ReceivePlaybackHistory()
        history.append([0, 1, 2, 3, 4, 5], startingAt: 100)
        history.prune(renderedSampleTime: 103)
        XCTAssertEqual(history.samples, [3, 4, 5])
        XCTAssertEqual(history.startSampleTime, 103)
        history.append([6, 7], startingAt: 106)
        XCTAssertEqual(history.boundedReplacement(adding: [8, 9], maximumSamples: 6).samples, [4, 5, 6, 7, 8, 9])
        history.prune(renderedSampleTime: 109)
        XCTAssertEqual(history.samples, [])
    }

    func testNegativeRenderPrerollDoesNotInventQueuedAudio() {
        var history = ReceivePlaybackHistory()
        history.append([Float](repeating: 1, count: 1_280), startingAt: 0)
        XCTAssertEqual(history.remainingSamples(renderedSampleTime: -342), 1_280)
        history.prune(renderedSampleTime: -342)
        XCTAssertEqual(history.samples.count, 1_280)
        let queue = ReceivePlaybackQueue()
        XCTAssertFalse(queue.needsReset(adding: 640, remainingSamples: history.remainingSamples(renderedSampleTime: -342)))
    }

    func testBurstReplacementStaysBoundedAndOldGenerationCannotConsumeIt() {
        var history = ReceivePlaybackHistory()
        var queue = ReceivePlaybackQueue()
        history.append([Float](repeating: 1, count: 1_920), startingAt: 0)
        let oldToken = queue.reserve(1_920)
        let replacement = history.boundedReplacement(adding: [Float](repeating: 2, count: 640), maximumSamples: queue.maximumSamples)
        XCTAssertEqual(replacement.samples.count, 1_936)
        XCTAssertEqual(replacement.discardedSamples, 624)
        queue.reset()
        history.reset()
        history.append(replacement.samples, startingAt: 0)
        let newToken = queue.reserve(replacement.samples.count)
        queue.complete(1_920, generation: oldToken)
        XCTAssertEqual(queue.queuedSamples, 1_936)
        XCTAssertEqual(history.samples.suffix(640), [Float](repeating: 2, count: 640)[...])
        queue.complete(1_936, generation: newToken)
        history.prune(renderedSampleTime: 1_936)
        XCTAssertEqual(queue.queuedSamples, 0)
        XCTAssertEqual(history.samples, [])
    }

    func testRecoveryHeadroomPreventsRepeatedResetsDuringOutputPreroll() {
        var queue = ReceivePlaybackQueue()
        var history = ReceivePlaybackHistory()
        history.append([Float](repeating: 1, count: 1_327), startingAt: 0)
        let recovery = history.boundedReplacement(adding: [Float](repeating: 2, count: 641), maximumSamples: queue.recoverySamples)
        XCTAssertEqual(recovery.samples.count, 1_280)
        XCTAssertEqual(recovery.discardedSamples, 688)
        history.reset()
        queue.reset()
        history.append(recovery.samples, startingAt: 0)
        _ = queue.reserve(recovery.samples.count)
        var end = Int64(recovery.samples.count)
        // Model a conservative full packet of startup preroll, then normal
        // playback. Filling the replacement to 1,936 causes a reset at tick 1.
        for tick in 1...100 {
            let rendered = Int64(max(0, tick - 1) * 640)
            history.prune(renderedSampleTime: rendered)
            XCTAssertFalse(queue.needsReset(adding: 640, remainingSamples: history.remainingSamples(renderedSampleTime: rendered)))
            history.append([Float](repeating: Float(tick + 2), count: 640), startingAt: end)
            end += 640
            XCTAssertLessThanOrEqual(history.samples.count, queue.maximumSamples)
        }
    }

}
