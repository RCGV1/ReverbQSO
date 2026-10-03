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
        let transmittedPCM: [Int16]
        let encodedPackets: [Data]
        let metrics: Metrics
    }

    typealias Completion = @Sendable (Result?) -> Void

    private let queue: DispatchQueue
    private let generationLock = NSLock()
    private var activeGeneration: UInt64?

    // Accessed only on `queue`.
    private var stateGeneration: UInt64?
    private var resamplerState = PCMLinearResamplerState()
    private var automaticGain = AdaptiveMicrophoneGain()
    private let gsmCodec = GSMCodec()
    private let speexCodec = SpeexCodec()
    private var selectedCodec = EchoLinkVoiceCodec.gsm
    private var hasGSMInput = false
    private var gsmSampleRemainder = 0
    private var gsmFrameRemainder = 0
    private var nextOrdinal: UInt64 = 0
    private var lastProcessedCaptureAt: TimeInterval?

    init(label: String = "org.reverbqso.capture-dsp") {
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
                    now: ProcessInfo.processInfo.systemUptime
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

    /// Flushes after all earlier submitted buffers on the serial queue.
    func flush(generation: UInt64) async -> Data {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard isActive(generation), stateGeneration == generation else {
                    continuation.resume(returning: Data())
                    return
                }
                guard let last = lastProcessedCaptureAt,
                      LiveCaptureBacklogPolicy.isFresh(capturedAt: last, now: ProcessInfo.processInfo.systemUptime) else {
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
        resamplerState.reset()
        automaticGain.reset()
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
}
