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
            // Endpoints follow the continuous clock, not packet-local anchors;
            // the streaming tone tests below check phase, carrier, and sidebands.
            func rms(_ samples: [Int16]) -> Double {
                sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
            }
            return rms(corrected) / rms(packet)
        }
        XCTAssertGreaterThan(correctedRMSRatio(3_000), 0.97)
        XCTAssertGreaterThan(correctedRMSRatio(3_400), 0.90)
        XCTAssertLessThan(correctedRMSRatio(3_900), 0.30)
    }

    func testStreamingSteady500PPMCorrectionPreservesSpeechBandPhaseAndCarrier() {
        for frameSize in [80, 160, 320, 640] {
            for queue in [616, 664] {
                for frequency in [1_000.0, 3_000.0] {
                    let compensator = ReceiveClockCompensator()
                    var fraction = settleClock(compensator, queuedSamples: queue)
                    let ratio = queue < 640 ? 1.0005 : 0.9995
                    XCTAssertEqual(compensator.correctionRatio, ratio, accuracy: 1e-12)
                    var output: [Double] = []
                    var referencePhase: [Double] = []
                    var measuredCount = 0
                    // Seed prior waveform history with two legal, continuous packets.
                    // The tone's global input index does not restart at packet joins.
                    for packet in 0..<(2 + 32_000 / frameSize) {
                        let offset = packet * frameSize
                        let input = clockTone(offset: offset, count: frameSize, frequency: frequency)
                        let corrected = compensator.process(input, queuedSamples: queue)
                        let currentRatio = compensator.correctionRatio
                        if packet >= 2 {
                            measuredCount += corrected.count
                            for (index, sample) in corrected.enumerated() {
                                // Invert cumulative output time, including the carried
                                // fraction. Fitting at the input frequency would wrongly
                                // penalize the intended f / ratio clock correction.
                                let position = Double(offset)
                                    + (Double(index + 1) - fraction) / currentRatio - 1
                                referencePhase.append(2 * .pi * frequency * position / 8_000 + 0.37)
                                output.append(Double(sample))
                            }
                        }
                        fraction = Double(frameSize) * currentRatio + fraction - Double(corrected.count)
                    }
                    let context = "N=\(frameSize), queue=\(queue), tone=\(frequency) Hz"
                    XCTAssertEqual(measuredCount, queue < 640 ? 32_016 : 31_984, context)
                    let fit = fitClockTone(output, phases: referencePhase)
                    XCTAssertLessThan(fit.residualDB, frequency == 1_000 ? -30 : -20, context)
                    XCTAssertLessThan(abs(20 * log10(fit.amplitude / 12_000)), 0.2, context)

                    let carrier = frequency / ratio
                    let correctionFrequency = 8_000 * abs(1 - ratio) / ratio
                    for side in [-1.0, 1.0] {
                        let sideband = clockSpectralAmplitude(
                            fit.residual, frequency: carrier + side * correctionFrequency)
                        XCTAssertLessThan(20 * log10(max(sideband / fit.amplitude, 1e-15)), -30,
                            "\(context), sideband=\(carrier + side * correctionFrequency) Hz")
                    }
                }
            }
        }
    }

    func testStreamingHeadroomTonesDoNotClipAtPacketBoundaries() {
        let phases = (0..<16).map { 2 * Double.pi * Double($0) / 16 } + [0.37]
        for frameSize in [80, 160, 320, 640] {
            for queue in [664, 1_920] {
                let compensator = ReceiveClockCompensator()
                _ = settleClock(compensator, queuedSamples: queue)
                for frequency in [1_000.0, 3_000.0] {
                    for phase in phases {
                        var railSamples = 0
                        var inputPeak = 0
                        for packet in 0..<66 {
                            let input = clockTone(offset: packet * frameSize, count: frameSize,
                                frequency: frequency, amplitude: 32_000, phase: phase)
                            let output = compensator.process(input, queuedSamples: queue)
                            // Ignore only the transition between phase fixtures, not
                            // any boundary within the measured continuous tone.
                            guard packet >= 2 else { continue }
                            inputPeak = max(inputPeak, input.map { abs(Int($0)) }.max() ?? 0)
                            railSamples += output.filter { $0 == .min || $0 == .max }.count
                        }
                        let context = "N=\(frameSize), queue=\(queue), tone=\(frequency) Hz, phase=\(phase)"
                        XCTAssertLessThanOrEqual(inputPeak, 32_000, context)
                        XCTAssertEqual(railSamples, 0, context)
                    }
                }
            }
        }
    }

    func testStreamingFeedbackPreservesExactPerCallCountsAndRatios() {
        for frameSizes in [[80], [160], [320], [640], [80, 160, 320, 640]] {
            let compensator = ReceiveClockCompensator()
            var reference = ClockFeedbackReference()
            var exactTotal = 0.0
            var outputTotal = 0
            for packet in 0..<1_024 {
                let frameSize = frameSizes[packet % frameSizes.count]
                let target = [640, 320, 160, -40][(packet / 256) % 4]
                let queue: Int
                switch packet / 128 {
                case 0: queue = target
                case 1: queue = target + 24
                case 2: queue = target - 24
                case 3: queue = target + 1_280
                case 4: queue = target + max(0, 1_280 - (packet % 128) * 10)
                case 5: queue = 0
                case 6: queue = -80
                default: queue = target + 240
                }
                let expectedCount = reference.process(count: frameSize, queue: queue, target: target)
                let output = compensator.process([Int16](repeating: 123, count: frameSize),
                    queuedSamples: queue, targetQueuedSamples: target)
                let context = "chunks=\(frameSizes), packet=\(packet)"
                XCTAssertEqual(output.count, expectedCount, context)
                XCTAssertEqual(compensator.correctionRatio, reference.ratio, context)
                XCTAssertGreaterThanOrEqual(compensator.correctionRatio, 0.97, context)
                XCTAssertLessThanOrEqual(compensator.correctionRatio, 1.005, context)
                exactTotal += Double(frameSize) * reference.ratio
                outputTotal += output.count
                XCTAssertLessThan(abs(Double(outputTotal) - exactTotal), 1.000_000_1, context)
                XCTAssertTrue(compensator.process([], queuedSamples: 10_000).isEmpty)
                XCTAssertEqual(compensator.correctionRatio, reference.ratio, context)
            }
        }
    }

    func testStreamingNeutralQueueIsBitExactForEveryLegalChunkSize() {
        for frameSizes in [[80], [160], [320], [640], [80, 160, 320, 640]] {
            let compensator = ReceiveClockCompensator()
            var offset = 0
            for packet in 0..<100 {
                let frameSize = frameSizes[packet % frameSizes.count]
                let input = (offset..<(offset + frameSize)).map { Int16(($0 * 977) % 60_000 - 30_000) }
                XCTAssertEqual(compensator.process(input, queuedSamples: 640), input)
                XCTAssertEqual(compensator.correctionRatio, 1)
                offset += frameSize
            }
        }
    }

    func testStreamingDCIncludingRailsSurvivesCorrectionAndLegalChunkChanges() {
        for frameSizes in [[80], [160], [320], [640], [80, 160, 320, 640]] {
            for value: Int16 in [.min, -30_000, -12_345, 0, 12_345, 30_000, .max] {
                let compensator = ReceiveClockCompensator()
                for packet in 0..<200 {
                    let frameSize = frameSizes[packet % frameSizes.count]
                    let queue = [640, 664, 616, 1_920, 0][(packet / 40) % 5]
                    let output = compensator.process([Int16](repeating: value, count: frameSize),
                        queuedSamples: queue)
                    XCTAssertFalse(output.isEmpty)
                    XCTAssertTrue(output.allSatisfy { $0 == value },
                        "chunks=\(frameSizes), DC=\(value), packet=\(packet)")
                }
            }
        }
    }

    func testStreamingResetMatchesFreshClockAndWaveformHistory() {
        for frameSize in [80, 160, 320, 640] {
            let compensator = ReceiveClockCompensator()
            for packet in 0..<100 {
                _ = compensator.process(clockTone(offset: packet * frameSize, count: frameSize,
                    frequency: 3_000), queuedSamples: 1_920)
            }
            compensator.reset()
            XCTAssertEqual(compensator.correctionRatio, 1)
            let fresh = ReceiveClockCompensator()
            for packet in 0..<100 {
                let input = clockTone(offset: packet * frameSize, count: frameSize,
                    frequency: 1_000, phase: -0.81)
                let queue = [1_920, 0, 664, 640][(packet / 25) % 4]
                XCTAssertEqual(compensator.process(input, queuedSamples: queue),
                    fresh.process(input, queuedSamples: queue), "N=\(frameSize), packet=\(packet)")
                XCTAssertEqual(compensator.correctionRatio, fresh.correctionRatio)
            }
            compensator.reset()
            let input = clockTone(offset: 0, count: frameSize, frequency: 3_000)
            XCTAssertEqual(compensator.process(input, queuedSamples: 640), input)
        }
    }

    func testStreamingToneMetricFitsConstantPhaseAndGainButDetectsModulation() {
        for frequency in [1_000.0, 3_000.0] {
            let carrier = frequency / 0.9995
            let modulation = 8_000 * 0.0005 / 0.9995
            let phases = (0..<31_984).map { 2 * Double.pi * carrier * Double($0) / 8_000 }
            let clean = phases.map { 11_880 * sin($0 + 0.61) }
            let fit = fitClockTone(clean, phases: phases)
            XCTAssertEqual(fit.amplitude, 11_880, accuracy: 1e-6)
            XCTAssertLessThan(fit.residualDB, -180)
            let modulated = phases.enumerated().map { index, phase in
                11_880 * sin(phase + 0.61 + 0.3 * sin(2 * .pi * modulation * Double(index) / 8_000))
            }
            let modulatedFit = fitClockTone(modulated, phases: phases)
            XCTAssertGreaterThan(modulatedFit.residualDB, -20)
            let sideband = clockSpectralAmplitude(modulatedFit.residual, frequency: carrier - modulation)
            XCTAssertGreaterThan(20 * log10(sideband / modulatedFit.amplitude), -20)
        }
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

private func clockTone(offset: Int, count: Int, frequency: Double,
                       amplitude: Double = 12_000, phase: Double = 0.37) -> [Int16] {
    (offset..<(offset + count)).map {
        Int16((amplitude * sin(2 * .pi * frequency * Double($0) / 8_000 + phase)).rounded())
    }
}

private func settleClock(_ compensator: ReceiveClockCompensator, queuedSamples: Int) -> Double {
    let silence = [Int16](repeating: 0, count: 80)
    var fraction = 0.0
    for _ in 0..<1_500 {
        let output = compensator.process(silence, queuedSamples: queuedSamples)
        fraction = Double(silence.count) * compensator.correctionRatio + fraction - Double(output.count)
    }
    return fraction
}

private func fitClockTone(_ samples: [Double], phases: [Double])
    -> (amplitude: Double, residualDB: Double, residual: [Double]) {
    precondition(samples.count == phases.count && !samples.isEmpty)
    let sines = phases.map { sin($0) }
    let cosines = phases.map { cos($0) }
    var ss = 0.0, cc = 0.0, sc = 0.0, ys = 0.0, yc = 0.0
    for index in samples.indices {
        let s = sines[index], c = cosines[index], y = samples[index]
        ss += s * s
        cc += c * c
        sc += s * c
        ys += y * s
        yc += y * c
    }
    // A single sine/cosine least-squares fit removes constant gain and phase,
    // but cannot track or hide time-varying packet-induced phase modulation.
    let determinant = ss * cc - sc * sc
    let a = (ys * cc - yc * sc) / determinant
    let b = (yc * ss - ys * sc) / determinant
    var errorEnergy = 0.0, carrierEnergy = 0.0
    var residual: [Double] = []
    residual.reserveCapacity(samples.count)
    for index in samples.indices {
        let carrier = a * sines[index] + b * cosines[index]
        let error = samples[index] - carrier
        errorEnergy += error * error
        carrierEnergy += carrier * carrier
        residual.append(error)
    }
    return (hypot(a, b), 10 * log10(max(errorEnergy / carrierEnergy, 1e-30)), residual)
}

private func clockSpectralAmplitude(_ samples: [Double], frequency: Double) -> Double {
    var real = 0.0, imaginary = 0.0
    for (index, sample) in samples.enumerated() {
        let phase = 2 * .pi * frequency * Double(index) / 8_000
        real += sample * cos(phase)
        imaginary += sample * sin(phase)
    }
    return 2 * hypot(real, imaginary) / Double(samples.count)
}

// Freeze the shipping feedback/count contract independently of interpolation.
private struct ClockFeedbackReference {
    private var smoothedError = 0.0
    private var catchup = 0.0
    private var fraction = 0.0
    private(set) var ratio = 1.0

    mutating func process(count: Int, queue: Int, target: Int) -> Int {
        let error = Double(max(0, queue) - max(0, target))
        let normalized = max(-1, min(1, error / 240))
        smoothedError += 0.02 * (normalized - smoothedError)
        let desiredCatchup = 0.025 * min(1, max(0, error - 128) / 640)
        if error <= 0 { catchup = 0 }
        else { catchup += 0.08 * (desiredCatchup - catchup) }
        ratio = 1 - 0.005 * smoothedError - catchup
        let exactCount = Double(count) * ratio + fraction
        let outputCount = max(1, Int(exactCount.rounded(.down)))
        fraction = exactCount - Double(outputCount)
        return outputCount
    }
}
