// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class PCMLinearResamplerTests: XCTestCase {

    private func rms(_ samples: [Int16], droppingPrefix count: Int = 0) -> Double {
        let measured = samples.dropFirst(min(count, samples.count))
        guard !measured.isEmpty else { return 0 }
        return sqrt(measured.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(measured.count))
    }

    private func sine(frequency: Double, sampleRate: Double, duration: Double,
                      amplitude: Double = 12_000) -> [Int16] {
        (0..<Int(sampleRate * duration)).map { index in
            Int16((amplitude * sin(2 * .pi * frequency * Double(index) / sampleRate)).rounded())
        }
    }

    func testResampleEmptyInputReturnsEmpty() {
        var state = PCMLinearResamplerState()
        let output = PCMLinearResampler.resample(
            [],
            sourceSampleRate: 48_000,
            targetSampleRate: 8_000,
            state: &state
        )
        XCTAssertTrue(output.isEmpty)
    }

    func testResamplePassThroughWhenRatesMatch() {
        var state = PCMLinearResamplerState()
        let input = (0..<128).map(Int16.init)

        let output = PCMLinearResampler.resample(
            input,
            sourceSampleRate: 8_000,
            targetSampleRate: 8_000,
            state: &state
        )

        XCTAssertEqual(output, input)
    }

    func testDownsample48000To8000HasExpectedLength() {
        var state = PCMLinearResamplerState()
        let input = [Int16](repeating: 1_000, count: 480)

        let output = PCMLinearResampler.resample(
            input,
            sourceSampleRate: 48_000,
            targetSampleRate: 8_000,
            state: &state
        )

        XCTAssertEqual(output.count, 80)
    }

    func testUpsample8000To16000HasExpectedLength() {
        var state = PCMLinearResamplerState()
        let input = [Int16](repeating: 500, count: 80)

        let output = PCMLinearResampler.resample(
            input,
            sourceSampleRate: 8_000,
            targetSampleRate: 16_000,
            state: &state
        )

        XCTAssertEqual(output.count, 160)
    }

    func testChunkedResamplingMatchesOneShotResult() {
        let input = (0..<1_000).map { i in
            Int16((i % 97) * 300 - 12_000)
        }

        var oneShotState = PCMLinearResamplerState()
        let oneShot = PCMLinearResampler.resample(
            input,
            sourceSampleRate: 44_100,
            targetSampleRate: 8_000,
            state: &oneShotState
        )

        var chunkedState = PCMLinearResamplerState()
        var chunked: [Int16] = []
        var offset = 0
        let chunkSizes = [73, 41, 109, 64, 87, 53, 128, 77, 92, 143, 133]
        var chunkIndex = 0

        while offset < input.count {
            let size = chunkSizes[chunkIndex % chunkSizes.count]
            let end = min(input.count, offset + size)
            let part = Array(input[offset..<end])
            chunked.append(
                contentsOf: PCMLinearResampler.resample(
                    part,
                    sourceSampleRate: 44_100,
                    targetSampleRate: 8_000,
                    state: &chunkedState
                )
            )
            offset = end
            chunkIndex += 1
        }

        XCTAssertEqual(chunked.count, oneShot.count)
        let maxDifference = zip(chunked, oneShot)
            .map { abs(Int($0) - Int($1)) }
            .max() ?? 0
        XCTAssertLessThanOrEqual(maxDifference, 256)
    }

    func testSourceRateChangeResetsState() {
        var state = PCMLinearResamplerState()
        let first = [Int16](repeating: 200, count: 480)
        let second = [Int16](repeating: 300, count: 160)

        _ = PCMLinearResampler.resample(
            first,
            sourceSampleRate: 48_000,
            targetSampleRate: 8_000,
            state: &state
        )
        let output = PCMLinearResampler.resample(
            second,
            sourceSampleRate: 16_000,
            targetSampleRate: 8_000,
            state: &state
        )

        XCTAssertEqual(output.count, 80)
        XCTAssertEqual(Set(output), [300], "The prior rate's filter history must not leak into the new stream")
    }

    func testInvalidSourceRateReturnsOriginalSamples() {
        var state = PCMLinearResamplerState()
        let input = (0..<64).map(Int16.init)

        let output = PCMLinearResampler.resample(
            input,
            sourceSampleRate: 0,
            targetSampleRate: 8_000,
            state: &state
        )

        XCTAssertEqual(output, input)
    }

    func testInvalidTargetRateReturnsOriginalSamples() {
        var state = PCMLinearResamplerState()
        let input = (0..<64).map(Int16.init)

        let output = PCMLinearResampler.resample(
            input,
            sourceSampleRate: 48_000,
            targetSampleRate: 0,
            state: &state
        )

        XCTAssertEqual(output, input)
    }

    func testConstantSignalRemainsStableAfterDownsampling() {
        var state = PCMLinearResamplerState()
        let input = [Int16](repeating: 1_234, count: 441)

        let output = PCMLinearResampler.resample(
            input,
            sourceSampleRate: 44_100,
            targetSampleRate: 8_000,
            state: &state
        )

        XCTAssertFalse(output.isEmpty)
        let minValue = output.min() ?? 0
        let maxValue = output.max() ?? 0
        XCTAssertLessThanOrEqual(Int(maxValue - minValue), 1)
        XCTAssertEqual(output.first, 1_234)
    }

    func testStreamingDownsampleLengthTracksExpectedTotal() {
        var state = PCMLinearResamplerState()
        var totalOutputCount = 0

        for _ in 0..<10 {
            let inputChunk = [Int16](repeating: 500, count: 480)
            let output = PCMLinearResampler.resample(
                inputChunk,
                sourceSampleRate: 48_000,
                targetSampleRate: 8_000,
                state: &state
            )
            totalOutputCount += output.count
        }

        XCTAssertEqual(totalOutputCount, 800)
    }

    func testDownsamplingPreservesSpeechBandAndRejectsOutOfBandAlias() {
        for sourceRate in [44_100.0, 48_000.0, 96_000.0] {
            var passbandState = PCMLinearResamplerState()
            let passband = PCMLinearResampler.resample(
                sine(frequency: 1_000, sampleRate: sourceRate, duration: 0.25),
                sourceSampleRate: sourceRate,
                targetSampleRate: 8_000,
                state: &passbandState
            )

            var stopbandState = PCMLinearResamplerState()
            let aliased = PCMLinearResampler.resample(
                sine(frequency: 6_000, sampleRate: sourceRate, duration: 0.25),
                sourceSampleRate: sourceRate,
                targetSampleRate: 8_000,
                state: &stopbandState
            )

            let passbandRMS = rms(passband, droppingPrefix: 32)
            let aliasRMS = rms(aliased, droppingPrefix: 32)
            XCTAssertGreaterThan(passbandRMS, 7_000, "1 kHz passband loss at \(sourceRate) Hz")
            XCTAssertLessThan(aliasRMS, passbandRMS * 0.03,
                              "6 kHz alias insufficiently suppressed at \(sourceRate) Hz")
        }
    }

    func testDownsamplingPreservesUpperSpeechBand() {
        let unfilteredRMS = 12_000 / sqrt(2.0)
        for sourceRate in [44_100.0, 48_000.0, 96_000.0] {
            var state = PCMLinearResamplerState()
            let output = PCMLinearResampler.resample(
                sine(frequency: 3_000, sampleRate: sourceRate, duration: 0.25),
                sourceSampleRate: sourceRate,
                targetSampleRate: 8_000,
                state: &state
            )

            XCTAssertGreaterThan(
                rms(output, droppingPrefix: 32) / unfilteredRMS,
                0.93,
                "3 kHz speech-band loss at \(sourceRate) Hz"
            )
        }
    }

    func testFilteredDownsamplingIsStableAcrossArbitraryChunkBoundaries() {
        for sourceRate in [44_100.0, 48_000.0, 96_000.0] {
            let input = sine(frequency: 1_000, sampleRate: sourceRate, duration: 0.25)
            var oneShotState = PCMLinearResamplerState()
            let oneShot = PCMLinearResampler.resample(
                input, sourceSampleRate: sourceRate, targetSampleRate: 8_000, state: &oneShotState)

            var chunkedState = PCMLinearResamplerState()
            var chunked: [Int16] = []
            var offset = 0
            let sizes = [37, 211, 19, 480, 73, 1024, 61]
            var index = 0
            while offset < input.count {
                let end = min(input.count, offset + sizes[index % sizes.count])
                chunked += PCMLinearResampler.resample(
                    Array(input[offset..<end]), sourceSampleRate: sourceRate,
                    targetSampleRate: 8_000, state: &chunkedState)
                offset = end
                index += 1
            }

            XCTAssertEqual(chunked.count, oneShot.count)
            XCTAssertLessThanOrEqual(
                zip(chunked, oneShot).map { abs(Int($0) - Int($1)) }.max() ?? 0,
                256,
                "Chunk boundary discontinuity at \(sourceRate) Hz"
            )
        }
    }
}
