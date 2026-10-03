// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import Combine
import os

enum AudioOutputPreference: String, CaseIterable {
    case speaker
    case receiver
    case system
}

struct AudioCaptureFlushPlan: Equatable {
    let partialFrameSamplePadding: Int
    let silentFramePadding: Int

    static func make(
        hasCodecInput: Bool,
        sampleRemainder: Int,
        encodedFrameRemainder: Int
    ) -> AudioCaptureFlushPlan {
        guard hasCodecInput else {
            return AudioCaptureFlushPlan(partialFrameSamplePadding: 0, silentFramePadding: 0)
        }

        let samplePadding = sampleRemainder > 0
            ? GSMCodec.samplesPerFrame - sampleRemainder
            : 0
        let completedPartialFrame = samplePadding > 0 ? 1 : 0
        let framesPerPacket = 4
        let frameRemainder = (
            encodedFrameRemainder + completedPartialFrame
        ) % framesPerPacket
        let silentFramePadding = (framesPerPacket - frameRemainder) % framesPerPacket

        return AudioCaptureFlushPlan(
            partialFrameSamplePadding: samplePadding,
            silentFramePadding: silentFramePadding
        )
    }
}

/// Raises quiet microphone speech to a useful GSM input level without
/// changing playback volume or amplifying near-silence between words.
struct AdaptiveMicrophoneGain {
    struct Result {
        let samples: [Int16]
        let appliedGain: Double
    }

    private var previousGain: Double?
    private let targetRMS = 2_500.0
    private let maximumGain = 8.0
    private let noiseFloorRMS = 60.0
    private let maximumPeak = 30_000.0

    mutating func reset() {
        previousGain = nil
    }

    mutating func process(_ samples: [Int16]) -> Result {
        guard !samples.isEmpty else { return Result(samples: [], appliedGain: 1) }
        let sumOfSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = sqrt(sumOfSquares / Double(samples.count))
        guard rms >= noiseFloorRMS else {
            // Keep very soft syllables intact while declining to boost the
            // noise floor between words.
            return Result(samples: samples, appliedGain: 1)
        }

        let peak = Double(samples.reduce(0) { max($0, abs(Int($1))) })
        let requestedGain = min(maximumGain, max(1, targetRMS / rms))
        let smoothedGain = previousGain.map { prior in
            requestedGain < prior ? requestedGain : prior + (requestedGain - prior) * 0.5
        } ?? requestedGain
        let appliedGain = min(smoothedGain, maximumPeak / peak)
        previousGain = appliedGain

        let output = samples.map { sample in
            Int16(clamping: Int((Double(sample) * appliedGain).rounded()))
        }
        return Result(samples: output, appliedGain: appliedGain)
    }
}

enum MicrophoneGainMode: String, CaseIterable {
    case automatic
    case manual
}

/// Microphone gain applied to PCM before GSM encoding. A peak ceiling
/// prevents a manual boost from clipping when the microphone is already loud.
enum MicrophoneGainSettings {
    static let key = "microphoneGainMultiplier"
    static let modeKey = "microphoneGainMode"
    static let minimum = 0.25
    static let maximum = 4.0

    struct Result {
        let samples: [Int16]
        let appliedMultiplier: Double
    }

    static func mode(defaults: UserDefaults = .standard) -> MicrophoneGainMode {
        MicrophoneGainMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .automatic
    }

    static func load(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil else { return 1 }
        return normalized(defaults.double(forKey: key))
    }

    static func apply(_ samples: [Int16], multiplier: Double) -> [Int16] {
        process(samples, multiplier: multiplier).samples
    }

    static func process(_ samples: [Int16], multiplier: Double) -> Result {
        let requested = normalized(multiplier)
        guard !samples.isEmpty else { return Result(samples: [], appliedMultiplier: requested) }
        let peak = Double(samples.reduce(0) { max($0, abs(Int($1))) })
        let applied = requested > 1 && peak > 0
            ? min(requested, max(1, 30_000 / peak))
            : requested
        guard applied != 1 else { return Result(samples: samples, appliedMultiplier: 1) }
        return Result(
            samples: samples.map { Int16(clamping: Int((Double($0) * applied).rounded())) },
            appliedMultiplier: applied
        )
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, minimum), maximum)
    }
}

private final class CaptureBufferProcessingBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingCount = 0
    private var isSealed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSealed else { return false }
        pendingCount += 1
        return true
    }

    func leave() {
        lock.lock()
        precondition(pendingCount > 0)
        pendingCount -= 1
        guard pendingCount == 0, isSealed else {
            lock.unlock()
            return
        }
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func sealAndWait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            isSealed = true
            if pendingCount == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// The tap stays installed for the QSO. Only callbacks admitted while PTT is
/// down may enter the encoder; sealing the gate makes release deterministic.
private final class CaptureTapGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: (CaptureBufferProcessingBarrier, UInt64)?
    private var firstBufferSeen = false

    func activate(_ barrier: CaptureBufferProcessingBarrier, generation: UInt64) {
        lock.lock()
        active = (barrier, generation)
        lock.unlock()
    }

    func deactivate() -> CaptureBufferProcessingBarrier? {
        lock.lock()
        let barrier = active?.0
        active = nil
        lock.unlock()
        return barrier
    }

    func admitBuffer() -> (barrier: CaptureBufferProcessingBarrier, generation: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let (barrier, generation) = active, barrier.enter() else { return nil }
        return (barrier, generation)
    }

    func markFirstBuffer() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !firstBufferSeen else { return false }
        firstBufferSeen = true
        return true
    }

    func resetFirstBuffer() {
        lock.lock()
        firstBufferSeen = false
        lock.unlock()
    }
}

/// Manages audio capture and playback for EchoLink QSO sessions.
///
/// Uses AVAudioEngine for low-latency audio I/O. Captured PCM audio is
/// passed through the GSMCodec for encoding before transmission.
/// Received encoded audio is decoded and played through the output node.
@MainActor
final class AudioEngine: ObservableObject {
    private struct SessionObserverToken: @unchecked Sendable {
        let rawValue: NSObjectProtocol
    }

    // MARK: - Published State

    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isCaptureReady = false
    @Published private(set) var capturePreparationFailed = false
    @Published var inputLevel: Double = 0.0
    @Published var outputLevel: Double = 0.0
    @Published private(set) var outputRouteName = "System Audio"
#if os(iOS) && !targetEnvironment(macCatalyst)
    @Published private(set) var outputPreference: AudioOutputPreference = .system
#else
    @Published private(set) var outputPreference: AudioOutputPreference = .speaker
#endif

    // MARK: - Audio Components

    private var engine = AVAudioEngine()
    private let codec = GSMCodec()
    private let speexCodec = SpeexCodec()
    private(set) var transmitCodec: EchoLinkVoiceCodec = .gsm
    var isSpeexTransmitAvailable: Bool { speexCodec.isEncoderAvailable }
    /// Optional second consumer for host fanout, after resampling and microphone gain.
    var onCapturedPCM: (@MainActor ([Int16]) -> Void)?

    @discardableResult
    func setTransmitCodec(_ selected: EchoLinkVoiceCodec) -> Bool {
        guard !captureRequested, selected != .speex || isSpeexTransmitAvailable else { return false }
        transmitCodec = selected
        codec.resetEncodeState()
        speexCodec.resetEncoding()
        return true
    }
    var onRecordingPCM: (@MainActor ([Int16]) -> Void)?
    private let playerNode = AVAudioPlayerNode()
    private let logger = Logger(subsystem: "org.reverbqso.app", category: "AudioEngine")
    private var isConfigured = false
    private var tapInstalled = false
    private var tapVersion: UInt64 = 0
    private var captureRequested = false
    @Published private(set) var isPreparingCapture = false
    private var captureGeneration: UInt64 = 0
    private var captureDrainGeneration: UInt64?
    private var captureBufferBarrier = CaptureBufferProcessingBarrier()
    private let captureTapGate = CaptureTapGate()
    private var prepareCaptureTask: Task<Void, Never>?
    private var resumeCaptureAfterInterruption = false
    private var captureRecoveryTask: Task<Void, Never>?
    private var isPerformingCaptureRecovery = false
    private var outputLevelDecayTask: Task<Void, Never>?
    private var captureRecoveryFailureCount = 0
    private var captureResamplerState = PCMLinearResamplerState()
    private var captureCodecSampleRemainder = 0
    private var captureEncodedFrameRemainder = 0
    private var captureHasCodecInput = false
    private var captureBufferCount = 0
    private var captureSampleCount = 0
    private var captureEncodedByteCount = 0
    private var capturePeakLevel = 0.0
    private var capturePeakRawRMS = 0.0
    private var capturePeakRawSample = 0
    private var capturePeakCodecRMS = 0.0
    private var capturePeakCodecSample = 0
    private var microphoneGain = AdaptiveMicrophoneGain()
    private var captureMaximumAppliedGain = 0.0
    private var capturePeakTransmittedRMS = 0.0
    private var capturePeakTransmittedSample = 0
    private var rxWindowActive = false
    private var rxWindowPacketCount = 0
    private var rxWindowMaxRMS = 0.0
    private var rxWindowPeak = 0
    private var sessionObservers: [SessionObserverToken] = []
    private var hasInstalledSessionObservers = false

    private func replaceEngineAfterSessionActivation() {
        // An input node created while its hardware route was disabled can keep
        // reporting 0 Hz even after the session becomes valid. A new engine
        // creates a new input node against the now-active route.
        playerNode.stop()
        engine.stop()
        if engine.attachedNodes.contains(playerNode) {
            engine.detach(playerNode)
        }
        for token in sessionObservers {
            NotificationCenter.default.removeObserver(token.rawValue)
        }
        sessionObservers.removeAll()
        hasInstalledSessionObservers = false
        engine = AVAudioEngine()
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            VoiceDiagnosticLog.record("fresh engine voice processing enabled AGC=\(engine.inputNode.isVoiceProcessingAGCEnabled)")
        } catch {
            VoiceDiagnosticLog.record("fresh engine voice processing unavailable error=\(error.localizedDescription)")
            // Discard any partially configured I/O unit before using the
            // proven unprocessed path on devices that reject voice I/O.
            engine = AVAudioEngine()
        }
#endif
        isConfigured = false
        isRunning = false
        installAudioSessionObserversIfNeeded()
        let freshInput = engine.inputNode
        let format = freshInput.outputFormat(forBus: 0)
        VoiceDiagnosticLog.record("fresh engine input format channels=\(format.channelCount) rate=\(format.sampleRate)")
    }

    /// Callback invoked with encoded audio data ready for transmission.
    var onCapturedAudio: (@MainActor (Data) -> Void)?

    // MARK: - Configuration

    private let sampleRate: Double = 8000
    private let channelCount: AVAudioChannelCount = 1
    /// Fixed receive-side gain to compensate for low telephony-level decoded PCM.
    private let playbackGain: Float = 2.5

    private var captureFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )
    }

    // MARK: - Lifecycle

    deinit {
        prepareCaptureTask?.cancel()
        captureRecoveryTask?.cancel()
        for token in sessionObservers {
            NotificationCenter.default.removeObserver(token.rawValue)
        }
    }

    /// Start playback/capture engine so received audio can be rendered even when not transmitting.
    func startPlayback() {
        guard !isRunning else { return }

        do {
            installAudioSessionObserversIfNeeded()
            try configureAudioSession()
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            // Build the input node only after the session owns a hardware mic
            // route. Reusing the preactivation engine leaves it at 0 Hz on
            // physical iPhone even though AVAudioSession reports 48 kHz input.
            replaceEngineAfterSessionActivation()
#endif
            try setupEngineIfNeeded()
            playerNode.volume = 1.0
            engine.mainMixerNode.outputVolume = 1.0
            try engine.start()
            isRunning = true
            logRouteDiagnostics(context: "playback-engine-started")
            // Start the player node immediately so the first received buffer
            // renders without the extra scheduling round-trip on first arrival.
            playerNode.play()
            ensurePlaybackOutputRoute()
            updateOutputRouteName()
        } catch {
            logger.error("Failed to start playback error='\(error.localizedDescription, privacy: .public)'")
            resetEngineGraph()
            isRunning = false
        }
    }

    /// Prepare the microphone while the station is connected, before a PTT
    /// gesture. RX remains available if permission or the input route fails.
    func prepareCaptureInput() async -> Bool {
#if targetEnvironment(simulator)
        return false
#else
        guard !isCaptureReady else { return true }
        guard !isPreparingCapture else { return false }
        isPreparingCapture = true
        capturePreparationFailed = false
        defer { isPreparingCapture = false }

        for attempt in 0..<3 {
            guard !Task.isCancelled else { return false }
            if tapInstalled { stopCaptureTap(preservingIntent: false) }
            let installed = await startCapture()
            captureRequested = false
            if installed {
                for _ in 0..<20 {
                    if isCaptureReady { return true }
                    guard !Task.isCancelled else { return false }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            VoiceDiagnosticLog.record("capture preparation attempt=\(attempt + 1) inputCallback=\(isCaptureReady)")
            stopCaptureTap(preservingIntent: false)
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        capturePreparationFailed = true
        return false
#endif
    }

    /// Start capturing audio from the microphone (PTT pressed).
    func startCapture() async -> Bool {
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        if tapInstalled && isCaptureReady && !isPreparingCapture {
            guard !captureRequested else { return true }
            captureRequested = true
            captureGeneration &+= 1
            captureBufferBarrier = CaptureBufferProcessingBarrier()
            captureBufferCount = 0
            captureSampleCount = 0
            captureEncodedByteCount = 0
            capturePeakLevel = 0
            resetCaptureLevelDiagnostics()
            captureDrainGeneration = nil
            captureResamplerState.reset()
            microphoneGain.reset()
            codec.resetEncodeState()
            resetCaptureEncodingCounters()
            captureTapGate.activate(captureBufferBarrier, generation: captureGeneration)
            VoiceDiagnosticLog.record("capture began from ready input graph")
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
            VoiceDiagnosticLog.record("PTT audio route preference=\(outputPreference.rawValue) outputs=[\(outputs)] voiceProcessing=\(engine.inputNode.isVoiceProcessingEnabled) AGC=\(engine.inputNode.isVoiceProcessingAGCEnabled) bypassed=\(engine.inputNode.isVoiceProcessingBypassed) inputMuted=\(engine.inputNode.isVoiceProcessingInputMuted)")
            return true
        }
        guard isPreparingCapture else { return false }
#endif
        let isContinuingCaptureRequest = captureRequested
        captureRequested = true
        VoiceDiagnosticLog.record("capture requested running=\(engine.isRunning) configured=\(isConfigured)")
        guard !isCapturing else { return true }

        if !isContinuingCaptureRequest {
            resetCaptureEncodingCounters()
            captureBufferCount = 0
            captureSampleCount = 0
            captureEncodedByteCount = 0
            capturePeakLevel = 0
            resetCaptureLevelDiagnostics()
            captureBufferBarrier = CaptureBufferProcessingBarrier()
            captureDrainGeneration = nil
        }

        captureGeneration &+= 1
        let generation = captureGeneration
        captureRecoveryTask?.cancel()
        captureRecoveryTask = nil
#if targetEnvironment(simulator)
        captureRequested = false
        logger.info("PTT capture disabled on Simulator (no reliable mic input chain)")
        return false
#else
        let hasPermission = await ensureRecordPermission()
        VoiceDiagnosticLog.record("microphone permission granted=\(hasPermission)")
        guard isCaptureRequestCurrent(generation) else { return false }
        guard hasPermission else {
            logger.error("Microphone permission denied; capture not started")
            captureRequested = false
            return false
        }

        if !isRunning { startPlayback() }
        guard isRunning else {
            captureRequested = false
            return false
        }

        do {
            try ensureSessionReadyForCapture()
        } catch {
            logger.error("Failed to prepare audio session for capture error='\(error.localizedDescription, privacy: .public)'")
        }

        let inputNode = engine.inputNode
        logRouteDiagnostics(context: "capture-before-format")
        let outputFormat = inputNode.outputFormat(forBus: 0)
        let inputFormat = inputNode.inputFormat(forBus: 0)
        logger.debug(
            "Capture format candidates output(ch=\(outputFormat.channelCount),rate=\(outputFormat.sampleRate)) input(ch=\(inputFormat.channelCount),rate=\(inputFormat.sampleRate))"
        )
        VoiceDiagnosticLog.record(
            "capture formats outputChannels=\(outputFormat.channelCount) outputRate=\(outputFormat.sampleRate) inputChannels=\(inputFormat.channelCount) inputRate=\(inputFormat.sampleRate)"
        )

        // Quick check: try to resolve an explicit tap format (3 attempts ≈ 225ms).
        var selectedFormat = await resolveCaptureTapFormat(
            inputNode: inputNode,
            maxAttempts: 3,
            retryDelay: .milliseconds(75),
            generation: generation
        )
        guard isCaptureRequestCurrent(generation) else { return false }

        stopCaptureTap(preservingIntent: true)

        // Fast path: use the resolved format if available.
        if let safeTapFormat = validatedTapFormat(for: inputNode, preferred: selectedFormat),
           installCaptureTap(on: inputNode, format: safeTapFormat, generation: generation) {
            guard activateCaptureGraphAfterInstallingTap() else { return false }
            if !isPreparingCapture { captureTapGate.activate(captureBufferBarrier, generation: generation) }
            logger.debug(
                "Capture started using native tap format (selected candidate rate=\(safeTapFormat.sampleRate) channels=\(safeTapFormat.channelCount))"
            )
            return true
        }

        // Never ask AVAudioEngine to infer a format from a 0 Hz route. Wait for a
        // validated live output format, escalating through route recovery as needed.
        logger.warning(
            "Capture route not ready (0Hz input/output). Attempting session reactivation recovery output(ch=\(outputFormat.channelCount),rate=\(outputFormat.sampleRate)) input(ch=\(inputFormat.channelCount),rate=\(inputFormat.sampleRate))"
        )
        selectedFormat = await recoverCaptureTapFormat(generation: generation)
        guard isCaptureRequestCurrent(generation) else { return false }

        if selectedFormat == nil {
            logRouteDiagnostics(context: "capture-format-unavailable")
        }

        stopCaptureTap(preservingIntent: true)
        let recoveredInputNode = engine.inputNode
        if let safeTapFormat = validatedTapFormat(for: recoveredInputNode, preferred: selectedFormat),
           installCaptureTap(on: recoveredInputNode, format: safeTapFormat, generation: generation) {
            guard activateCaptureGraphAfterInstallingTap() else { return false }
            if !isPreparingCapture { captureTapGate.activate(captureBufferBarrier, generation: generation) }
            logger.debug(
                "Capture started using native tap format after recovery (rate=\(safeTapFormat.sampleRate) channels=\(safeTapFormat.channelCount))"
            )
            return true
        }

        logger.error("Capture aborted: input route unavailable (0Hz). Tap not installed to avoid AVAudioEngine crash")
        stopCaptureTap(preservingIntent: true)
        if isCaptureRequestCurrent(generation) {
            scheduleCaptureRecoveryAfterFailure(reason: "route-unavailable")
        }
        return false
#endif
    }

    /// Stop microphone capture (PTT released) while keeping playback alive.
    func stopCapture() {
        _ = stopCaptureAndFlush()
    }

    /// Stop capture and emit the final zero-padded four-frame voice payload.
    ///
    /// The returned data is the same data synchronously delivered through
    /// `onCapturedAudio`; callers should use one delivery path, not both.
    @discardableResult
    func stopCaptureAndFlush() -> Data {
        invalidateCaptureStart(preservingIntent: false)
        captureRecoveryFailureCount = 0
        recordCaptureLevelSummary()
        let finalAudio = flushCaptureEncoderToPacketBoundary()
        logger.info("PTT capture buffers=\(self.captureBufferCount) samples=\(self.captureSampleCount) encodedBytes=\(self.captureEncodedByteCount) peakLevel=\(self.capturePeakLevel) flushBytes=\(finalAudio.count)")
        if !finalAudio.isEmpty {
            onCapturedAudio?(finalAudio)
        }
        codec.resetEncodeState()
        resetCaptureEncodingCounters()
        return finalAudio
    }

    /// Stop the input tap, process callbacks already handed off by AVAudioEngine,
    /// then emit the final zero-padded four-frame voice payload.
    @discardableResult
    func stopCaptureAndFlushPendingBuffers() async -> Data {
        let generation = captureGeneration
        let barrier = captureTapGate.deactivate() ?? captureBufferBarrier
        captureRequested = false
        captureRecoveryTask?.cancel()
        captureRecoveryTask = nil
        captureDrainGeneration = generation
#if !os(iOS) || targetEnvironment(macCatalyst) || targetEnvironment(simulator)
        stopCaptureTap(preservingIntent: false, resetResampler: false)
#endif

        await barrier.sealAndWait()
        guard captureGeneration == generation,
              captureDrainGeneration == generation else { return Data() }

        captureGeneration &+= 1
        captureDrainGeneration = nil
        captureRecoveryFailureCount = 0
        recordCaptureLevelSummary()
        let finalAudio = flushCaptureEncoderToPacketBoundary()
        logger.info("PTT capture buffers=\(self.captureBufferCount) samples=\(self.captureSampleCount) encodedBytes=\(self.captureEncodedByteCount) peakLevel=\(self.capturePeakLevel) flushBytes=\(finalAudio.count)")
        if !finalAudio.isEmpty {
            onCapturedAudio?(finalAudio)
        }
        codec.resetEncodeState()
        captureResamplerState.reset()
        resetCaptureEncodingCounters()
        inputLevel = 0
#if targetEnvironment(macCatalyst)
        // Restart the player timeline after the input graph was rebuilt for
        // capture. Incoming EchoLink packets arrive after PTT is released.
        if isRunning {
            playerNode.stop()
            playerNode.play()
            ensurePlaybackOutputRoute()
            logger.info("Playback resumed after PTT engineRunning=\(self.engine.isRunning) playerPlaying=\(self.playerNode.isPlaying)")
        }
#endif
        return finalAudio
    }

    /// Fully stop audio playback + capture for session teardown.
    func stopAll() {
        rxWindowActive = false
        prepareCaptureTask?.cancel()
        prepareCaptureTask = nil
        isCaptureReady = false
        capturePreparationFailed = false
        invalidateCaptureStart(preservingIntent: false)
        captureRecoveryFailureCount = 0
        playerNode.stop()
        if isRunning {
            engine.stop()
        }
        isRunning = false
        outputLevelDecayTask?.cancel()
        outputLevelDecayTask = nil
        outputLevel = 0
        inputLevel = 0
        // Reset all codec state for a clean session.
        codec.resetAll()
        speexCodec.reset()
        resetCaptureEncodingCounters()
    }

    /// Reset codec state without stopping the engine.
    ///
    /// Call at the start of a new QSO session to ensure no stale
    /// encoder/decoder state leaks across connections.
    func resetCodecState() {
        codec.resetAll()
        speexCodec.reset()
        resetCaptureEncodingCounters()
    }

    /// Play received encoded audio data through the speaker.
    ///
    /// Each call corresponds to a self-contained network packet, so we use
    /// `decodePacket()` which discards any stale partial-frame bytes from
    /// prior packets. This prevents audio corruption after packet loss.
    func playReceivedAudio(_ data: Data, diagnoseFirstRXAfterPTT: Bool = false) {
        if !isRunning {
            startPlayback()
        }
        guard isRunning else { return }

        let pcmSamples = codec.decodePacket(data)
        guard !pcmSamples.isEmpty else { return }
        onRecordingPCM?(pcmSamples)
        accumulateRXWindow(samples: pcmSamples)

        guard let format = captureFormat,
              let buffer = pcmBuffer(from: pcmSamples, format: format) else { return }

        playerNode.scheduleBuffer(buffer)

        if !playerNode.isPlaying {
            playerNode.play()
        }

        if diagnoseFirstRXAfterPTT {
            recordFirstRXDiagnostics(samples: pcmSamples, codec: "GSM")
        }

        recordOutputLevel(from: pcmSamples)
    }

    /// Decode an EchoLink Speex datagram before receive activity/mute decisions.
    func decodeReceivedSpeex(_ payload: Data) -> [Int16]? {
        speexCodec.decodePacket(payload)
    }

    /// Play decoded PCM audio samples directly.
    func playReceivedPCM(_ samples: [Int16], diagnoseFirstRXAfterPTT: Bool = false) {
        if !isRunning {
            startPlayback()
        }
        guard isRunning else { return }
        guard !samples.isEmpty else { return }
        onRecordingPCM?(samples)
        accumulateRXWindow(samples: samples)

        guard let format = captureFormat,
              let buffer = pcmBuffer(from: samples, format: format) else { return }

        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying {
            playerNode.play()
        }

        if diagnoseFirstRXAfterPTT {
            recordFirstRXDiagnostics(samples: samples, codec: "PCM")
        }

        recordOutputLevel(from: samples)
    }

    /// Record the latest receive level and clear it when packet playback stops.
    func recordOutputLevel(
        from samples: [Int16],
        decayAfter: Duration = .milliseconds(250)
    ) {
        let rms = computeRMS(samples)
        outputLevel = min(1.0, rms / 10000.0)
        outputLevelDecayTask?.cancel()
        outputLevelDecayTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: decayAfter)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.outputLevel = 0
            self?.outputLevelDecayTask = nil
        }
    }

    // MARK: - Private Setup

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
#if os(watchOS)
        // watchOS owns route selection and does not expose iOS route preferences.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
#elseif targetEnvironment(simulator)
        // Simulator has limited VoIP I/O support; prefer stable playback.
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
#else
        do {
            // Note: .allowBluetoothA2DP is NOT supported with .voiceChat mode per Apple docs;
            // only .allowBluetoothHFP is valid there.
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: voiceChatRouteOptions
            )
        } catch {
            logger.error("Audio session voiceChat category failed, falling back error='\(error.localizedDescription, privacy: .public)'")
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: fallbackRouteOptions
            )
        }
#if !os(watchOS)
        do {
            try session.setPreferredSampleRate(sampleRate)
        } catch {
            logger.debug("Preferred sample rate not applied error='\(error.localizedDescription, privacy: .public)'")
        }
        do {
            try session.setPreferredIOBufferDuration(0.02)
        } catch {
            logger.debug("Preferred IO buffer duration not applied error='\(error.localizedDescription, privacy: .public)'")
        }
#endif
#endif
        try session.setActive(true)
        logRouteDiagnostics(context: "session-activated")
        ensurePlaybackOutputRoute(session: session)
        updateOutputRouteName(session: session)
    }

#if !os(watchOS)
    private var voiceChatRouteOptions: AVAudioSession.CategoryOptions {
#if targetEnvironment(macCatalyst)
        [.defaultToSpeaker, .allowBluetoothHFP]
#else
        [.allowBluetoothHFP]
#endif
    }

    private var fallbackRouteOptions: AVAudioSession.CategoryOptions {
#if targetEnvironment(macCatalyst)
        [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
#else
        [.allowBluetoothHFP, .allowBluetoothA2DP]
#endif
    }
#endif

    func setOutputPreference(_ preference: AudioOutputPreference) {
        outputPreference = preference
#if !os(watchOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord else { return }
        do {
            switch preference {
            case .speaker, .receiver:
                // Select the built-in input as well so a Bluetooth HFP route
                // cannot keep the handset or speaker choice on the headset.
                if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try session.setPreferredInput(builtInMic)
                }
                try session.overrideOutputAudioPort(preference == .speaker ? .speaker : .none)
            case .system:
                try session.setPreferredInput(nil)
                try session.overrideOutputAudioPort(.none)
            }
        } catch {
            logger.error("Could not select audio output: \(error.localizedDescription, privacy: .public)")
        }
        updateOutputRouteName(session: session)
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        VoiceDiagnosticLog.record("audio route selected preference=\(preference.rawValue) outputs=[\(outputs)]")
#endif
    }

    private func updateOutputRouteName(session: AVAudioSession = AVAudioSession.sharedInstance()) {
        outputRouteName = session.currentRoute.outputs.first?.portName ?? "System Audio"
    }

    private func ensureSessionReadyForCapture() throws {
#if targetEnvironment(simulator)
        return
#else
        let session = AVAudioSession.sharedInstance()
        let hasPlayAndRecordCategory = session.category == .playAndRecord
        let hasExpectedMode = session.mode == .voiceChat || session.mode == .default

        if !hasPlayAndRecordCategory || !hasExpectedMode || !session.isInputAvailable {
            logger.debug(
                "Reconfiguring audio session before capture category='\(session.category.rawValue, privacy: .public)' mode='\(session.mode.rawValue, privacy: .public)' isInputAvailable=\(session.isInputAvailable)"
            )
            try configureAudioSession()
        } else {
            try session.setActive(true)
            normalizePreferredInputIfNeeded(session: session)
            ensurePlaybackOutputRoute(session: session)
        }
#endif
    }

    private func setupEngineIfNeeded() throws {
        guard !isConfigured else { return }

        engine.attach(playerNode)

        guard let format = captureFormat else {
            throw NSError(domain: "AudioEngine", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create audio format"
            ])
        }

        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        isConfigured = true
    }

    // MARK: - Audio Utilities

    private nonisolated static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        let channels = max(Int(buffer.format.channelCount), 1)

        if let channelData = buffer.int16ChannelData {
            var samples = [Int16](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                var mixed: Int32 = 0
                for channel in 0..<channels {
                    mixed += Int32(channelData[channel][i])
                }
                samples[i] = Int16(clamping: mixed / Int32(channels))
            }
            return samples
        }

        if let floatData = buffer.floatChannelData {
            var samples = [Int16](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                var mixed: Float = 0
                for channel in 0..<channels {
                    mixed += floatData[channel][i]
                }
                let mono = mixed / Float(channels)
                let clamped = max(-1.0, min(1.0, mono))
                samples[i] = Int16(clamped * Float(Int16.max))
            }
            return samples
        }

        return []
    }

    private func pcmBuffer(from samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let floatData = buffer.floatChannelData else {
            logger.error("Playback buffer missing float channel data")
            return nil
        }

        let channels = Int(format.channelCount)
        for i in 0..<samples.count {
            let normalized = (Float(samples[i]) / Float(Int16.max)) * playbackGain
            let clamped = max(-1.0, min(1.0, normalized))
            for channel in 0..<channels {
                floatData[channel][i] = clamped
            }
        }

        return buffer
    }

    private func computeRMS(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return sqrt(sumOfSquares / Double(samples.count))
    }

    private func recordFirstRXDiagnostics(samples: [Int16], codec: String) {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let peak = samples.reduce(0) { max($0, abs(Int($1))) }
        VoiceDiagnosticLog.record(
            "first RX after PTT codec=\(codec) samples=\(samples.count) rms=\(computeRMS(samples)) peak=\(peak) engineRunning=\(engine.isRunning) playerPlaying=\(playerNode.isPlaying) playerAttached=\(engine.attachedNodes.contains(playerNode)) route=[\(route)] outputVolume=\(session.outputVolume)"
        )
    }

    func beginRXWindowAfterPTT() {
        rxWindowActive = true
        rxWindowPacketCount = 0
        rxWindowMaxRMS = 0
        rxWindowPeak = 0
    }

    func finishRXWindowAfterPTT() {
        guard rxWindowActive else { return }
        rxWindowActive = false
        VoiceDiagnosticLog.record("RX after PTT window packets=\(rxWindowPacketCount) maxRMS=\(rxWindowMaxRMS) peak=\(rxWindowPeak)")
    }

    private func accumulateRXWindow(samples: [Int16]) {
        guard rxWindowActive else { return }
        rxWindowPacketCount += 1
        rxWindowMaxRMS = max(rxWindowMaxRMS, computeRMS(samples))
        rxWindowPeak = max(rxWindowPeak, samples.reduce(0) { max($0, abs(Int($1))) })
    }

    private func ensureRecordPermission() async -> Bool {
        await MicrophoneAccess.request()
    }

    private func selectTapFormat(outputFormat: AVAudioFormat, inputFormat: AVAudioFormat) -> AVAudioFormat? {
        if isUsableHardwareFormat(outputFormat) {
            return outputFormat
        }
        if isUsableHardwareFormat(inputFormat) {
            logger.debug(
                "Ignoring input-side bus format as capture tap candidate; input taps must use the input node output bus format output(ch=\(outputFormat.channelCount),rate=\(outputFormat.sampleRate)) input(ch=\(inputFormat.channelCount),rate=\(inputFormat.sampleRate))"
            )
        }
        return nil
    }

    private func resolveCaptureTapFormat(
        inputNode: AVAudioInputNode,
        maxAttempts: Int,
        retryDelay: Duration,
        generation: UInt64
    ) async -> AVAudioFormat? {
        // Routes can report 0 Hz briefly after activation; retry for a short window.
        for _ in 0..<maxAttempts {
            guard isCaptureRequestCurrent(generation) else { return nil }
            let outputFormat = inputNode.outputFormat(forBus: 0)
            let inputFormat = inputNode.inputFormat(forBus: 0)
            if let format = selectTapFormat(outputFormat: outputFormat, inputFormat: inputFormat) {
                return format
            }
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return nil
            }
            guard isCaptureRequestCurrent(generation) else { return nil }
        }
        return nil
    }

    private func recoverCaptureTapFormat(generation: UInt64) async -> AVAudioFormat? {
        guard isCaptureRequestCurrent(generation) else { return nil }
        let session = AVAudioSession.sharedInstance()

        // A confirmed 0 Hz route needs a real session + graph rebuild. Waiting
        // on setActive(true) is ineffective when the session is already active,
        // and makes ordinary PTT presses expire before useful recovery begins.
        VoiceDiagnosticLog.record("capture recovery stage=full-reset begin reason=zero-hz")
        isPerformingCaptureRecovery = true
        let resetFormat = await performFullCaptureRouteReset(
            session: session,
            generation: generation
        )
        isPerformingCaptureRecovery = false
        guard isCaptureRequestCurrent(generation) else {
            VoiceDiagnosticLog.record("capture recovery stage=full-reset result=cancelled")
            return nil
        }
        if let resetFormat {
            VoiceDiagnosticLog.record(
                "capture recovery stage=full-reset result=ready rate=\(resetFormat.sampleRate) channels=\(resetFormat.channelCount)"
            )
            return resetFormat
        }
        VoiceDiagnosticLog.record("capture recovery stage=full-reset result=unavailable")

        // Preserve a conservative mode fallback for devices whose route remains
        // unavailable after the preferred voice-chat graph was rebuilt.
        isPerformingCaptureRecovery = true
        do {
#if os(watchOS)
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
#else
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: fallbackRouteOptions
            )
#endif
            try session.setActive(true)
            logRouteDiagnostics(context: "fallback-session-activated")
            normalizePreferredInputIfNeeded(session: session)
            ensurePlaybackOutputRoute(session: session)
        } catch {
            logger.debug("Capture recovery fallback category failed error='\(error.localizedDescription, privacy: .public)'")
            VoiceDiagnosticLog.record(
                "capture recovery stage=fallback-category result=error reason=\(error.localizedDescription)"
            )
        }

        VoiceDiagnosticLog.record("capture recovery stage=fallback-category result=waiting")
        let recoveredInputNode = engine.inputNode
        let secondaryAttempt = await resolveCaptureTapFormat(
            inputNode: recoveredInputNode,
            maxAttempts: 20,
            retryDelay: .milliseconds(100),
            generation: generation
        )
        isPerformingCaptureRecovery = false
        guard isCaptureRequestCurrent(generation) else { return nil }
        if let secondaryAttempt {
            VoiceDiagnosticLog.record(
                "capture recovery stage=fallback-category result=ready rate=\(secondaryAttempt.sampleRate) channels=\(secondaryAttempt.channelCount)"
            )
            return secondaryAttempt
        }
        VoiceDiagnosticLog.record("capture recovery stage=fallback-category result=unavailable")
        return nil
    }

    @discardableResult
    private func installCaptureTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat?,
        generation: UInt64
    ) -> Bool {
        guard isCaptureRequestCurrent(generation) else { return false }
        guard let format = validatedTapFormat(for: inputNode, preferred: format) else {
            logger.error("Refused to install capture tap with invalid format")
            return false
        }
        guard isCaptureRequestCurrent(generation) else { return false }

        tapVersion &+= 1
        let installedTapVersion = tapVersion
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.captureTapBlock(
                engine: self,
                gate: captureTapGate,
                tapVersion: installedTapVersion
            )
        )

        tapInstalled = true
        isCapturing = true
        captureRecoveryFailureCount = 0
        VoiceDiagnosticLog.record(
            "capture tap installed rate=\(format.sampleRate) channels=\(format.channelCount) engineRunning=\(engine.isRunning)"
        )
        return true
    }

    private nonisolated static func captureTapBlock(
        engine: AudioEngine,
        gate: CaptureTapGate,
        tapVersion: UInt64
    ) -> AVAudioNodeTapBlock {
        { [weak engine, gate] buffer, _ in
            if buffer.frameLength > 0 && gate.markFirstBuffer() {
                let firstBufferRate = buffer.format.sampleRate
                Task { @MainActor [weak engine] in
                    guard engine?.tapInstalled == true, engine?.tapVersion == tapVersion else { return }
                    engine?.isCaptureReady = true
                    VoiceDiagnosticLog.record("input graph ready first callback rate=\(firstBufferRate)")
                }
            }
            guard let ticket = gate.admitBuffer() else { return }
            // AVAudioEngine delivers tap buffers on a real-time audio thread.
            // Copy PCM before the callback returns, then pass only Sendable
            // samples across to the main actor for encoding and UI updates.
            let samples = Self.extractSamples(from: buffer)
            let sampleRate = buffer.format.sampleRate
            Task { @MainActor [weak engine, barrier = ticket.barrier, generation = ticket.generation] in
                defer { barrier.leave() }
                if engine?.captureBufferCount == 0 {
                    VoiceDiagnosticLog.record(
                        "first tap callback frames=\(samples.count) rate=\(sampleRate)"
                    )
                }
                engine?.handleCapturedSamples(samples, sampleRate: sampleRate, generation: generation)
            }
        }
    }

    private func activateCaptureGraphAfterInstallingTap() -> Bool {
        // Starting the output graph before installing the input tap can leave
        // the input branch idle even though the engine reports running.
        let wasRunning = engine.isRunning
        do {
            if wasRunning { engine.stop() }
            try engine.start()
            playerNode.play()
            isRunning = true
            logger.info("Capture graph started with input tap installed previousEngineRunning=\(wasRunning)")
        } catch {
            logger.error("Failed to start capture graph error='\(error.localizedDescription, privacy: .public)'")
            stopCaptureTap(preservingIntent: false)
            isRunning = engine.isRunning
            return false
        }
        return true
    }

    private func handleCapturedSamples(_ samples: [Int16], sampleRate: Double, generation: UInt64) {
        let isActiveCapture = isCapturing && isCaptureRequestCurrent(generation)
        let isDrainingCapture = captureDrainGeneration == generation && captureGeneration == generation
        guard isActiveCapture || isDrainingCapture else { return }
        captureBufferCount += 1
        captureSampleCount += samples.count
        let rawRMS = computeRMS(samples)
        let rawPeak = samples.reduce(0) { max($0, abs(Int($1))) }
        capturePeakRawRMS = max(capturePeakRawRMS, rawRMS)
        capturePeakRawSample = max(capturePeakRawSample, rawPeak)
        let codecInput = prepareSamplesForCodec(samples, sourceSampleRate: sampleRate)
        let codecRMS = computeRMS(codecInput)
        let codecPeak = codecInput.reduce(0) { max($0, abs(Int($1))) }
        capturePeakCodecRMS = max(capturePeakCodecRMS, codecRMS)
        capturePeakCodecSample = max(capturePeakCodecSample, codecPeak)
        let transmittedInput: [Int16]
        let appliedGain: Double
        switch MicrophoneGainSettings.mode() {
        case .automatic:
            let gained = microphoneGain.process(codecInput)
            transmittedInput = gained.samples
            appliedGain = gained.appliedGain
        case .manual:
            let gained = MicrophoneGainSettings.process(
                codecInput,
                multiplier: MicrophoneGainSettings.load()
            )
            transmittedInput = gained.samples
            appliedGain = gained.appliedMultiplier
        }
        if !transmittedInput.isEmpty { onRecordingPCM?(transmittedInput) }
        let transmittedRMS = computeRMS(transmittedInput)
        let transmittedPeak = transmittedInput.reduce(0) { max($0, abs(Int($1))) }
        captureMaximumAppliedGain = max(captureMaximumAppliedGain, appliedGain)
        capturePeakTransmittedRMS = max(capturePeakTransmittedRMS, transmittedRMS)
        capturePeakTransmittedSample = max(capturePeakTransmittedSample, transmittedPeak)
        if captureBufferCount == 1 {
            VoiceDiagnosticLog.record("first input PCM frames=\(samples.count) rate=\(sampleRate) rms=\(rawRMS) peak=\(rawPeak) codecFrames=\(codecInput.count) codecRMS=\(codecRMS) codecPeak=\(codecPeak) txRMS=\(transmittedRMS) txPeak=\(transmittedPeak) gain=\(appliedGain)")
        }
        encodeTransmitPCM(transmittedInput)

        // The TX meter represents the samples sent after microphone gain.
        inputLevel = min(1.0, transmittedRMS / 10000.0)
        capturePeakLevel = max(capturePeakLevel, inputLevel)
    }

    /// Encodes gained, mono 8 kHz PCM from the capture graph. Speex callbacks
    /// always contain exactly one packed four-frame packet; GSM remains streaming.
    func encodeTransmitPCM(_ transmittedInput: [Int16]) {
        guard !transmittedInput.isEmpty else { return }
        onCapturedPCM?(transmittedInput)
        if transmitCodec == .speex {
            guard let packets = speexCodec.encode(transmittedInput) else { return }
            for packet in packets {
                captureEncodedByteCount += packet.count
                onCapturedAudio?(packet)
            }
            return
        }
        captureHasCodecInput = true
        captureCodecSampleRemainder = (
            captureCodecSampleRemainder + transmittedInput.count
        ) % GSMCodec.samplesPerFrame
        let encoded = codec.encode(transmittedInput)

        if !encoded.isEmpty {
            captureEncodedByteCount += encoded.count
            recordEncodedFrames(in: encoded)
            if captureEncodedByteCount == encoded.count {
                VoiceDiagnosticLog.record(
                    "first encoded audio bytes=\(encoded.count) codecSamples=\(transmittedInput.count)"
                )
            }
            onCapturedAudio?(encoded)
        }
    }

    private func resetCaptureLevelDiagnostics() {
        microphoneGain.reset()
        capturePeakRawRMS = 0
        capturePeakRawSample = 0
        capturePeakCodecRMS = 0
        capturePeakCodecSample = 0
        captureMaximumAppliedGain = 0
        capturePeakTransmittedRMS = 0
        capturePeakTransmittedSample = 0
    }

    private func recordCaptureLevelSummary() {
        VoiceDiagnosticLog.record("PTT input level buffers=\(captureBufferCount) rawMaxRMS=\(capturePeakRawRMS) rawPeak=\(capturePeakRawSample) codecMaxRMS=\(capturePeakCodecRMS) codecPeak=\(capturePeakCodecSample) txMaxRMS=\(capturePeakTransmittedRMS) txPeak=\(capturePeakTransmittedSample) maxGain=\(captureMaximumAppliedGain)")
    }

    private func normalizePreferredInputIfNeeded(session: AVAudioSession) {
#if !os(watchOS) && !targetEnvironment(macCatalyst)
        guard session.isInputAvailable else { return }
        guard outputPreference != .system else { return }
        // Keep the microphone paired with a user-selected headset or USB route.
        let externalOutputTypes: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .usbAudio, .headphones]
        if session.currentRoute.outputs.contains(where: { externalOutputTypes.contains($0.portType) }) {
            return
        }
        if session.currentRoute.inputs.contains(where: { $0.portType != .builtInMic }) {
            return
        }
        guard let availableInputs = session.availableInputs, !availableInputs.isEmpty else { return }
        guard let builtInMic = availableInputs.first(where: { $0.portType == .builtInMic }) else { return }

        let currentInputUID = session.preferredInput?.uid ?? session.currentRoute.inputs.first?.uid
        guard currentInputUID != builtInMic.uid else { return }

        do {
            try session.setPreferredInput(builtInMic)
            logger.debug("Capture recovery selected preferred input: built-in microphone")
        } catch {
            logger.debug("Setting preferred built-in microphone failed error='\(error.localizedDescription, privacy: .public)'")
        }
#endif
    }

    private func logRouteDiagnostics(context: StaticString) {
        let session = AVAudioSession.sharedInstance()
        let currentInputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let currentOutputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let availableInputs = (session.availableInputs ?? []).map { $0.portType.rawValue }.joined(separator: ",")
#if os(watchOS)
        let preferredInput = "system"
        let preferredRate = 0.0
        let inputGain = "system"
#else
        let preferredInput = session.preferredInput?.portType.rawValue ?? "none"
        let preferredRate = session.preferredSampleRate
        let inputGain = "\(session.inputGain) settable=\(session.isInputGainSettable)"
#endif
        let message = "route context=\(context) category=\(session.category.rawValue) mode=\(session.mode.rawValue) inputAvailable=\(session.isInputAvailable) sessionRate=\(session.sampleRate) preferredRate=\(preferredRate) inputChannels=\(session.inputNumberOfChannels) outputChannels=\(session.outputNumberOfChannels) outputVolume=\(session.outputVolume) inputGain=\(inputGain) inputs=[\(currentInputs)] outputs=[\(currentOutputs)] availableInputs=[\(availableInputs)] preferredInput=\(preferredInput) engineRunning=\(engine.isRunning)"
        VoiceDiagnosticLog.record(message)
        logger.warning(
            "\(message, privacy: .public)"
        )
    }

    private func performFullCaptureRouteReset(
        session: AVAudioSession,
        generation: UInt64
    ) async -> AVAudioFormat? {
        guard isCaptureRequestCurrent(generation) else { return nil }
        logger.warning("Capture recovery escalating to full audio route reset")
        do {
            stopCaptureTap(preservingIntent: true)
            if engine.isRunning {
                engine.pause()
                engine.stop()
            }
            if engine.attachedNodes.contains(playerNode) {
                engine.detach(playerNode)
            }
            isConfigured = false
            isRunning = false

            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                logger.debug("Capture recovery deactivation step failed error='\(error.localizedDescription, privacy: .public)'")
            }

#if os(watchOS)
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
#else
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: voiceChatRouteOptions
            )
#endif
#if !os(watchOS)
            do {
                try session.setPreferredSampleRate(sampleRate)
            } catch {
                logger.debug("Capture recovery preferred sample rate step failed error='\(error.localizedDescription, privacy: .public)'")
            }
            do {
                try session.setPreferredIOBufferDuration(0.02)
            } catch {
                logger.debug("Capture recovery preferred IO buffer duration step failed error='\(error.localizedDescription, privacy: .public)'")
            }
#endif
            try session.setActive(true)
            logRouteDiagnostics(context: "full-reset-session-activated")
            normalizePreferredInputIfNeeded(session: session)
            ensurePlaybackOutputRoute(session: session)

            replaceEngineAfterSessionActivation()

            try setupEngineIfNeeded()
            try engine.start()
            isRunning = true
            playerNode.play()
            logRouteDiagnostics(context: "full-reset-engine-started")

            let liveInputNode = engine.inputNode
            let recoveredFormat = await resolveCaptureTapFormat(
                inputNode: liveInputNode,
                maxAttempts: 30,
                retryDelay: .milliseconds(100),
                generation: generation
            )
            guard isCaptureRequestCurrent(generation) else { return nil }
            if let recoveredFormat {
                return recoveredFormat
            }
        } catch {
            logger.debug("Full capture route reset failed error='\(error.localizedDescription, privacy: .public)'")
        }

        logRouteDiagnostics(context: "capture-recovery-exhausted")
        return nil
    }

    private func prepareSamplesForCodec(_ samples: [Int16], sourceSampleRate: Double) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        guard sourceSampleRate.isFinite, sourceSampleRate > 0 else { return samples }

        return PCMLinearResampler.resample(
            samples,
            sourceSampleRate: sourceSampleRate,
            targetSampleRate: Double(GSMCodec.sampleRate),
            state: &captureResamplerState
        )
    }

    private func recordEncodedFrames(in encoded: Data) {
        guard let payload = GSMCodec.stripHeader(encoded),
              !payload.isEmpty,
              payload.count.isMultiple(of: GSMCodec.encodedFrameSize) else { return }
        let frameCount = payload.count / GSMCodec.encodedFrameSize
        captureEncodedFrameRemainder = (
            captureEncodedFrameRemainder + frameCount
        ) % 4
    }

    private func flushCaptureEncoderToPacketBoundary() -> Data {
        if transmitCodec == .speex { return speexCodec.flushEncoding() ?? Data() }
        guard captureHasCodecInput else { return Data() }

        var finalPayload = Data()
        let flushPlan = AudioCaptureFlushPlan.make(
            hasCodecInput: captureHasCodecInput,
            sampleRemainder: captureCodecSampleRemainder,
            encodedFrameRemainder: captureEncodedFrameRemainder
        )

        func appendEncodedPayload(_ encoded: Data) {
            guard let payload = GSMCodec.stripHeader(encoded), !payload.isEmpty else { return }
            finalPayload.append(payload)
            recordEncodedFrames(in: encoded)
        }

        if flushPlan.partialFrameSamplePadding > 0 {
            appendEncodedPayload(codec.encode(
                [Int16](repeating: 0, count: flushPlan.partialFrameSamplePadding)
            ))
            captureCodecSampleRemainder = 0
        }

        if flushPlan.silentFramePadding > 0 {
            appendEncodedPayload(codec.encode(
                [Int16](
                    repeating: 0,
                    count: flushPlan.silentFramePadding * GSMCodec.samplesPerFrame
                )
            ))
        }

        guard !finalPayload.isEmpty else { return Data() }
        return GSMCodec.wrapWithHeader(finalPayload)
    }

    private func resetCaptureEncodingCounters() {
        speexCodec.resetEncoding()
        captureCodecSampleRemainder = 0
        captureEncodedFrameRemainder = 0
        captureHasCodecInput = false
    }

    private func isCaptureRequestCurrent(_ generation: UInt64) -> Bool {
        captureRequested && captureGeneration == generation && !Task.isCancelled
    }

    private func validatedTapFormat(for inputNode: AVAudioInputNode, preferred: AVAudioFormat?) -> AVAudioFormat? {
        let liveOutput = inputNode.outputFormat(forBus: 0)
        if isUsableHardwareFormat(liveOutput) {
            if let preferred,
               isUsableHardwareFormat(preferred),
               (preferred.sampleRate != liveOutput.sampleRate || preferred.channelCount != liveOutput.channelCount) {
                logger.debug(
                    "Using live input-node output format instead of stale preferred tap format preferred(ch=\(preferred.channelCount),rate=\(preferred.sampleRate)) live(ch=\(liveOutput.channelCount),rate=\(liveOutput.sampleRate))"
                )
            }
            return liveOutput
        }

        let liveInput = inputNode.inputFormat(forBus: 0)
        if isUsableHardwareFormat(liveInput) {
            logger.debug(
                "Live input-side bus format is available but cannot be used for capture tap installation output(ch=\(liveOutput.channelCount),rate=\(liveOutput.sampleRate)) input(ch=\(liveInput.channelCount),rate=\(liveInput.sampleRate))"
            )
        }
        if let preferred, isUsableHardwareFormat(preferred) {
            logger.debug(
                "Discarding preferred capture tap format because the live input-node output bus format is unavailable preferred(ch=\(preferred.channelCount),rate=\(preferred.sampleRate)) output(ch=\(liveOutput.channelCount),rate=\(liveOutput.sampleRate))"
            )
        }
        return nil
    }

    private func stopCaptureTap(preservingIntent: Bool, resetResampler: Bool = true) {
        _ = captureTapGate.deactivate()
        if !preservingIntent {
            captureRequested = false
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        tapVersion &+= 1
        captureTapGate.resetFirstBuffer()
        isCaptureReady = false
        isCapturing = false
        inputLevel = 0
        if resetResampler {
            captureResamplerState.reset()
        }
    }

    private func invalidateCaptureStart(preservingIntent: Bool) {
        captureGeneration &+= 1
        captureDrainGeneration = nil
        captureRecoveryTask?.cancel()
        captureRecoveryTask = nil
        stopCaptureTap(preservingIntent: preservingIntent)
    }

    @discardableResult
    private func scheduleCaptureRecovery(reason: StaticString, delay: Duration = .milliseconds(250)) -> Bool {
        guard captureRequested else { return false }
        guard captureRecoveryTask == nil else { return false }

        let generation = captureGeneration
        captureRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.isCaptureRequestCurrent(generation) else { return }
            await self.runCaptureRecovery(reason: reason, generation: generation)
        }
        return true
    }

    private func scheduleCaptureRecoveryAfterFailure(reason: StaticString) {
        // Exponential backoff to prevent retry storms when route remains unavailable.
        let exponent = min(captureRecoveryFailureCount, 5) // caps around ~8s
        let rawDelayMs = 250 * (1 << exponent)
        let delayMs = min(rawDelayMs, 8_000)
        if scheduleCaptureRecovery(reason: reason, delay: .milliseconds(delayMs)) {
            captureRecoveryFailureCount = min(captureRecoveryFailureCount + 1, 16)
        }
    }

    private func runCaptureRecovery(reason: StaticString, generation: UInt64) async {
        guard isCaptureRequestCurrent(generation) else { return }
        captureRecoveryTask = nil
        guard captureRequested, !isCapturing else { return }
        logger.debug("Retrying capture start reason='\(reason, privacy: .public)'")
        _ = await startCapture()
    }

    private func scheduleInputPreparation() {
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        guard prepareCaptureTask == nil else { return }
        prepareCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.prepareCaptureInput()
            self.prepareCaptureTask = nil
        }
#endif
    }

    private func installAudioSessionObserversIfNeeded() {
        guard !hasInstalledSessionObservers else { return }
        let center = NotificationCenter.default

        let routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reasonValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self, reasonValue] in
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        }

        let interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
            let optionsValue = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self, typeValue, optionsValue] in
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }

        let mediaResetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        }

        let engineConfigObserver = center.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEngineConfigurationChange()
            }
        }

        sessionObservers = [
            SessionObserverToken(rawValue: routeObserver),
            SessionObserverToken(rawValue: interruptionObserver),
            SessionObserverToken(rawValue: mediaResetObserver),
            SessionObserverToken(rawValue: engineConfigObserver),
        ]
        hasInstalledSessionObservers = true
    }

    private func handleRouteChange(reasonValue: UInt) {
        guard captureRequested || isRunning else { return }
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)

        if isPreparingCapture {
            updateOutputRouteName()
            return
        }

        if isPerformingCaptureRecovery {
            updateOutputRouteName()
            VoiceDiagnosticLog.record(
                "route change ignored during capture recovery reason=\(reasonValue)"
            )
            return
        }

        if reason == .categoryChange {
            updateOutputRouteName()
            if captureRequested && !hasUsableCaptureRoute() {
                logger.warning("Audio route changed reason=categoryChange; capture route invalid, scheduling recovery")
                logRouteDiagnostics(context: "category-change-invalid-route")
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
                invalidateCaptureStart(preservingIntent: false)
                scheduleInputPreparation()
#else
                invalidateCaptureStart(preservingIntent: true)
                scheduleCaptureRecoveryAfterFailure(reason: "category-change-invalid-route")
#endif
            } else if tapInstalled && !hasUsableCaptureRoute() {
                stopCaptureTap(preservingIntent: false)
                scheduleInputPreparation()
            } else {
                logger.debug("Audio route changed reason=categoryChange; route remains usable")
            }
            return
        }

        logger.info("Audio route changed reason=\(reasonValue)")
        ensurePlaybackOutputRoute()
        updateOutputRouteName()

        let shouldTriggerRecovery: Bool
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange, .noSuitableRouteForCategory, .wakeFromSleep:
            shouldTriggerRecovery = true
        case .override:
            shouldTriggerRecovery = false
        case .categoryChange:
            shouldTriggerRecovery = false
        case .unknown:
            shouldTriggerRecovery = true
        case .none:
            shouldTriggerRecovery = true
        @unknown default:
            shouldTriggerRecovery = true
        }

        if captureRequested && shouldTriggerRecovery {
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            invalidateCaptureStart(preservingIntent: false)
            scheduleInputPreparation()
#else
            invalidateCaptureStart(preservingIntent: true)
            scheduleCaptureRecoveryAfterFailure(reason: "route-change")
#endif
        } else if tapInstalled && shouldTriggerRecovery {
            stopCaptureTap(preservingIntent: false)
            scheduleInputPreparation()
        }
    }

    private func hasUsableCaptureRoute() -> Bool {
        let inputNode = engine.inputNode
        let outputFormat = inputNode.outputFormat(forBus: 0)
        return isUsableHardwareFormat(outputFormat)
    }

    private func handleInterruption(typeValue: UInt, optionsValue: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            resumeCaptureAfterInterruption = captureRequested
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            invalidateCaptureStart(preservingIntent: false)
#else
            invalidateCaptureStart(preservingIntent: true)
#endif
            if engine.isRunning {
                engine.pause()
            }
            isRunning = false

        case .ended:
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                logger.error("Audio session reactivation after interruption failed error='\(error.localizedDescription, privacy: .public)'")
            }

            startPlayback()
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            scheduleInputPreparation()
#else
            if !resumeCaptureAfterInterruption { scheduleInputPreparation() }
#endif

            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if resumeCaptureAfterInterruption && options.contains(.shouldResume) {
                scheduleCaptureRecovery(reason: "interruption-ended")
            }
            resumeCaptureAfterInterruption = false

        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        logger.warning("Audio media services reset detected; rebuilding audio engine state")

        let shouldRestartPlayback = isRunning || captureRequested
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        invalidateCaptureStart(preservingIntent: false)
#else
        invalidateCaptureStart(preservingIntent: true)
#endif
        resetEngineGraph()
        isRunning = false

        guard shouldRestartPlayback else { return }
        startPlayback()
        if !captureRequested { scheduleInputPreparation() }
        if captureRequested {
            scheduleCaptureRecovery(reason: "media-services-reset", delay: .milliseconds(100))
        }
    }

    private func handleEngineConfigurationChange() {
        logger.warning("Audio engine configuration changed; validating capture chain")
        VoiceDiagnosticLog.record(
            "engine configuration changed captureRequested=\(captureRequested) capturing=\(isCapturing) engineRunning=\(engine.isRunning)"
        )

        if isPerformingCaptureRecovery || isPreparingCapture {
            VoiceDiagnosticLog.record("engine configuration change ignored during capture recovery")
            return
        }

        if isRunning, !engine.isRunning {
            do {
                try engine.start()
                if engine.isRunning {
                    playerNode.play()
                }
            } catch {
                logger.error("Engine restart after configuration change failed error='\(error.localizedDescription, privacy: .public)'")
            }
            isRunning = engine.isRunning
        }

        if captureRequested {
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            invalidateCaptureStart(preservingIntent: false)
            scheduleInputPreparation()
#else
            invalidateCaptureStart(preservingIntent: true)
            scheduleCaptureRecovery(reason: "engine-config-change")
#endif
        } else if tapInstalled {
            stopCaptureTap(preservingIntent: false)
            scheduleInputPreparation()
        }
    }

    private func isUsableHardwareFormat(_ format: AVAudioFormat?) -> Bool {
        guard let format else { return false }
        let rate = format.sampleRate
        let channels = format.channelCount
        guard rate.isFinite, rate >= 1_000, rate <= 384_000 else { return false }
        guard channels > 0, channels <= 8 else { return false }
        return true
    }

    private func resetEngineGraph() {
        stopCaptureTap(preservingIntent: true)
        playerNode.stop()
        engine.stop()

        if engine.attachedNodes.contains(playerNode) {
            engine.detach(playerNode)
        }

        isConfigured = false
        isCapturing = false
    }

    private func ensurePlaybackOutputRoute(session: AVAudioSession = AVAudioSession.sharedInstance()) {
#if os(watchOS) || targetEnvironment(simulator)
        return
#else
        guard session.category == .playAndRecord else { return }
#if !targetEnvironment(macCatalyst)
        guard outputPreference == .speaker else { return }
#endif

        let outputs = session.currentRoute.outputs
        let hasBluetoothOutput = outputs.contains {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
        }
        if hasBluetoothOutput {
            return
        }

        let hasBuiltInSpeaker = outputs.contains { $0.portType == .builtInSpeaker }
        if hasBuiltInSpeaker {
            return
        }

        let hasReceiverOnlyRoute = outputs.contains { $0.portType == .builtInReceiver }
        guard hasReceiverOnlyRoute else { return }

        do {
            try session.overrideOutputAudioPort(.speaker)
            logger.debug("Forced playback route to built-in speaker")
        } catch {
            logger.debug("Failed to force speaker route error='\(error.localizedDescription, privacy: .public)'")
        }
#endif
    }
}
