// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class CaptureDSPProcessorTests: XCTestCase {
    private let manualUnity = CaptureDSPProcessor.Configuration(
        codec: .gsm,
        gainMode: .manual,
        manualGainMultiplier: 1
    )

    func testProcessingMatchesExistingResamplerAndGSMCodec() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        let generation: UInt64 = 1
        let input = (0..<960).map { Int16(($0 % 101) * 200 - 10_000) }
        var expectedState = PCMLinearResamplerState()
        let expectedPCM = PCMLinearResampler.resample(
            input,
            sourceSampleRate: 48_000,
            targetSampleRate: 8_000,
            state: &expectedState
        )
        let expectedEncoded = GSMCodec().encode(expectedPCM)
        processor.begin(generation: generation)

        let result = try await submit(
            processor, samples: input, sampleRate: 48_000,
            generation: generation, configuration: manualUnity
        )

        XCTAssertEqual(result.transmittedPCM, expectedPCM)
        XCTAssertEqual(result.encodedPackets, [expectedEncoded])
        XCTAssertEqual(result.metrics.gsmSampleRemainder, 0)
        XCTAssertEqual(result.metrics.gsmFrameRemainder, 1)
    }

    func testSequentialSubmissionsPreserveStreamingResamplerState() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        let generation: UInt64 = 2
        processor.begin(generation: generation)
        let input = (0..<1_000).map { Int16(($0 % 97) * 300 - 12_000) }
        var actual: [Int16] = []
        for offset in stride(from: 0, to: input.count, by: 73) {
            let end = min(input.count, offset + 73)
            let result = try await submit(
                processor, samples: Array(input[offset..<end]), sampleRate: 44_100,
                generation: generation, configuration: manualUnity
            )
            actual += result.transmittedPCM
        }
        var expectedState = PCMLinearResamplerState()
        let expected = PCMLinearResampler.resample(
            input, sourceSampleRate: 44_100, targetSampleRate: 8_000,
            state: &expectedState
        )
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertLessThanOrEqual(zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0, 256)
    }

    func testEndImmediatelyRejectsOldGeneration() async {
        let processor = CaptureDSPProcessor(label: #function)
        processor.begin(generation: 3)
        processor.end(generation: 3)

        let result = await submitOptional(
            processor, samples: [1, -1], sampleRate: 8_000,
            generation: 3, configuration: manualUnity
        )
        XCTAssertNil(result)
        let flushed = await processor.flush(generation: 3)
        XCTAssertTrue(flushed.isEmpty)
    }

    func testNewGenerationDoesNotInheritGSMRemainder() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        processor.begin(generation: 4)
        _ = try await submit(
            processor, samples: [Int16](repeating: 100, count: 79), sampleRate: 8_000,
            generation: 4, configuration: manualUnity
        )
        processor.begin(generation: 5)

        let result = try await submit(
            processor, samples: [Int16](repeating: 200, count: 160), sampleRate: 8_000,
            generation: 5, configuration: manualUnity
        )
        XCTAssertEqual(result.metrics.gsmSampleRemainder, 0)
        XCTAssertEqual(result.encodedPackets.first?.count, 4 + GSMCodec.encodedFrameSize)
    }

    func testEndingOldGenerationDoesNotResetNewGenerationPartialFrame() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        processor.begin(generation: 8)
        processor.begin(generation: 9)
        let first = try await submit(
            processor, samples: [Int16](repeating: 300, count: 79), sampleRate: 8_000,
            generation: 9, configuration: manualUnity
        )
        XCTAssertTrue(first.encodedPackets.isEmpty)

        processor.end(generation: 8)
        let second = try await submit(
            processor, samples: [Int16](repeating: 300, count: 81), sampleRate: 8_000,
            generation: 9, configuration: manualUnity
        )

        XCTAssertEqual(second.encodedPackets.first?.count, 4 + GSMCodec.encodedFrameSize)
        XCTAssertEqual(second.metrics.gsmSampleRemainder, 0)
    }

    func testDSPCompletionDoesNotWaitForMainActor() async {
        let processor = CaptureDSPProcessor(label: #function)
        let generation: UInt64 = 10
        let mainActorStarted = expectation(description: "main actor occupied")
        let dspCompleted = expectation(description: "DSP completed")
        let releaseMainActor = DispatchSemaphore(value: 0)
        processor.begin(generation: generation)

        DispatchQueue.main.async {
            mainActorStarted.fulfill()
            releaseMainActor.wait()
        }
        await fulfillment(of: [mainActorStarted], timeout: 1)

        processor.submit(
            samples: [Int16](repeating: 500, count: 160),
            sampleRate: 8_000,
            generation: generation,
            capturedAt: ProcessInfo.processInfo.systemUptime,
            configuration: manualUnity
        ) { result in
            XCTAssertNotNil(result)
            dspCompleted.fulfill()
            releaseMainActor.signal()
        }
        await fulfillment(of: [dspCompleted], timeout: 1)
        // Also release on timeout so a regression cannot strand the test runner's main actor.
        releaseMainActor.signal()
    }

    func testLongCaptureGapDiscardsOldPartialFrame() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        processor.begin(generation: 11)
        _ = try await submit(processor, samples: [Int16](repeating: 500, count: 79),
            sampleRate: 8000, generation: 11, configuration: manualUnity)
        try await Task.sleep(for: .milliseconds(270))
        let staleFlush = await processor.flush(generation: 11)
        XCTAssertTrue(staleFlush.isEmpty)
        let resumed = try await submit(processor, samples: [Int16](repeating: 1000, count: 81),
            sampleRate: 8000, generation: 11, configuration: manualUnity)
        XCTAssertTrue(resumed.encodedPackets.isEmpty)
        XCTAssertEqual(resumed.metrics.gsmSampleRemainder, 81)
        XCTAssertEqual(resumed.ordinal, 1)
    }

    func testFlushPadsGSMToFourFramePacketBoundary() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        let generation: UInt64 = 6
        processor.begin(generation: generation)
        _ = try await submit(
            processor, samples: [Int16](repeating: 500, count: 137), sampleRate: 8_000,
            generation: generation, configuration: manualUnity
        )

        let flushed = await processor.flush(generation: generation)
        let payload = try XCTUnwrap(GSMCodec.stripHeader(flushed))
        XCTAssertEqual(payload.count, 4 * GSMCodec.encodedFrameSize)
        XCTAssertEqual(GSMCodec().decodePacket(flushed).count, 4 * GSMCodec.samplesPerFrame)
    }

    func testManualGainIsAppliedBeforeEncoding() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        let generation: UInt64 = 7
        processor.begin(generation: generation)
        let configuration = CaptureDSPProcessor.Configuration(
            codec: .gsm, gainMode: .manual, manualGainMultiplier: 2
        )

        let result = try await submit(
            processor, samples: [1_000, -1_000], sampleRate: 8_000,
            generation: generation, configuration: configuration
        )
        XCTAssertEqual(result.transmittedPCM, [2_000, -2_000])
        XCTAssertEqual(result.metrics.appliedGain, 2)
    }

    func testNormalizedFloatPathAppliesGainBeforeSingleInt16Quantization() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        let generation: UInt64 = 12
        processor.begin(generation: generation)
        let configuration = CaptureDSPProcessor.Configuration(
            codec: .gsm, gainMode: .manual, manualGainMultiplier: 4
        )

        let result = try await submit(
            processor, normalizedSamples: [0.25 / Float(Int16.max), -0.25 / Float(Int16.max)],
            sampleRate: 8_000, generation: generation, configuration: configuration
        )

        XCTAssertEqual(result.transmittedPCM, [1, -1],
                       "Gain must run in Float before the only Int16 quantization")
        XCTAssertEqual(result.metrics.appliedGain, 4)
    }

    func testNormalizedFloatPathUsesNativeStreamingSampleRateConversion() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        let generation: UInt64 = 13
        processor.begin(generation: generation)
        var output: [Int16] = []

        for _ in 0..<50 {
            let result = try await submit(
                processor, normalizedSamples: [Float](repeating: 0.25, count: 960),
                sampleRate: 48_000, generation: generation, configuration: manualUnity
            )
            output += result.transmittedPCM
        }

        XCTAssertEqual(output.count, 8_000)
        let expectedNativeSteadySample = Int16((0.25 * 0.989_806 * Float(Int16.max)).rounded())
        XCTAssertEqual(output.dropFirst(64).last ?? 0, expectedNativeSteadySample, accuracy: 2,
                       "Preserve Apple's measured minimum-phase steady gain without another gain stage")
    }

    func testNormalizedFloatPathSanitizesNonfiniteSamplesBeforeMetricsAndGain() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        let generation: UInt64 = 14
        processor.begin(generation: generation)

        let result = try await submit(
            processor,
            normalizedSamples: [.nan, .infinity, -.infinity, 0.25, 2, -2],
            sampleRate: 8_000, generation: generation, configuration: manualUnity
        )

        XCTAssertEqual(result.transmittedPCM, [0, 0, 0, 8_192, 32_767, -32_767])
        XCTAssertTrue(result.metrics.rawRMS.isFinite)
        XCTAssertEqual(result.metrics.rawPeak, Int(Int16.max))
    }

    func testRejectedDeliveryResetDoesNotSpliceItsPartialSamplesIntoFreshAudio() async throws {
        let processor = CaptureDSPProcessor(label: #function)
        processor.begin(generation: 21)
        let rejected = try await submit(processor, samples: [Int16](repeating: 500, count: 79),
            sampleRate: 8_000, generation: 21, configuration: manualUnity)

        processor.resetStream(generation: 21)
        let fresh = try await submit(processor, samples: [Int16](repeating: 1_000, count: 81),
            sampleRate: 8_000, generation: 21, configuration: manualUnity)

        XCTAssertNotEqual(rejected.streamEpoch, fresh.streamEpoch)
        XCTAssertEqual(fresh.ordinal, rejected.ordinal + 1)
        XCTAssertTrue(fresh.encodedPackets.isEmpty)
        XCTAssertEqual(fresh.metrics.gsmSampleRemainder, 81)
    }

    func testCaptureStreamResetDiscardsOldPacketFragmentsBeforeResumingAndFlush() async throws {
        let clock = TestCaptureClock()
        let processor = CaptureDSPProcessor(label: #function, now: { clock.read() })
        processor.begin(generation: 20)
        func process(_ samples: [Int16]) async throws -> CaptureDSPProcessor.Result {
            let result: CaptureDSPProcessor.Result? = await withCheckedContinuation { continuation in
                processor.submit(samples: samples, sampleRate: 8_000, generation: 20,
                    capturedAt: clock.read(), configuration: manualUnity) {
                    continuation.resume(returning: $0)
                }
            }
            return try XCTUnwrap(result)
        }
        let first = try await process([Int16](repeating: 500, count: 480))
        var packetBuffer = try XCTUnwrap(GSMCodec.stripHeader(try XCTUnwrap(first.encodedPackets.first)))
        XCTAssertEqual(packetBuffer.count, 99)
        XCTAssertTrue(EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &packetBuffer).isEmpty)

        clock.advance(by: 0.3)
        let resumed = try await process([Int16](repeating: 1_000, count: 160))
        XCTAssertNotEqual(first.streamEpoch, resumed.streamEpoch)
        XCTAssertEqual(resumed.ordinal, first.ordinal + 1)
        // AudioEngine propagates the epoch transition to the packetizer before delivery.
        packetBuffer.removeAll(keepingCapacity: true)
        packetBuffer.append(try XCTUnwrap(GSMCodec.stripHeader(try XCTUnwrap(resumed.encodedPackets.first))))
        XCTAssertTrue(EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &packetBuffer).isEmpty)
        let flushed = await processor.flush(generation: 20)
        packetBuffer.append(try XCTUnwrap(GSMCodec.stripHeader(flushed)))
        let packets = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &packetBuffer)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.first?.count, 132)
        XCTAssertTrue(packetBuffer.isEmpty, "Flush must finish the resumed packet without an abandoned tail")
    }

    private func submit(
        _ processor: CaptureDSPProcessor,
        samples: [Int16],
        sampleRate: Double,
        generation: UInt64,
        configuration: CaptureDSPProcessor.Configuration
    ) async throws -> CaptureDSPProcessor.Result {
        let result = await submitOptional(
            processor, samples: samples, sampleRate: sampleRate,
            generation: generation, configuration: configuration
        )
        return try XCTUnwrap(result)
    }

    private func submitOptional(
        _ processor: CaptureDSPProcessor,
        samples: [Int16],
        sampleRate: Double,
        generation: UInt64,
        configuration: CaptureDSPProcessor.Configuration
    ) async -> CaptureDSPProcessor.Result? {
        await withCheckedContinuation { continuation in
            processor.submit(
                samples: samples,
                sampleRate: sampleRate,
                generation: generation,
                capturedAt: ProcessInfo.processInfo.systemUptime,
                configuration: configuration
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func submit(
        _ processor: CaptureDSPProcessor,
        normalizedSamples: [Float],
        sampleRate: Double,
        generation: UInt64,
        configuration: CaptureDSPProcessor.Configuration
    ) async throws -> CaptureDSPProcessor.Result {
        let result: CaptureDSPProcessor.Result? = await withCheckedContinuation { continuation in
            processor.submit(
                normalizedSamples: normalizedSamples,
                sampleRate: sampleRate,
                generation: generation,
                capturedAt: ProcessInfo.processInfo.systemUptime,
                configuration: configuration
            ) { result in
                continuation.resume(returning: result)
            }
        }
        return try XCTUnwrap(result)
    }
}

private final class TestCaptureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func read() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return time
    }
    func advance(by interval: TimeInterval) {
        lock.lock()
        time += interval
        lock.unlock()
    }
}
