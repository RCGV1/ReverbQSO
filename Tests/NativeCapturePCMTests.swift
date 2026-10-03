// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import XCTest
#if canImport(ReverbQSO)
@testable import ReverbQSO
#endif

final class NativeCapturePCMTests: XCTestCase {
    func testExtractsPrimaryFloatChannelWithoutAveragingAntiphaseStereo() throws {
        let buffer = try makeBuffer(format: .pcmFormatFloat32, interleaved: false, channels: 2, frames: 3)
        let data = try XCTUnwrap(buffer.floatChannelData)
        data[0][0] = 0.25
        data[0][1] = -0.5
        data[0][2] = 0.75
        data[1][0] = -0.25
        data[1][1] = 0.5
        data[1][2] = -0.75

        XCTAssertEqual(NativeCapturePCM.extractSamples(from: buffer), [0.25, -0.5, 0.75])
    }

    func testExtractsEverySupportedPCMRepresentationAndLayout() throws {
        for commonFormat in [
            AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatFloat64,
            .pcmFormatInt16, .pcmFormatInt32
        ] {
            for interleaved in [false, true] {
                let buffer = try makeBuffer(
                    format: commonFormat, interleaved: interleaved, channels: 2, frames: 3)
                writeNormalized([0.25, -0.5, 0.75], toChannel: 0, in: buffer)
                writeNormalized([-0.75, 0.5, -0.25], toChannel: 1, in: buffer)

                let output = NativeCapturePCM.extractSamples(from: buffer)

                XCTAssertEqual(output.count, 3, "\(commonFormat) interleaved=\(interleaved)")
                XCTAssertEqual(output[0], 0.25, accuracy: 0.000_1)
                XCTAssertEqual(output[1], -0.5, accuracy: 0.000_1)
                XCTAssertEqual(output[2], 0.75, accuracy: 0.000_1)
            }
        }
    }

    func testExtractionSanitizesNonfiniteAndClipsToNormalizedHeadroom() throws {
        let buffer = try makeBuffer(format: .pcmFormatFloat32, interleaved: false, channels: 1, frames: 6)
        let data = try XCTUnwrap(buffer.floatChannelData)[0]
        [Float.nan, .infinity, -.infinity, 1.5, -2, 0.125].enumerated().forEach { data[$0] = $1 }

        XCTAssertEqual(NativeCapturePCM.extractSamples(from: buffer), [0, 0, 0, 1, -1, 0.125])
    }

    func testInvalidChannelAndEmptyBufferAreSafe() throws {
        let buffer = try makeBuffer(format: .pcmFormatFloat32, interleaved: false, channels: 1, frames: 0)
        XCTAssertTrue(NativeCapturePCM.extractSamples(from: buffer).isEmpty)
        buffer.frameLength = 1
        buffer.floatChannelData?[0][0] = 0.5
        XCTAssertTrue(NativeCapturePCM.extractSamples(from: buffer, channelIndex: 1).isEmpty)
    }

    func testStreamingResamplerTracksExactLongRunSampleCount() throws {
        var measuredSteadyGains: [Float] = []
        for sourceRate in [44_100.0, 48_000.0, 96_000.0] {
            let converter = NativeCapturePCM()
            var output: [Float] = []
            let chunkFrames = Int(sourceRate * 0.02)
            for _ in 0..<50 {
                output += try converter.resample(
                    [Float](repeating: 0.25, count: chunkFrames), sourceSampleRate: sourceRate)
            }
            XCTAssertEqual(output.count, 8_000, "source rate \(sourceRate)")
            let steadyGain = (output.dropFirst(64).last ?? 0) / 0.25
            measuredSteadyGains.append(steadyGain)
            XCTAssertGreaterThanOrEqual(steadyGain, 0.985,
                                        "Unexpected native converter DC loss at \(sourceRate)")
            XCTAssertLessThanOrEqual(steadyGain, 1,
                                     "Native conversion must not add clipping headroom risk")
        }
        XCTAssertLessThan(
            Double((measuredSteadyGains.max() ?? 0) - (measuredSteadyGains.min() ?? 0)),
            0.000_1,
            "Minimum-phase steady gain should remain consistent across hardware rates"
        )
    }

    func testStreamingChunksMatchOneShotConversion() throws {
        let sourceRate = 44_100.0
        let input = sine(frequency: 1_000, sampleRate: sourceRate, duration: 0.2)
        let oneShot = try NativeCapturePCM().resample(input, sourceSampleRate: sourceRate)
        let streaming = NativeCapturePCM()
        var chunked: [Float] = []
        var offset = 0
        for size in [73, 211, 19, 480, 73, 1024, 61].cycled(while: { offset < input.count }) {
            let end = min(input.count, offset + size)
            chunked += try streaming.resample(Array(input[offset..<end]), sourceSampleRate: sourceRate)
            offset = end
        }

        XCTAssertEqual(chunked.count, oneShot.count)
        XCTAssertLessThan(rmsDifference(chunked, oneShot), 0.002)
    }

    func testResamplerPreservesSpeechBandAndRejectsTransitionBandAlias() throws {
        for sourceRate in [44_100.0, 48_000.0, 96_000.0] {
            let passband = try NativeCapturePCM().resample(
                sine(frequency: 3_000, sampleRate: sourceRate, duration: 0.2),
                sourceSampleRate: sourceRate)
            let passbandRMS = rms(Array(passband.dropFirst(128)))
            XCTAssertGreaterThan(passbandRMS, 0.62, "3 kHz loss at \(sourceRate)")

            for frequency in [4_100.0, 4_500.0, 5_000.0] {
                let stopband = try NativeCapturePCM().resample(
                    sine(frequency: frequency, sampleRate: sourceRate, duration: 0.2),
                    sourceSampleRate: sourceRate)
                XCTAssertLessThan(
                    rms(Array(stopband.dropFirst(128))), passbandRMS * 0.05,
                    "\(frequency) Hz alias insufficiently rejected at \(sourceRate)")
            }
        }
    }

    func testResetDropsPriorConverterState() throws {
        let converter = NativeCapturePCM()
        _ = try converter.resample([Float](repeating: 1, count: 4_800), sourceSampleRate: 48_000)
        converter.reset()
        let output = try converter.resample([Float](repeating: 0, count: 4_800), sourceSampleRate: 48_000)
        XCTAssertLessThan(rms(Array(output.dropFirst(128))), 0.000_1)
    }

    func testRejectsOutOfRangeSampleRatesBeforeSizingBuffers() {
        let converter = NativeCapturePCM()
        XCTAssertThrowsError(try converter.resample([0], sourceSampleRate: 999))
        XCTAssertThrowsError(try converter.resample([0], sourceSampleRate: 384_001))
        XCTAssertThrowsError(try converter.resample([0], sourceSampleRate: .greatestFiniteMagnitude))
    }

    private func makeBuffer(
        format: AVAudioCommonFormat,
        interleaved: Bool,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let audioFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: format, sampleRate: 48_000,
            channels: channels, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: audioFormat, frameCapacity: max(frames, 1)))
        buffer.frameLength = frames
        return buffer
    }

    private func writeNormalized(_ samples: [Float], toChannel channel: Int, in buffer: AVAudioPCMBuffer) {
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        let offset = buffer.format.isInterleaved ? channel : 0
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            let pointer = buffer.floatChannelData![buffer.format.isInterleaved ? 0 : channel]
            for index in samples.indices { pointer[index * stride + offset] = samples[index] }
        case .pcmFormatFloat64:
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let audioBuffer = audioBuffers[buffer.format.isInterleaved ? 0 : channel]
            let pointer = audioBuffer.mData!.assumingMemoryBound(to: Double.self)
            for index in samples.indices { pointer[index * stride + offset] = Double(samples[index]) }
        case .pcmFormatInt16:
            let pointer = buffer.int16ChannelData![buffer.format.isInterleaved ? 0 : channel]
            for index in samples.indices {
                pointer[index * stride + offset] = Int16((samples[index] * Float(Int16.max)).rounded())
            }
        case .pcmFormatInt32:
            let pointer = buffer.int32ChannelData![buffer.format.isInterleaved ? 0 : channel]
            for index in samples.indices {
                pointer[index * stride + offset] = Int32((Double(samples[index]) * Double(Int32.max)).rounded())
            }
        default:
            XCTFail("Unsupported test format")
        }
    }

    private func sine(frequency: Double, sampleRate: Double, duration: Double) -> [Float] {
        (0..<Int(sampleRate * duration)).map { index in
            Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }

    private func rmsDifference(_ lhs: [Float], _ rhs: [Float]) -> Double {
        rms(zip(lhs, rhs).map { $0 - $1 })
    }
}

private extension Array {
    func cycled(while condition: @escaping () -> Bool) -> AnySequence<Element> {
        AnySequence {
            var index = 0
            return AnyIterator<Element> {
                guard condition(), !isEmpty else { return nil }
                defer { index += 1 }
                return self[index % count]
            }
        }
    }
}
