// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class ReceiveAudioPlaybackStateTests: XCTestCase {
    func testPendingDecodedSpeechAlsoReservesConcealmentCapacity() {
        let queue = ReceivePlaybackQueue()
        let synthetic = (0..<1280).map(Int16.init)
        XCTAssertEqual(Array(queue.retainedConcealment(synthetic, receivedSamples: 640,
            remainingSamples: 160, pendingSamples: 320)), Array(synthetic.suffix(160)))
        XCTAssertTrue(queue.retainedConcealment(synthetic, receivedSamples: 640,
            remainingSamples: 0, pendingSamples: 640).isEmpty)
        XCTAssertEqual(queue.concealmentSampleBudget(receivedSamples: 640,
            remainingSamples: Int.max, pendingSamples: Int.max), 0)
    }

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

    func testLaterLoudPeakDoesNotCreateAnEarlierPacketBoundaryClick() {
        var gain = ReceivePlaybackGain()
        let quiet = gainTone { _ in 9_000 }
        let rising = gainTone { index in
            9_000 + 21_000 * min(1, max(0, Double(index - 240) / 160))
        }
        let previous = gain.process(quiet)
        let output = gain.process(rising)
        let step = abs(output[0] - previous[previous.count - 1])

        print("RECEIVE_GAIN_ATTACK_JOIN step=\(step)")
        XCTAssertLessThan(step, 0.005, "A later peak must not turn a continuous join into a click")
        XCTAssertEqual(output[0], Float(rising[0]) / 32768 * 2.5, accuracy: 0.000_001)
        XCTAssertEqual(output.count, rising.count)
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 0.950_001 })
    }

    func testGainRecoveryDoesNotStepAtTheNextQuietPacketBoundary() {
        var gain = ReceivePlaybackGain()
        let falling = gainTone { index in
            30_000 - 21_000 * min(1, max(0, Double(index - 160) / 160))
        }
        let quiet = gainTone { _ in 9_000 }
        let previous = gain.process(falling)
        let output = gain.process(quiet)
        let step = abs(output[0] - previous[previous.count - 1])

        print("RECEIVE_GAIN_RELEASE_JOIN step=\(step)")
        XCTAssertLessThan(step, 0.005, "Release must not apply 80 ms of gain recovery at once")
        XCTAssertEqual(output.count, quiet.count)
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 0.950_001 })
    }

    func testGainReleaseIsIndependentOfLegalPacketPartitioning() {
        let quiet = [Int16](repeating: 9_000, count: 6_400)
        var referenceGain = ReceivePlaybackGain()
        _ = referenceGain.process([Int16](repeating: 30_000, count: 640))
        let reference = referenceGain.process(quiet)

        for packetSize in [80, 160, 320, 640] {
            var gain = ReceivePlaybackGain()
            _ = gain.process([Int16](repeating: 30_000, count: 640))
            var output: [Float] = []
            for offset in stride(from: 0, to: quiet.count, by: packetSize) {
                output += gain.process(Array(quiet[offset..<min(offset + packetSize, quiet.count)]))
            }
            XCTAssertEqual(output.count, reference.count)
            let error = zip(output, reference).map { abs($0 - $1) }.max() ?? 0
            print("RECEIVE_GAIN_PARTITION size=\(packetSize) maxError=\(error)")
            XCTAssertLessThanOrEqual(error, 0.000_001,
                "The same speech must not have different gain envelopes at different packet sizes")
        }
    }

    private func gainTone(amplitude: (Int) -> Double) -> [Int16] {
        (0..<640).map { index in
            Int16((amplitude(index) * cos(2 * .pi * 100 * Double(index) / 8_000)).rounded())
        }
    }

    func testGainTransitionsStayFiniteAndPeakBoundedAcrossBufferSizes() {
        var gain = ReceivePlaybackGain()
        for count in [1, 2, 7, 32, 80, 160, 320, 640, 1_280, 1_920, 1_930] {
            for seed in 0..<12 {
                let samples = (0..<count).map { index -> Int16 in
                    if seed == 0 { return 0 }
                    if seed == 1 { return index.isMultiple(of: 2) ? .min : .max }
                    if seed == 2 { return index == count - 1 ? .max : 9_000 }
                    return Int16(truncatingIfNeeded: index * 7_919 + seed * 12_347)
                }
                let output = gain.process(samples)
                XCTAssertEqual(output.count, samples.count)
                XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 0.950_001 },
                    "Peak protection failed for count=\(count), seed=\(seed)")
                XCTAssertEqual(gain.process([]), [])
            }
        }
    }

    func testPlaybackBacklogIsBoundedAndStaleCompletionsCannotClearNewAudio() {
        var queue = ReceivePlaybackQueue()
        let oldGeneration = queue.reserve(640)
        _ = queue.reserve(640)
        _ = queue.reserve(640)
        _ = queue.reserve(640)
        XCTAssertTrue(queue.wouldOverflow(adding: 640))
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
        XCTAssertFalse(queue.wouldOverflow(adding: 640))
        queue.complete(640, generation: generation)
        XCTAssertFalse(queue.wouldOverflow(adding: queue.maximumSamples))
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
            XCTAssertFalse(queue.wouldOverflow(adding: 640, remainingSamples: remaining))
            end = max(end, rendered) + 640
            let generation = queue.reserve(640)
            completions.append((Double(end) / 8_000 + 0.04 + 0.16, 640, generation))
        }
    }

    func testActualRenderedBacklogStillRequiresTrim() {
        var queue = ReceivePlaybackQueue()
        _ = queue.reserve(640)
        XCTAssertTrue(queue.wouldOverflow(adding: 640, remainingSamples: 2_560))
        XCTAssertFalse(queue.wouldOverflow(adding: 640, remainingSamples: 320))
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
        XCTAssertFalse(queue.wouldOverflow(adding: 640, remainingSamples: history.remainingSamples(renderedSampleTime: -342)))
    }

    func testBurstReplacementStaysBoundedAndOldGenerationCannotConsumeIt() {
        var history = ReceivePlaybackHistory()
        var queue = ReceivePlaybackQueue()
        history.append([Float](repeating: 1, count: 2_560), startingAt: 0)
        let oldToken = queue.reserve(2_560)
        let replacement = history.boundedReplacement(adding: [Float](repeating: 2, count: 640), maximumSamples: queue.maximumSamples)
        XCTAssertEqual(replacement.samples.count, 2_576)
        XCTAssertEqual(replacement.discardedSamples, 624)
        queue.reset()
        history.reset()
        history.append(replacement.samples, startingAt: 0)
        let newToken = queue.reserve(replacement.samples.count)
        queue.complete(2_560, generation: oldToken)
        XCTAssertEqual(queue.queuedSamples, 2_576)
        XCTAssertEqual(history.samples.suffix(640), [Float](repeating: 2, count: 640)[...])
        queue.complete(2_576, generation: newToken)
        history.prune(renderedSampleTime: 2_576)
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
        // Two packets arrive during the measured >100 ms native preroll.
        // The old 242 ms bound resets again at tick 2 before output starts.
        let generationAfterRecovery = queue.generation
        for tick in 1...100 {
            let rendered = tick <= 2 ? Int64(-342 + (tick - 1) * 171) : Int64((tick - 2) * 640)
            history.prune(renderedSampleTime: rendered)
            XCTAssertFalse(queue.wouldOverflow(adding: 640, remainingSamples: history.remainingSamples(renderedSampleTime: rendered)))
            history.append([Float](repeating: Float(tick + 2), count: 640), startingAt: end)
            end += 640
            XCTAssertLessThanOrEqual(history.samples.count, queue.maximumSamples)
            XCTAssertEqual(queue.generation, generationAfterRecovery)
        }
    }

    func testOverflowRejectsIncomingSpeechWithoutResetAndResumesAfterRendering() {
        var queue = ReceivePlaybackQueue()
        var history = ReceivePlaybackHistory()
        let existing = (0..<2_008).map(Float.init)
        history.append(existing, startingAt: 0)
        _ = queue.reserve(existing.count)
        let generation = queue.generation
        let incoming = [Float](repeating: 10_000, count: 640)
        XCTAssertTrue(queue.wouldOverflow(adding: incoming.count,
            remainingSamples: history.remainingSamples(renderedSampleTime: 0)))
        // Reject the new block without touching scheduled history or generation.
        XCTAssertEqual(history.samples, existing)
        XCTAssertEqual(queue.queuedSamples, existing.count)
        XCTAssertEqual(queue.generation, generation)
        history.prune(renderedSampleTime: 640)
        XCTAssertFalse(queue.wouldOverflow(adding: incoming.count,
            remainingSamples: history.remainingSamples(renderedSampleTime: 640)))
        history.append(incoming, startingAt: Int64(existing.count))
        _ = queue.reserve(incoming.count)
        XCTAssertEqual(history.samples, Array(existing.dropFirst(640)) + incoming)
        XCTAssertLessThanOrEqual(history.samples.count, queue.maximumSamples)
        XCTAssertEqual(queue.generation, generation)
    }

    func testObservedSmallBurstOvershootPreservesSpeechWithoutRestart() {
        let queue = ReceivePlaybackQueue()
        XCTAssertFalse(queue.wouldOverflow(adding: 641, remainingSamples: 1_413))
        XCTAssertFalse(queue.wouldOverflow(adding: 640, remainingSamples: 1_919))
        XCTAssertTrue(queue.wouldOverflow(adding: 641, remainingSamples: 1_936))
    }

}
