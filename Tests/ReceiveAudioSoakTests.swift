// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ReverbQSO

final class ReceiveAudioSoakTests: XCTestCase {
    func testTenMinuteEightyMillisecondPacketsWithFasterReceiverClock() {
        assertSoak(duration: 600, packetSamples: 640, receiverPPM: 300)
    }

    func testTenMinuteEightyMillisecondPacketsWithSlowerReceiverClock() {
        assertSoak(duration: 600, packetSamples: 640, receiverPPM: -300)
    }

    func testTwoMinuteTwentyMillisecondPacketsWithFasterReceiverClock() {
        assertSoak(duration: 120, packetSamples: 160, receiverPPM: 300)
    }

    func testTwoMinuteTwentyMillisecondPacketsWithSlowerReceiverClock() {
        assertSoak(duration: 120, packetSamples: 160, receiverPPM: -300)
    }

    func testResetIsolatesPendingPCMClockFeedbackAndStaleCompletions() {
        let configuration = Configuration(duration: 8, packetSamples: 160, receiverPPM: 300)
        let reused = VirtualReceiver(configuration)
        reused.receive(id: 0, now: 0)
        reused.advance(to: 0.040)
        reused.drain(now: 0.040)
        reused.playout.enqueue([Int16](repeating: -30_000, count: 160), now: 0.041,
                               rendererLeadSamples: reused.remainingSamples)
        for _ in 0..<200 {
            _ = reused.clock.process([Int16](repeating: -7, count: 160),
                                     queuedSamples: 2_000, targetQueuedSamples: 320)
        }
        XCTAssertGreaterThan(reused.remainingSamples, 0)
        XCTAssertGreaterThan(reused.playout.pendingSampleCount, 0)
        XCTAssertNotEqual(reused.clock.correctionRatio, 1)
        let oldToken = reused.queue.generation
        let oldCount = reused.queue.queuedSamples

        reused.reset()

        XCTAssertEqual(reused.remainingSamples, 0)
        XCTAssertEqual(reused.queue.queuedSamples, 0)
        XCTAssertEqual(reused.queue.generation, oldToken &+ 1)
        XCTAssertEqual(reused.playout.pendingSampleCount, 0)
        XCTAssertNil(reused.playout.nextDeadline)
        XCTAssertNil(reused.wake)
        XCTAssertEqual(reused.playout.targetDelay, 0.040)
        XCTAssertEqual(reused.clock.correctionRatio, 1)
        let newToken = reused.queue.reserve(17)
        reused.queue.complete(oldCount, generation: oldToken)
        XCTAssertEqual(reused.queue.queuedSamples, 17, "An old callback must not consume a new reservation")
        reused.queue.complete(17, generation: newToken)

        let replay = reused.run()
        let fresh = VirtualReceiver(configuration).run()
        assertDelivery(replay, configuration: configuration)
        XCTAssertEqual(replay, fresh, "Reset must clear fractional resampling, timers, PCM and feedback history")
        print("ReceiveAudioSoak reset: replay exactly matches a fresh receiver")
    }

    func testUpperSpeechBandPacketJoinsSurviveClockCorrectionInBothDirections() {
        for ppm in [-300.0, 300.0] {
            let configuration = Configuration(duration: 60, packetSamples: 160,
                                              receiverPPM: ppm, upperSpeechBand: true)
            let result = VirtualReceiver(configuration).run()
            assertDelivery(result, configuration: configuration)
            XCTAssertGreaterThan(result.changedPackets, 0)
            if ppm < 0 {
                XCTAssertTrue(result.outputCounts.contains { $0 < configuration.packetSamples })
            } else {
                XCTAssertTrue(result.outputCounts.contains { $0 > configuration.packetSamples })
            }
            XCTAssertEqual(result.checkedJoins, configuration.packetCount - 1)
            XCTAssertEqual(result.joinErrors, 0, "Rendered joins must retain the scheduled corrected PCM delta")
            XCTAssertLessThan(result.maximumUpperBandError, 0.10,
                              "Interior 2873/3371 Hz PCM must track the continuous global sample clock")
            XCTAssertLessThan(result.maximumFullBandError, 0.10,
                              "Packet edges must also track the continuous global sample clock")
            print(result.summary(configuration))
        }
    }

    func testUpperSpeechBandPacketEdgesAcrossOtherLegalChunkSizes() {
        for packetSamples in [80, 320, 640] {
            for ppm in [-300.0, 300.0] {
                let configuration = Configuration(duration: 8, packetSamples: packetSamples,
                                                  receiverPPM: ppm, upperSpeechBand: true)
                let result = VirtualReceiver(configuration).run()
                assertDelivery(result, configuration: configuration)
                XCTAssertLessThan(result.maximumUpperBandError, 0.10)
                XCTAssertLessThan(result.maximumFullBandError, 0.10,
                                  "N=\(packetSamples), receiver_ppm=\(ppm)")
                print(result.summary(configuration))
            }
        }
    }

    func testGlobalToneOracleRejectsPacketLocalEndpointTiming() {
        let configuration = Configuration(duration: 8, packetSamples: 160,
                                          receiverPPM: 0, upperSpeechBand: true)
        for ratio in [0.9995, 1.0005] {
            var referenceClock = ReferenceClock()
            var emittedSamples = 0
            var maximumIdealError = 0.0
            var maximumEndpointError = 0.0
            for id in 0..<configuration.packetCount {
                let reference = referenceClock.process(inputCount: configuration.packetSamples, ratio: ratio)
                // Independent constant-rate construction from the global output
                // index, not the packet reference's carried fractional clock.
                let ideal = (0..<reference.outputCount).map { index in
                    Int16(configuration.tone(Double(emittedSamples + index + 1) / ratio - 1).rounded())
                }
                let endpointAligned = (0..<reference.outputCount).map { index in
                    let position = Double(id * configuration.packetSamples)
                        + Double(index * (configuration.packetSamples - 1)) / Double(reference.outputCount - 1)
                    return Int16(configuration.tone(position).rounded())
                }
                maximumIdealError = max(maximumIdealError,
                    Self.toneError(ideal, reference: reference, configuration: configuration))
                maximumEndpointError = max(maximumEndpointError,
                    Self.toneError(endpointAligned, reference: reference, configuration: configuration))
                emittedSamples += reference.outputCount
            }
            XCTAssertLessThan(maximumIdealError, 0.0001)
            XCTAssertGreaterThan(maximumEndpointError, 0.10,
                                 "A packet-local endpoint fit must fail the unchanged tone-error limit")
            print("ReceiveAudioSoak oracle calibration ratio=\(ratio) ideal=\(maximumIdealError) endpoint=\(maximumEndpointError)")
        }
    }

    func testGloballyConstantPCMRemainsConstantAcrossClockFeedbackChanges() {
        for count in [80, 160, 320, 640] {
            for value: Int16 in [.min, -12_345, 0, 12_345, .max] {
                let clock = ReceiveClockCompensator()
                let input = [Int16](repeating: value, count: count)
                for packet in 0..<200 {
                    let queue = [640, 664, 616, 1_920, 0][(packet / 40) % 5]
                    let output = clock.process(input, queuedSamples: queue)
                    XCTAssertFalse(output.isEmpty)
                    XCTAssertTrue(output.allSatisfy { $0 == value }, "N=\(count), DC=\(value), packet=\(packet)")
                }
            }
        }
    }

    func testPacketTagAndScheduledPCMOraclesRejectCorruption() {
        let current = [Int16](repeating: 22, count: 160)
        let blended = [Int16](repeating: 21, count: 17) + current.dropFirst(17)
        XCTAssertTrue(Self.matchesPacketTag(blended, id: 21))
        XCTAssertFalse(Self.matchesPacketTag([Int16](repeating: 21, count: 160), id: 21))
        var corrupt = blended
        corrupt[80] = 0
        XCTAssertFalse(Self.matchesPacketTag(corrupt, id: 21))
        corrupt = blended
        corrupt[0] = 20
        XCTAssertFalse(Self.matchesPacketTag(corrupt, id: 21))

        let previous = [Int16](repeating: 21, count: 160)
        func trace(_ samples: [Int16]) -> PCMTrace {
            var result = PCMTrace()
            result.append(samples)
            return result
        }
        let expected = trace(previous + blended)
        var split = PCMTrace()
        split.append(previous.prefix(79))
        split.append(previous.dropFirst(79))
        split.append(blended)
        XCTAssertEqual(split, expected, "Render chunk boundaries must not change the stream fingerprint")
        XCTAssertNotEqual(trace(blended + previous), expected)
        XCTAssertNotEqual(trace(previous + Array(blended.dropFirst())), expected)
        XCTAssertNotEqual(trace(previous + [blended[0]] + blended), expected)
        XCTAssertNotEqual(trace(previous + corrupt), expected)
    }

    private func assertSoak(duration: Double, packetSamples: Int, receiverPPM: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        let configuration = Configuration(duration: duration, packetSamples: packetSamples, receiverPPM: receiverPPM)
        let result = VirtualReceiver(configuration).run()
        assertDelivery(result, configuration: configuration, file: file, line: line)
        XCTAssertGreaterThan(result.changedPackets, 0, file: file, line: line)

        // Initial renderer silence is excluded from underruns. Separately omit
        // the first 30 seconds from steady-state drift/correction measurements.
        let windowMeans = stride(from: 30.0, to: duration, by: 30).map { start in
            mean(result.startDelays.enumerated().compactMap { id, delay in
                let sentAt = Double(id * packetSamples) / 8_000
                return sentAt >= start && sentAt < start + 30 ? delay : nil
            })
        }
        XCTAssertGreaterThanOrEqual(windowMeans.count, 3, file: file, line: line)
        let drift = (windowMeans.max() ?? .infinity) - (windowMeans.min() ?? -.infinity)
        XCTAssertLessThan(drift, 0.010, "Settled 30-second mean delay must not drift by 10 ms", file: file, line: line)
        let finalCounts = result.outputCounts.enumerated().compactMap { id, count in
            Double(id * packetSamples) / 8_000 >= duration - 30 ? count : nil
        }
        let finalRatio = Double(finalCounts.reduce(0, +)) / Double(finalCounts.count * packetSamples)
        XCTAssertEqual(finalRatio, 1 + receiverPPM / 1_000_000, accuracy: 0.000_075,
                       "Settled output must track the nonzero receiver-clock mismatch", file: file, line: line)
        print(result.summary(configuration) + String(format: " drift_ms=%.3f final_ppm=%.2f", drift * 1_000,
                                                     (finalRatio - 1) * 1_000_000))
    }

    private func assertDelivery(_ result: Result, configuration: Configuration,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.submittedPackets, configuration.packetCount, file: file, line: line)
        XCTAssertEqual(result.processCalls, configuration.packetCount, "Process every packet, not one per batch", file: file, line: line)
        XCTAssertEqual(result.renderedIDs, Array(0..<configuration.packetCount), file: file, line: line)
        XCTAssertEqual(result.outputCounts.count, configuration.packetCount, file: file, line: line)
        XCTAssertEqual(result.renderedSamples, result.outputCounts.reduce(0, +), file: file, line: line)
        XCTAssertEqual(result.packetErrors, 0, "Source order, correction counts and packet tag waveforms must survive", file: file, line: line)
        XCTAssertEqual(result.renderedPCM, result.scheduledPCM,
                       "Every corrected PCM sample must render exactly once in FIFO order", file: file, line: line)
        XCTAssertEqual(result.accountingErrors, 0, file: file, line: line)
        XCTAssertEqual(result.overflowAttempts, 0, file: file, line: line)
        XCTAssertEqual(result.discardedPackets, 0, file: file, line: line)
        XCTAssertEqual(result.capacityDiscards, 0, file: file, line: line)
        XCTAssertEqual(result.expiredDiscards, 0, file: file, line: line)
        XCTAssertEqual(result.pendingSamples, 0, file: file, line: line)
        XCTAssertEqual(result.nativeSamples, 0, file: file, line: line)
        XCTAssertEqual(result.reservedSamples, 0, file: file, line: line)
        XCTAssertGreaterThan(result.maximumNativeSamples, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(result.maximumNativeSamples, ReceivePlaybackQueue().maximumSamples, file: file, line: line)
        XCTAssertLessThanOrEqual(result.maximumPendingSamples, 3_840, file: file, line: line)
        XCTAssertGreaterThanOrEqual(result.minimumRatio, 0.970 - 1e-12, file: file, line: line)
        XCTAssertLessThanOrEqual(result.maximumRatio, 1.005 + 1e-12, file: file, line: line)
        XCTAssertEqual(result.underruns, 0, "No gaps after the first rendered sample in these no-loss traces", file: file, line: line)
        XCTAssertGreaterThan(result.startupSilence, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(result.startupSilence, 0.101, file: file, line: line)
        XCTAssertLessThan(result.startDelays.max() ?? .infinity, 0.150, file: file, line: line)
        XCTAssertLessThan(result.tailDelays.max() ?? .infinity, 0.250,
                          "Arrival-to-last-rendered-sample delay must remain bounded", file: file, line: line)
        XCTAssertLessThanOrEqual(result.maximumPlayoutWait, 0.240, file: file, line: line)
    }

    private func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .infinity : values.reduce(0, +) / Double(values.count)
    }

    private static func matchesPacketTag(_ samples: [Int16], id: Int) -> Bool {
        guard !samples.isEmpty else { return false }
        let tag = Int16(id + 1)
        let previous = Int16(max(1, id))
        // These tags form a unit staircase, not global DC. Prior kernel support
        // may blend the preceding tag, but the stable body must be exact.
        return samples.enumerated().allSatisfy { index, sample in
            index < 17 ? (previous...tag).contains(sample) : sample == tag
        }
    }

    private static func toneError(_ samples: [Int16], reference: PacketReference,
                                  configuration: Configuration, interiorOnly: Bool = false) -> Double {
        let margin = interiorOnly ? 16 : 0
        var error = 0.0
        var energy = 0.0
        for index in margin..<(samples.count - margin) {
            let expected = configuration.tone(reference.position(index))
            error += pow(Double(samples[index]) - expected, 2)
            energy += expected * expected
        }
        return sqrt(error / energy)
    }

    private struct PCMTrace: Equatable {
        private var count = 0
        private var fingerprint: UInt64 = 0xcbf29ce484222325

        mutating func append<S: Sequence>(_ samples: S) where S.Element == Int16 {
            for sample in samples {
                count += 1
                fingerprint ^= UInt64(UInt16(bitPattern: sample))
                fingerprint &*= 0x100000001b3
            }
        }
    }

    private struct PacketReference {
        let firstSourcePosition: Double
        let sourceStep: Double
        let outputCount: Int

        func position(_ index: Int) -> Double { firstSourcePosition + Double(index) * sourceStep }
    }

    // Analytically invert integrated output-clock ticks, independently of the
    // interpolator: there is no endpoint fit, kernel, or output-PCM feedback.
    private struct ReferenceClock {
        private var sourceSamples = 0
        private var fractionalTicks = 0.0

        mutating func process(inputCount: Int, ratio: Double) -> PacketReference {
            let nextTicks = fractionalTicks + Double(inputCount) * ratio
            let count = Int(nextTicks.rounded(.down))
            let reference = PacketReference(firstSourcePosition: Double(sourceSamples) - 1 + (1 - fractionalTicks) / ratio,
                                            sourceStep: 1 / ratio, outputCount: count)
            fractionalTicks = nextTicks - Double(count)
            sourceSamples += inputCount
            return reference
        }
    }

    private struct Configuration {
        let duration: Double
        let packetSamples: Int
        let receiverPPM: Double
        var upperSpeechBand = false
        var packetCount: Int { Int((duration * 8_000 / Double(packetSamples)).rounded()) }
        var rendererRate: Double { 8_000 * (1 + receiverPPM / 1_000_000) }

        func arrival(_ id: Int) -> Double {
            // Reproducible millisecond jitter; even the shortest cadence stays
            // strictly ordered. Neither wall time nor a random generator is used.
            let jitter = [0, 2, -1, 1, -2, 3, 0, -3, 2, 0, -1, 1, -2, 0, 2, -1]
            return Double(id * packetSamples) / 8_000 + Double(jitter[id % jitter.count]) / 1_000
        }

        func tone(_ sourcePosition: Double) -> Double {
            6_000 * sin(2 * .pi * 2_873 * sourcePosition / 8_000)
                + 4_000 * sin(2 * .pi * 3_371 * sourcePosition / 8_000)
        }

        func packet(_ id: Int) -> [Int16] {
            if !upperSpeechBand { return [Int16](repeating: Int16(id + 1), count: packetSamples) }
            return (0..<packetSamples).map { Int16(tone(Double(id * packetSamples + $0)).rounded()) }
        }
    }

    private struct Result: Equatable {
        var submittedPackets = 0
        var processCalls = 0
        var renderedIDs: [Int] = []
        var outputCounts: [Int] = []
        var startDelays: [Double] = []
        var tailDelays: [Double] = []
        var renderedSamples = 0
        var scheduledPCM = PCMTrace()
        var renderedPCM = PCMTrace()
        var packetErrors = 0
        var accountingErrors = 0
        var overflowAttempts = 0
        var discardedPackets = 0
        var capacityDiscards = 0
        var expiredDiscards = 0
        var recoveries = 0
        var pendingSamples = 0
        var nativeSamples = 0
        var reservedSamples = 0
        var maximumNativeSamples = 0
        var maximumPendingSamples = 0
        var maximumPlayoutWait = 0.0
        var minimumRatio = 1.0
        var maximumRatio = 1.0
        var startupSilence = 0.0
        var underruns = 0
        var gapSeconds = 0.0
        var changedPackets = 0
        var checkedJoins = 0
        var joinErrors = 0
        var maximumUpperBandError = 0.0
        var maximumFullBandError = 0.0

        func summary(_ configuration: Configuration) -> String {
            String(format: "ReceiveAudioSoak seconds=%.0f packet_ms=%.0f receiver_ppm=%.0f",
                   configuration.duration, Double(configuration.packetSamples) / 8, configuration.receiverPPM)
                + " submitted=\(submittedPackets) processed=\(processCalls) rendered=\(renderedIDs.count)"
                + " native_peak=\(maximumNativeSamples) pending_peak=\(maximumPendingSamples)"
                + " drops=\(discardedPackets) overflow=\(overflowAttempts) recoveries=\(recoveries) gaps=\(underruns)"
                + String(format: " startup_ms=%.3f start_max_ms=%.3f tail_max_ms=%.3f ratio=%.7f...%.7f upper_band_error=%.5f full_band_error=%.5f",
                         startupSilence * 1_000, (startDelays.max() ?? 0) * 1_000,
                         (tailDelays.max() ?? 0) * 1_000, minimumRatio, maximumRatio,
                         maximumUpperBandError, maximumFullBandError)
        }
    }

    private final class VirtualReceiver {
        private struct NativePacket {
            let id: Int
            let samples: [Int16]
            let token: UInt64
            let expectedJoinDelta: Int?
            var cursor = 0
        }

        let configuration: Configuration
        var playout = ReceiveAdaptivePlayoutBuffer()
        var queue = ReceivePlaybackQueue()
        let clock = ReceiveClockCompensator()
        var wake: Double?
        private var native: [NativePacket] = []
        private var rendererTicks = 0
        private var lastRenderedEnd: Double?
        private var lastRenderedSample: Int16?
        private var lastScheduledSample: Int16?
        private var referenceClock = ReferenceClock()
        private var result = Result()
        var remainingSamples: Int { native.reduce(0) { $0 + $1.samples.count - $1.cursor } }

        init(_ configuration: Configuration) { self.configuration = configuration }

        func reset() {
            playout.reset()
            queue.reset()
            clock.reset()
            wake = nil
            native.removeAll()
            rendererTicks = 0
            lastRenderedEnd = nil
            lastRenderedSample = nil
            lastScheduledSample = nil
            referenceClock = ReferenceClock()
            result = Result()
        }

        func run() -> Result {
            for id in 0..<configuration.packetCount {
                let now = configuration.arrival(id)
                precondition(id == 0 || now > configuration.arrival(id - 1), "Jitter must not reorder packets")
                pump(until: now)
                receive(id: id, now: now)
            }
            // Continue consuming PCM, not just scheduling it. A fixed one-second
            // tail makes lost/stuck packets fail instead of extending forever.
            pump(until: configuration.arrival(configuration.packetCount - 1) + 1)
            result.discardedPackets = playout.discardedPackets
            result.capacityDiscards = playout.capacityDiscardedPackets
            result.expiredDiscards = playout.expiredDiscardedPackets
            result.recoveries = playout.recoveryCount
            result.maximumPlayoutWait = playout.maximumObservedWait
            result.pendingSamples = playout.pendingSampleCount
            result.nativeSamples = remainingSamples
            result.reservedSamples = queue.queuedSamples
            return result
        }

        func receive(id: Int, now: Double) {
            drain(now: now)
            playout.enqueue(configuration.packet(id), networkSampleCount: configuration.packetSamples,
                            now: now, rendererLeadSamples: remainingSamples)
            result.submittedPackets += 1
            result.maximumPendingSamples = max(result.maximumPendingSamples, playout.pendingSampleCount)
            drain(now: now)
            arm(now: now)
        }

        private func pump(until now: Double) {
            while let deadline = wake, deadline <= now {
                advance(to: deadline)
                wake = nil
                drain(now: deadline)
                arm(now: deadline)
            }
            advance(to: now)
        }

        private func arm(now: Double) {
            guard wake == nil, let deadline = playout.nextDeadline else { return }
            wake = deadline > now ? deadline : now + 0.010
        }

        func drain(now: Double) {
            let capacity = max(0, queue.maximumSamples - remainingSamples)
            let budget = Int(Double(capacity) / 1.005)
            for packet in playout.drain(now: now, maximumSamples: budget) {
                let id = result.processCalls
                let expected = configuration.packet(id)
                if packet != expected { result.packetErrors += 1 }
                let corrected = clock.process(packet, queuedSamples: remainingSamples,
                                              targetQueuedSamples: Int(playout.targetDelay * 8_000))
                let reference = referenceClock.process(inputCount: packet.count, ratio: clock.correctionRatio)
                result.processCalls += 1
                result.outputCounts.append(corrected.count)
                result.minimumRatio = min(result.minimumRatio, clock.correctionRatio)
                result.maximumRatio = max(result.maximumRatio, clock.correctionRatio)
                if corrected.count != packet.count { result.changedPackets += 1 }
                if corrected.count != reference.outputCount
                    || corrected.count < Int((Double(packet.count) * 0.970).rounded(.down))
                    || corrected.count > Int((Double(packet.count) * 1.005).rounded(.up)) {
                    result.packetErrors += 1
                }
                if configuration.upperSpeechBand { checkUpperBand(corrected, reference: reference) }
                else if !ReceiveAudioSoakTests.matchesPacketTag(corrected, id: id) { result.packetErrors += 1 }
                guard !queue.wouldOverflow(adding: corrected.count, remainingSamples: remainingSamples) else {
                    result.overflowAttempts += 1
                    continue
                }
                let token = queue.reserve(corrected.count)
                let joinDelta = corrected.first.flatMap { first in lastScheduledSample.map { Int(first) - Int($0) } }
                native.append(NativePacket(id: id, samples: corrected, token: token, expectedJoinDelta: joinDelta))
                result.scheduledPCM.append(corrected)
                lastScheduledSample = corrected.last
                result.maximumNativeSamples = max(result.maximumNativeSamples, remainingSamples)
                checkAccounting()
            }
        }

        func advance(to now: Double) {
            // Positive ppm means faster consumption. Use an absolute sample
            // clock so rounding at packet/timer events cannot erase the drift.
            let nextTick = Int((now * configuration.rendererRate).rounded(.down))
            precondition(nextTick >= rendererTicks)
            var tick = rendererTicks
            var available = nextTick - rendererTicks
            while available > 0, !native.isEmpty {
                let count = min(available, native[0].samples.count - native[0].cursor)
                let id = native[0].id
                if native[0].cursor == 0 {
                    let start = Double(tick + 1) / configuration.rendererRate
                    result.startDelays.append(start - configuration.arrival(id))
                    if let lastRenderedEnd {
                        let gap = max(0, start - lastRenderedEnd - 1 / configuration.rendererRate)
                        if gap > 0.5 / configuration.rendererRate {
                            result.underruns += 1
                            result.gapSeconds += gap
                        }
                    } else {
                        result.startupSilence = start - configuration.arrival(0)
                    }
                    if configuration.upperSpeechBand, let lastRenderedSample {
                        let actualDelta = Int(native[0].samples[0]) - Int(lastRenderedSample)
                        result.checkedJoins += 1
                        if actualDelta != native[0].expectedJoinDelta { result.joinErrors += 1 }
                    }
                }
                let endCursor = native[0].cursor + count
                let consumed = native[0].samples[native[0].cursor..<endCursor]
                result.renderedPCM.append(consumed)
                lastRenderedSample = consumed.last
                native[0].cursor = endCursor
                tick += count
                available -= count
                result.renderedSamples += count
                lastRenderedEnd = Double(tick) / configuration.rendererRate
                if endCursor == native[0].samples.count {
                    result.renderedIDs.append(id)
                    result.tailDelays.append(Double(tick) / configuration.rendererRate - configuration.arrival(id))
                    queue.complete(native[0].samples.count, generation: native[0].token)
                    native.removeFirst()
                }
            }
            rendererTicks = nextTick
            checkAccounting()
        }

        private func checkAccounting() {
            // Reservations cover whole outstanding packets, while native lead
            // excludes each packet's already-consumed samples.
            if queue.queuedSamples != native.reduce(0, { $0 + $1.samples.count }) {
                result.accountingErrors += 1
            }
        }

        private func checkUpperBand(_ samples: [Int16], reference: PacketReference) {
            result.maximumUpperBandError = max(result.maximumUpperBandError,
                ReceiveAudioSoakTests.toneError(samples, reference: reference,
                    configuration: configuration, interiorOnly: true))
            let fullError = ReceiveAudioSoakTests.toneError(samples, reference: reference, configuration: configuration)
            if fullError > result.maximumFullBandError, fullError >= 0.10 {
                let errors = samples.enumerated().map { index, sample in
                    abs(Double(sample) - configuration.tone(reference.position(index)))
                }
                let worst = errors.indices.max { errors[$0] < errors[$1] }!
                print("ReceiveAudioSoak edge diagnostic ppm=\(configuration.receiverPPM) packet=\(result.processCalls - 1) ratio=\(clock.correctionRatio) full_error=\(fullError) worst_index=\(worst)/\(samples.count) source=\(reference.position(worst)) actual=\(samples[worst]) expected=\(configuration.tone(reference.position(worst)))")
            }
            result.maximumFullBandError = max(result.maximumFullBandError, fullError)
        }
    }
}
