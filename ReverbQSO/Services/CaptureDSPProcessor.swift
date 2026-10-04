// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Queue-confined microphone DSP for the native capture callback.
///
/// AudioEngine owns capture lifecycle and delivery. This type owns only the
/// stateful resampler, microphone gain, and transmit encoders so those steps do
/// not depend on MainActor availability.
final class CaptureDSPProcessor: @unchecked Sendable {
    struct Configuration: @unchecked Sendable {
        let codec: EchoLinkVoiceCodec
        let gainMode: MicrophoneGainMode
        let manualGainMultiplier: Double
    }

    struct Metrics: Sendable, Equatable {
        let rawRMS: Double
        let rawPeak: Int
        let codecRMS: Double
        let codecPeak: Int
        let transmittedRMS: Double
        let transmittedPeak: Int
        let appliedGain: Double
        let encodedByteCount: Int
        let gsmSampleRemainder: Int
        let gsmFrameRemainder: Int
    }

    struct Result: Sendable, Equatable {
        let generation: UInt64
        let ordinal: UInt64
        /// Changes whenever encoder continuity is reset inside this generation.
        let streamEpoch: UInt64
        let transmittedPCM: [Int16]
        let encodedPackets: [Data]
        let metrics: Metrics
    }

    typealias Completion = @Sendable (Result?) -> Void

    private let queue: DispatchQueue
    private let now: @Sendable () -> TimeInterval
    private let generationLock = NSLock()
    private var activeGeneration: UInt64?

    // Accessed only on `queue`.
    private var stateGeneration: UInt64?
    private var resamplerState = PCMLinearResamplerState()
    private var automaticGain = AdaptiveMicrophoneGain()
    private let nativeCapturePCM = NativeCapturePCM()
    private var floatAutomaticGain = FloatAutomaticGain()
    private let gsmCodec = GSMCodec()
    private let speexCodec = SpeexCodec()
    private var selectedCodec = EchoLinkVoiceCodec.gsm
    private var hasGSMInput = false
    private var gsmSampleRemainder = 0
    private var gsmFrameRemainder = 0
    private var nextOrdinal: UInt64 = 0
    private var streamEpoch: UInt64 = 0
    private var lastProcessedCaptureAt: TimeInterval?

    init(
        label: String = "org.reverbqso.capture-dsp",
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.now = now
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Establishes a fresh capture generation. FIFO queue ordering guarantees
    /// this reset runs before subsequently submitted buffers.
    func begin(generation: UInt64) {
        setActiveGeneration(generation)
        queue.async { [self] in
            guard isActive(generation) else { return }
            resetQueueConfinedState()
            stateGeneration = generation
        }
    }

    /// Invalidates the generation immediately, then releases its queued state.
    /// Already queued work observes the invalidation before doing DSP.
    func end(generation: UInt64) {
        invalidate(generation)
        queue.async { [self] in
            guard stateGeneration == generation else { return }
            resetQueueConfinedState()
            stateGeneration = nil
        }
    }

    /// Discards predictor history and partial frames after a delivery was rejected.
    /// Already completed results retain their old epoch and must be rejected by
    /// the delivery owner until a result from the next epoch arrives.
    func resetStream(generation: UInt64) {
        queue.async { [self] in
            guard isActive(generation), stateGeneration == generation else { return }
            let ordinal = nextOrdinal
            resetQueueConfinedState()
            nextOrdinal = ordinal
        }
    }

    func submit(
        samples: [Int16],
        sampleRate: Double,
        generation: UInt64,
        capturedAt: TimeInterval,
        configuration: Configuration,
        completion: @escaping Completion
    ) {
        queue.async { [self] in
            guard isActive(generation), stateGeneration == generation,
                  LiveCaptureBacklogPolicy.isFresh(
                    capturedAt: capturedAt,
                    now: now()
                  ) else {
                completion(nil)
                return
            }
            if let previous = lastProcessedCaptureAt, capturedAt - previous > 0.240 {
                // A delivery stall must not splice old partial frames into new speech.
                let ordinal = nextOrdinal
                resetQueueConfinedState()
                nextOrdinal = ordinal
            }
            lastProcessedCaptureAt = capturedAt
            let result = process(
                samples: samples,
                sampleRate: sampleRate,
                generation: generation,
                configuration: configuration
            )
            completion(isActive(generation) ? result : nil)
        }
    }

    /// Processes normalized native capture without reducing it to Int16 before
    /// sample-rate conversion and microphone gain.
    func submit(
        normalizedSamples: [Float],
        sampleRate: Double,
        generation: UInt64,
        capturedAt: TimeInterval,
        configuration: Configuration,
        completion: @escaping Completion
    ) {
        queue.async { [self] in
            guard isActive(generation), stateGeneration == generation,
                  LiveCaptureBacklogPolicy.isFresh(
                    capturedAt: capturedAt,
                    now: now()
                  ) else {
                completion(nil)
                return
            }
            if let previous = lastProcessedCaptureAt, capturedAt - previous > 0.240 {
                let ordinal = nextOrdinal
                resetQueueConfinedState()
                nextOrdinal = ordinal
            }
            lastProcessedCaptureAt = capturedAt
            let result = process(
                normalizedSamples: normalizedSamples,
                sampleRate: sampleRate,
                generation: generation,
                configuration: configuration
            )
            completion(isActive(generation) ? result : nil)
        }
    }

    /// Flushes after all earlier submitted buffers on the serial queue.
    func flush(generation: UInt64) async -> Data {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard isActive(generation), stateGeneration == generation else {
                    continuation.resume(returning: Data())
                    return
                }
                guard let last = lastProcessedCaptureAt,
                      LiveCaptureBacklogPolicy.isFresh(capturedAt: last, now: now()) else {
                    continuation.resume(returning: Data())
                    return
                }
                let output = flushQueueConfined()
                continuation.resume(returning: isActive(generation) ? output : Data())
            }
        }
    }

    private func process(
        samples: [Int16],
        sampleRate: Double,
        generation: UInt64,
        configuration: Configuration
    ) -> Result {
        if selectedCodec != configuration.codec {
            streamEpoch &+= 1
            gsmCodec.resetEncodeState()
            speexCodec.resetEncoding()
            hasGSMInput = false
            gsmSampleRemainder = 0
            gsmFrameRemainder = 0
            selectedCodec = configuration.codec
        }

        let rawRMS = Self.rms(samples)
        let rawPeak = Self.peak(samples)
        let codecInput = PCMLinearResampler.resample(
            samples,
            sourceSampleRate: sampleRate,
            targetSampleRate: Double(GSMCodec.sampleRate),
            state: &resamplerState
        )
        let codecRMS = Self.rms(codecInput)
        let codecPeak = Self.peak(codecInput)

        let transmittedPCM: [Int16]
        let appliedGain: Double
        switch configuration.gainMode {
        case .automatic:
            let result = automaticGain.process(codecInput)
            transmittedPCM = result.samples
            appliedGain = result.appliedGain
        case .manual:
            let result = MicrophoneGainSettings.process(
                codecInput,
                multiplier: configuration.manualGainMultiplier
            )
            transmittedPCM = result.samples
            appliedGain = result.appliedMultiplier
        }

        let packets: [Data]
        switch configuration.codec {
        case .speex:
            packets = speexCodec.encode(transmittedPCM) ?? []
        case .gsm:
            hasGSMInput = hasGSMInput || !transmittedPCM.isEmpty
            gsmSampleRemainder = (gsmSampleRemainder + transmittedPCM.count) % GSMCodec.samplesPerFrame
            let encoded = gsmCodec.encode(transmittedPCM)
            recordGSMFrames(encoded)
            packets = encoded.isEmpty ? [] : [encoded]
        }

        let ordinal = nextOrdinal
        nextOrdinal &+= 1
        return Result(
            generation: generation,
            ordinal: ordinal,
            streamEpoch: streamEpoch,
            transmittedPCM: transmittedPCM,
            encodedPackets: packets,
            metrics: Metrics(
                rawRMS: rawRMS,
                rawPeak: rawPeak,
                codecRMS: codecRMS,
                codecPeak: codecPeak,
                transmittedRMS: Self.rms(transmittedPCM),
                transmittedPeak: Self.peak(transmittedPCM),
                appliedGain: appliedGain,
                encodedByteCount: packets.reduce(0) { $0 + $1.count },
                gsmSampleRemainder: gsmSampleRemainder,
                gsmFrameRemainder: gsmFrameRemainder
            )
        )
    }

    private func process(
        normalizedSamples: [Float],
        sampleRate: Double,
        generation: UInt64,
        configuration: Configuration
    ) -> Result? {
        prepareCodec(configuration.codec)

        let sanitizedSamples = Self.sanitize(normalizedSamples)
        let rawRMS = Self.rms(sanitizedSamples)
        let rawPeak = Self.peak(sanitizedSamples)
        let codecInput: [Float]
        do {
            codecInput = try nativeCapturePCM.resample(
                sanitizedSamples,
                sourceSampleRate: sampleRate
            )
        } catch {
            resetAfterNativeConversionFailure()
            return nil
        }
        let codecRMS = Self.rms(codecInput)
        let codecPeak = Self.peak(codecInput)

        let gained: [Float]
        let appliedGain: Double
        switch configuration.gainMode {
        case .automatic:
            let result = floatAutomaticGain.process(codecInput)
            gained = result.samples
            appliedGain = result.appliedGain
        case .manual:
            let result = Self.applyManualFloatGain(
                codecInput,
                multiplier: configuration.manualGainMultiplier
            )
            gained = result.samples
            appliedGain = result.appliedGain
        }
        let transmittedPCM = Self.quantize(gained)
        let packets = encode(transmittedPCM, codec: configuration.codec)

        let ordinal = nextOrdinal
        nextOrdinal &+= 1
        return Result(
            generation: generation,
            ordinal: ordinal,
            streamEpoch: streamEpoch,
            transmittedPCM: transmittedPCM,
            encodedPackets: packets,
            metrics: Metrics(
                rawRMS: rawRMS,
                rawPeak: rawPeak,
                codecRMS: codecRMS,
                codecPeak: codecPeak,
                transmittedRMS: Self.rms(transmittedPCM),
                transmittedPeak: Self.peak(transmittedPCM),
                appliedGain: appliedGain,
                encodedByteCount: packets.reduce(0) { $0 + $1.count },
                gsmSampleRemainder: gsmSampleRemainder,
                gsmFrameRemainder: gsmFrameRemainder
            )
        )
    }

    private func prepareCodec(_ codec: EchoLinkVoiceCodec) {
        guard selectedCodec != codec else { return }
        streamEpoch &+= 1
        gsmCodec.resetEncodeState()
        speexCodec.resetEncoding()
        hasGSMInput = false
        gsmSampleRemainder = 0
        gsmFrameRemainder = 0
        selectedCodec = codec
    }

    private func encode(_ samples: [Int16], codec: EchoLinkVoiceCodec) -> [Data] {
        switch codec {
        case .speex:
            return speexCodec.encode(samples) ?? []
        case .gsm:
            hasGSMInput = hasGSMInput || !samples.isEmpty
            gsmSampleRemainder = (gsmSampleRemainder + samples.count) % GSMCodec.samplesPerFrame
            let encoded = gsmCodec.encode(samples)
            recordGSMFrames(encoded)
            return encoded.isEmpty ? [] : [encoded]
        }
    }

    private func resetAfterNativeConversionFailure() {
        streamEpoch &+= 1
        nativeCapturePCM.reset()
        floatAutomaticGain.reset()
        gsmCodec.resetEncodeState()
        speexCodec.resetEncoding()
        hasGSMInput = false
        gsmSampleRemainder = 0
        gsmFrameRemainder = 0
    }

    private func flushQueueConfined() -> Data {
        if selectedCodec == .speex { return speexCodec.flushEncoding() ?? Data() }
        guard hasGSMInput else { return Data() }

        let plan = AudioCaptureFlushPlan.make(
            hasCodecInput: hasGSMInput,
            sampleRemainder: gsmSampleRemainder,
            encodedFrameRemainder: gsmFrameRemainder
        )
        var payload = Data()

        func append(_ encoded: Data) {
            guard let frames = GSMCodec.stripHeader(encoded), !frames.isEmpty else { return }
            payload.append(frames)
            recordGSMFrames(encoded)
        }
        if plan.partialFrameSamplePadding > 0 {
            append(gsmCodec.encode([Int16](
                repeating: 0,
                count: plan.partialFrameSamplePadding
            )))
            gsmSampleRemainder = 0
        }
        if plan.silentFramePadding > 0 {
            append(gsmCodec.encode([Int16](
                repeating: 0,
                count: plan.silentFramePadding * GSMCodec.samplesPerFrame
            )))
        }
        return payload.isEmpty ? Data() : GSMCodec.wrapWithHeader(payload)
    }

    private func recordGSMFrames(_ encoded: Data) {
        guard let payload = GSMCodec.stripHeader(encoded),
              payload.count.isMultiple(of: GSMCodec.encodedFrameSize) else { return }
        gsmFrameRemainder = (gsmFrameRemainder + payload.count / GSMCodec.encodedFrameSize) % 4
    }

    private func resetQueueConfinedState() {
        streamEpoch &+= 1
        resamplerState.reset()
        automaticGain.reset()
        nativeCapturePCM.reset()
        floatAutomaticGain.reset()
        gsmCodec.resetEncodeState()
        speexCodec.resetEncoding()
        selectedCodec = .gsm
        nextOrdinal = 0
        lastProcessedCaptureAt = nil
        hasGSMInput = false
        gsmSampleRemainder = 0
        gsmFrameRemainder = 0
    }

    private func setActiveGeneration(_ generation: UInt64) {
        generationLock.lock()
        activeGeneration = generation
        generationLock.unlock()
    }

    private func invalidate(_ generation: UInt64) {
        generationLock.lock()
        if activeGeneration == generation { activeGeneration = nil }
        generationLock.unlock()
    }

    private func isActive(_ generation: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return activeGeneration == generation
    }

    private static func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let squares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return sqrt(squares / Double(samples.count))
    }

    private static func peak(_ samples: [Int16]) -> Int {
        samples.reduce(0) { max($0, abs(Int($1))) }
    }

    private static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let squares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return sqrt(squares / Double(samples.count)) * Double(Int16.max)
    }

    private static func peak(_ samples: [Float]) -> Int {
        Int((samples.reduce(0 as Float) { max($0, abs($1)) } * Float(Int16.max)).rounded())
    }

    private static func quantize(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let finite = sample.isFinite ? sample : 0
            let normalized = min(1, max(-1, finite))
            return Int16(clamping: Int((normalized * Float(Int16.max)).rounded()))
        }
    }

    private static func sanitize(_ samples: [Float]) -> [Float] {
        samples.map { sample in
            guard sample.isFinite else { return 0 }
            return min(1, max(-1, sample))
        }
    }

    private static func applyManualFloatGain(
        _ samples: [Float],
        multiplier: Double
    ) -> (samples: [Float], appliedGain: Double) {
        let requested = multiplier.isFinite ? min(max(multiplier, 0.25), 4) : 1
        guard !samples.isEmpty else { return ([], requested) }
        let peak = Double(samples.reduce(0 as Float) { max($0, abs($1)) })
        let ceiling = 30_000.0 / Double(Int16.max)
        let applied = requested > 1 && peak > 0
            ? min(requested, max(1, ceiling / peak))
            : requested
        return (samples.map { Float(Double($0) * applied) }, applied)
    }
}

private struct FloatAutomaticGain {
    struct Result {
        let samples: [Float]
        let appliedGain: Double
    }

    private var previousGain: Double?
    private let targetRMS = 2_500.0 / Double(Int16.max)
    private let maximumGain = 8.0
    private let noiseFloorRMS = 60.0 / Double(Int16.max)
    private let maximumPeak = 30_000.0 / Double(Int16.max)

    mutating func reset() {
        previousGain = nil
    }

    mutating func process(_ samples: [Float]) -> Result {
        guard !samples.isEmpty else { return Result(samples: [], appliedGain: 1) }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        guard rms >= noiseFloorRMS else {
            return Result(samples: samples, appliedGain: 1)
        }
        let peak = Double(samples.reduce(0 as Float) { max($0, abs($1)) })
        let voiceGain = min(maximumGain, max(1, targetRMS / rms))
        let transition = min(1, (rms - noiseFloorRMS) / noiseFloorRMS)
        let voiceWeight = transition * transition * (3 - 2 * transition)
        let requestedGain = 1 + (voiceGain - 1) * voiceWeight
        let recovery = 1 - exp(-Double(samples.count) / 8_000 / 0.03)
        let smoothedGain = previousGain.map { prior in
            requestedGain < prior ? requestedGain : prior + (requestedGain - prior) * recovery
        } ?? requestedGain
        let appliedGain = peak > 0 ? min(smoothedGain, maximumPeak / peak) : smoothedGain
        previousGain = appliedGain
        return Result(samples: samples.map { Float(Double($0) * appliedGain) }, appliedGain: appliedGain)
    }
}
