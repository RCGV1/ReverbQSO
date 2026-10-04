// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation

/// Converts native capture PCM to normalized mono Float32 and then to the
/// codec's 8 kHz rate without quantizing before sample-rate conversion.
final class NativeCapturePCM {
    enum ConversionError: Error {
        case invalidSampleRate
        case inputTooLarge
        case formatUnavailable
        case conversionFailed(Error?)
    }

    static let targetSampleRate = 8_000.0
    private static let maximumPendingDuration = 0.240

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var destinationFormat: AVAudioFormat?
    // The owning capture DSP queue serializes conversion. Retain only the
    // current format's buffers and grow them when a hardware chunk grows.
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
#if DEBUG
    private(set) var auditBufferAllocationCount = 0
#endif

    /// Selects one physical input channel. Mixing microphone channels can
    /// cancel speech when their signals have different phase or delay.
    static func extractSamples(
        from buffer: AVAudioPCMBuffer,
        channelIndex: Int = 0
    ) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channelIndex >= 0, channelIndex < channels else { return [] }

        let interleaved = buffer.format.isInterleaved
        let list = buffer.mutableAudioBufferList
        let bufferIndex = interleaved ? 0 : channelIndex
        guard bufferIndex < Int(list.pointee.mNumberBuffers),
              let buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) else { return [] }
        // The C list stores a variable-length array beginning at mBuffers.
        // Access it directly; its Swift collection overlay is absent on Catalyst.
        let audioBuffers = UnsafeMutableRawPointer(list).advanced(by: buffersOffset)
            .assumingMemoryBound(to: AudioBuffer.self)
        guard let rawData = audioBuffers[bufferIndex].mData else { return [] }
        let stride = interleaved ? channels : 1
        let offset = interleaved ? channelIndex : 0

        func normalized(_ sample: Float) -> Float {
            guard sample.isFinite else { return 0 }
            return min(1, max(-1, sample))
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            let data = rawData.assumingMemoryBound(to: Float.self)
            return (0..<frames).map { normalized(data[$0 * stride + offset]) }
        case .pcmFormatFloat64:
            let data = rawData.assumingMemoryBound(to: Double.self)
            return (0..<frames).map { normalized(Float(data[$0 * stride + offset])) }
        case .pcmFormatInt16:
            let data = rawData.assumingMemoryBound(to: Int16.self)
            return (0..<frames).map {
                normalized(Float(data[$0 * stride + offset]) / Float(Int16.max))
            }
        case .pcmFormatInt32:
            let data = rawData.assumingMemoryBound(to: Int32.self)
            return (0..<frames).map {
                normalized(Float(Double(data[$0 * stride + offset]) / Double(Int32.max)))
            }
        default:
            return []
        }
    }

    func resample(_ samples: [Float], sourceSampleRate: Double) throws -> [Float] {
        guard sourceSampleRate.isFinite,
              sourceSampleRate >= 1_000,
              sourceSampleRate <= 384_000 else {
            throw ConversionError.invalidSampleRate
        }
        guard samples.count <= Int((sourceSampleRate * Self.maximumPendingDuration).rounded(.up)) else {
            throw ConversionError.inputTooLarge
        }
        guard !samples.isEmpty else { return [] }
        if abs(sourceSampleRate - Self.targetSampleRate) < 0.5 {
            if sourceFormat?.sampleRate != sourceSampleRate { reset() }
            return samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        }

        try prepareConverter(sourceSampleRate: sourceSampleRate)
        guard let converter, let sourceFormat, let destinationFormat else {
            throw ConversionError.formatUnavailable
        }
        let inputCapacity = AVAudioFrameCount(samples.count)
        if (inputBuffer?.frameCapacity ?? 0) < inputCapacity {
            guard let replacement = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity) else {
                throw ConversionError.formatUnavailable
            }
            inputBuffer = replacement
#if DEBUG
            auditBufferAllocationCount += 1
#endif
        }
        guard let input = inputBuffer else { throw ConversionError.formatUnavailable }
        input.frameLength = inputCapacity
        guard let inputData = input.floatChannelData?[0] else {
            throw ConversionError.formatUnavailable
        }
        for index in samples.indices {
            let value = samples[index]
            inputData[index] = value.isFinite ? min(1, max(-1, value)) : 0
        }

        let expectedFrames = Int(ceil(Double(samples.count) * Self.targetSampleRate / sourceSampleRate))
        let outputCapacity = AVAudioFrameCount(max(1, expectedFrames + 32))
        if (outputBuffer?.frameCapacity ?? 0) < outputCapacity {
            guard let replacement = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: outputCapacity) else {
                throw ConversionError.formatUnavailable
            }
            outputBuffer = replacement
#if DEBUG
            auditBufferAllocationCount += 1
#endif
        }
        guard let output = outputBuffer else { throw ConversionError.formatUnavailable }
        output.frameLength = 0

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status == .haveData || status == .inputRanDry else {
            throw ConversionError.conversionFailed(conversionError)
        }
        guard let outputData = output.floatChannelData?[0] else {
            throw ConversionError.formatUnavailable
        }
        return (0..<Int(output.frameLength)).map { outputData[$0] }
    }

    /// With primeMethod.none Apple's converter reports no EOS tail. Feed at
    /// most 20 ms of silence to release its minimum-phase filter history, then
    /// discard the converter. This adds at most 160 codec samples before final
    /// packet padding and can require one additional padded voice packet.
    func finish() throws -> [Float] {
        guard converter != nil, let rate = sourceFormat?.sampleRate else { return [] }
        defer { reset() }
        let silence = [Float](repeating: 0, count: Int((rate * 0.020).rounded(.down)))
        let tail = try resample(silence, sourceSampleRate: rate)
        guard tail.count <= 160 else { throw ConversionError.inputTooLarge }
        return tail
    }

    func reset() {
        converter?.reset()
        converter = nil
        sourceFormat = nil
        destinationFormat = nil
        inputBuffer = nil
        outputBuffer = nil
    }

    private func prepareConverter(sourceSampleRate: Double) throws {
        if let sourceFormat, abs(sourceFormat.sampleRate - sourceSampleRate) < 0.5 { return }
        reset()
        guard let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ), let destination = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let newConverter = AVAudioConverter(from: source, to: destination) else {
            throw ConversionError.formatUnavailable
        }
        newConverter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        newConverter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_MinimumPhase
        newConverter.primeMethod = .none
        sourceFormat = source
        destinationFormat = destination
        converter = newConverter
    }
}
