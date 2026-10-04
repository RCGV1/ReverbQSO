// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class ReceiveClockCompensatorTests: XCTestCase {
    func testStableQueueLeavesPacketAndRatioUnchanged() {
        let compensator = ReceiveClockCompensator()
        let samples = (0..<640).map { Int16($0 - 320) }

        let output = compensator.process(samples, queuedSamples: 640)

        XCTAssertEqual(output, samples)
        XCTAssertEqual(compensator.correctionRatio, 1, accuracy: 0.000_001)
    }

    func testSustainedLowQueueCompensatesForFasterPlaybackClock() {
        let compensator = ReceiveClockCompensator()
        let packet = (0..<640).map { Int16(($0 % 200) - 100) }
        var queuedSamples = 640
        var minimumQueue = queuedSamples
        var maximumRatio = 1.0

        for _ in 0..<2_000 {
            let output = compensator.process(packet, queuedSamples: queuedSamples)
            queuedSamples += output.count - 642
            minimumQueue = min(minimumQueue, queuedSamples)
            maximumRatio = max(maximumRatio, compensator.correctionRatio)
        }

        XCTAssertGreaterThan(queuedSamples, 480)
        XCTAssertGreaterThan(minimumQueue, 350)
        XCTAssertGreaterThan(maximumRatio, 1.002)
        XCTAssertLessThanOrEqual(maximumRatio, 1.005_001)
    }

    func testSustainedHighQueueCompensatesForSlowerPlaybackClock() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 500, count: 640)
        var queuedSamples = 640
        var maximumQueue = queuedSamples
        var minimumRatio = 1.0

        for _ in 0..<2_000 {
            let output = compensator.process(packet, queuedSamples: queuedSamples)
            queuedSamples += output.count - 638
            maximumQueue = max(maximumQueue, queuedSamples)
            minimumRatio = min(minimumRatio, compensator.correctionRatio)
        }

        XCTAssertLessThan(queuedSamples, 800)
        XCTAssertLessThan(maximumQueue, 930)
        XCTAssertLessThan(minimumRatio, 0.998)
        XCTAssertGreaterThanOrEqual(minimumRatio, 0.994_999)
    }

    func testSingleQueueBurstOnlyChangesRatioGently() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 1_000, count: 640)

        _ = compensator.process(packet, queuedSamples: 640)
        let output = compensator.process(packet, queuedSamples: 1_920)

        XCTAssertGreaterThan(compensator.correctionRatio, 0.997)
        XCTAssertGreaterThanOrEqual(output.count, 638)
    }

    func testInterpolationPreservesConstantWaveformWhenLengthChanges() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: -12_345, count: 640)
        var changedOutput = packet

        for _ in 0..<300 where changedOutput.count == packet.count {
            changedOutput = compensator.process(packet, queuedSamples: 1_280)
        }

        XCTAssertNotEqual(changedOutput.count, packet.count)
        XCTAssertTrue(changedOutput.allSatisfy { $0 == -12_345 })
    }

    func testEmptyQueueRetainsCorrectionUntilExplicitReset() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 7, count: 640)

        for _ in 0..<100 {
            _ = compensator.process(packet, queuedSamples: 1_280)
        }
        XCTAssertLessThan(compensator.correctionRatio, 1)

        for _ in 0..<200 { _ = compensator.process(packet, queuedSamples: 0) }
        XCTAssertGreaterThan(compensator.correctionRatio, 1.004)

    }

    func testTwentyMillisecondPacketsUseActualDesiredLead() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 1200, count: 160)
        for _ in 0..<200 {
            XCTAssertEqual(compensator.process(packet, queuedSamples: 160, targetQueuedSamples: 160), packet)
        }
        XCTAssertEqual(compensator.correctionRatio, 1, accuracy: 0.000001)
    }

    func testExplicitResetRestoresNeutralCorrection() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 7, count: 640)

        for _ in 0..<100 {
            _ = compensator.process(packet, queuedSamples: 1_280)
        }
        compensator.reset()

        XCTAssertEqual(compensator.correctionRatio, 1, accuracy: 0.000_001)
        XCTAssertEqual(compensator.process(packet, queuedSamples: 640), packet)
    }

    func testBurstCatchupIsBoundedAndPreservesConstantWaveform() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: -12_345, count: 640)
        for _ in 0..<400 {
            let output = compensator.process(packet, queuedSamples: 2_000, targetQueuedSamples: 320)
            XCTAssertGreaterThanOrEqual(compensator.correctionRatio, 0.97)
            XCTAssertTrue(output.allSatisfy { $0 == -12_345 })
        }
        XCTAssertLessThan(compensator.correctionRatio, 0.975)
        compensator.reset()
        XCTAssertEqual(compensator.process(packet, queuedSamples: 320, targetQueuedSamples: 320), packet)
        XCTAssertEqual(compensator.correctionRatio, 1)
    }

    func testDepletionImmediatelyReleasesBurstCatchup() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 1_000, count: 640)
        for _ in 0..<100 {
            _ = compensator.process(packet, queuedSamples: 1_920, targetQueuedSamples: 320)
        }
        XCTAssertLessThan(compensator.correctionRatio, 0.975)
        let output = compensator.process(packet, queuedSamples: 0, targetQueuedSamples: 320)
        XCTAssertGreaterThanOrEqual(compensator.correctionRatio, 0.995)
        XCTAssertGreaterThanOrEqual(output.count, 636)
    }

    func testClockCorrectionPreservesUpperSpeechBandAndReducesAliasing() {
        func correctedRMSRatio(_ frequency: Double) -> Double {
            let compensator = ReceiveClockCompensator()
            let packet = (0..<640).map { Int16((12_000 * sin(2 * .pi * frequency * Double($0) / 8_000)).rounded()) }
            for _ in 0..<300 { _ = compensator.process(packet, queuedSamples: 2_000, targetQueuedSamples: 320) }
            let corrected = compensator.process(packet, queuedSamples: 2_000, targetQueuedSamples: 320)
            XCTAssertEqual(corrected.first, packet.first)
            XCTAssertEqual(corrected.last, packet.last)
            func rms(_ samples: [Int16]) -> Double {
                sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
            }
            return rms(corrected) / rms(packet)
        }
        XCTAssertGreaterThan(correctedRMSRatio(3_000), 0.97)
        XCTAssertGreaterThan(correctedRMSRatio(3_400), 0.90)
        XCTAssertLessThan(correctedRMSRatio(3_900), 0.30)
    }

    func testFourPacketBurstClearsExcessDelayWithinTenSecondsWithoutDroppingSpeech() {
        var playout = ReceiveAdaptivePlayoutBuffer()
        let compensator = ReceiveClockCompensator()
        let maximumSamples = ReceivePlaybackQueue().maximumSamples
        var nativeEnd = 0.0
        var wake: Double?
        var delays: [Double] = []
        var scheduled = 0

        func nativeRemaining(_ now: Double) -> Int {
            max(0, Int(((nativeEnd - now) * 8_000).rounded()))
        }
        func drain(_ now: Double) {
            let capacity = max(0, maximumSamples - nativeRemaining(now))
            for packet in playout.drain(now: now, maximumSamples: Int(Double(capacity) / 1.005)) {
                let corrected = compensator.process(packet, queuedSamples: nativeRemaining(now),
                    targetQueuedSamples: Int(playout.targetDelay * 8_000))
                XCTAssertLessThanOrEqual(nativeRemaining(now) + corrected.count, maximumSamples)
                let start = max(now, nativeEnd)
                let id = Int(packet[0])
                let arrival = id < 4 ? 0 : Double(id - 3) * 0.080
                delays.append(start - arrival)
                nativeEnd = start + Double(corrected.count) / 8_000
                scheduled += 1
            }
        }
        func arm(_ now: Double) {
            guard wake == nil, let deadline = playout.nextDeadline else { return }
            wake = deadline > now ? deadline : now + 0.010
        }
        for tick in 0...10_000 {
            let now = Double(tick) / 1_000
            let ids = tick == 0 ? [0, 1, 2, 3] : tick.isMultiple(of: 80) ? [3 + tick / 80] : []
            for id in ids {
                drain(now)
                playout.enqueue([Int16](repeating: Int16(id), count: 640), now: now,
                    rendererLeadSamples: nativeRemaining(now))
                drain(now)
                arm(now)
            }
            if let deadline = wake, deadline <= now + 0.000_000_1 {
                wake = nil
                drain(now)
                arm(now)
            }
        }
        let recent = Array(delays.suffix(10))
        XCTAssertLessThan(recent.reduce(0, +) / Double(recent.count), 0.100,
            "A burst must not leave hundreds of milliseconds of sticky playback delay")
        XCTAssertEqual(scheduled, 129)
        XCTAssertEqual(playout.discardedPackets, 0)
        XCTAssertEqual(playout.recoveryCount, 0)
    }
}
