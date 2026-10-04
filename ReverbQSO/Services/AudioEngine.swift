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

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let portType: String
}

enum AudioRoutePreferences {
    static let didChange = Notification.Name("ReverbQSO.audioRoutePreferencesChanged")
    static let outputKey = "audio.outputPreference"
    static let inputKey = "audio.inputDeviceUID"

    static func output(defaultValue: AudioOutputPreference,
                       defaults: UserDefaults = .standard) -> AudioOutputPreference {
        AudioOutputPreference(rawValue: defaults.string(forKey: outputKey) ?? "") ?? defaultValue
    }

    static func inputUID(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: inputKey)
    }

    static func save(output: AudioOutputPreference, defaults: UserDefaults = .standard) {
        defaults.set(output.rawValue, forKey: outputKey)
        if defaults === UserDefaults.standard { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    static func save(inputUID: String?, defaults: UserDefaults = .standard) {
        if let inputUID { defaults.set(inputUID, forKey: inputKey) }
        else { defaults.removeObject(forKey: inputKey) }
        if defaults === UserDefaults.standard { NotificationCenter.default.post(name: didChange, object: nil) }
    }
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
        let voiceGain = min(maximumGain, max(1, targetRMS / rms))
        let transition = min(1, (rms - noiseFloorRMS) / noiseFloorRMS)
        let voiceWeight = transition * transition * (3 - 2 * transition)
        let requestedGain = 1 + (voiceGain - 1) * voiceWeight
        let recovery = 1 - exp(-Double(samples.count) / 8_000 / 0.03)
        let smoothedGain = previousGain.map { prior in
            requestedGain < prior ? requestedGain : prior + (requestedGain - prior) * recovery
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

/// The tap stays installed for the QSO. Only callbacks admitted while PTT is
/// down may enter the encoder; sealing the gate makes release deterministic.
private final class CaptureTapGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: (CaptureBufferProcessingBarrier, UInt64, CaptureDSPProcessor.Configuration)?
    private var firstBufferSeen = false

    func activate(_ barrier: CaptureBufferProcessingBarrier, generation: UInt64,
                  configuration: CaptureDSPProcessor.Configuration = .init(codec: .gsm, gainMode: .automatic, manualGainMultiplier: 1)) {
        lock.lock()
        active = (barrier, generation, configuration)
        lock.unlock()
    }

    func deactivate() -> CaptureBufferProcessingBarrier? {
        lock.lock()
        let barrier = active?.0
        active = nil
        lock.unlock()
        return barrier
    }

    func admitBuffer() -> (barrier: CaptureBufferProcessingBarrier, generation: UInt64, configuration: CaptureDSPProcessor.Configuration)? {
        lock.lock()
        defer { lock.unlock() }
        guard let (barrier, generation, configuration) = active, barrier.enter() else { return nil }
        return (barrier, generation, configuration)
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
    @Published private(set) var availableInputDevices: [AudioInputDevice] = []
    @Published private(set) var selectedInputDeviceID: String? = AudioRoutePreferences.inputUID()
#if os(iOS) && !targetEnvironment(macCatalyst)
    @Published private(set) var outputPreference: AudioOutputPreference =
        AudioRoutePreferences.output(defaultValue: .system)
#elseif targetEnvironment(macCatalyst)
    @Published private(set) var outputPreference: AudioOutputPreference =
        AudioRoutePreferences.output(defaultValue: .system)
#else
    @Published private(set) var outputPreference: AudioOutputPreference =
        AudioRoutePreferences.output(defaultValue: .speaker)
#endif

    // MARK: - Audio Components

    private var engine = AVAudioEngine()
    private let codec = GSMCodec()
    private let speexCodec = SpeexCodec()
    private let speexReceiveDecoder = SpeexReceiveStreamDecoder()
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
    private var receiveOutputMuted = false

    func setReceiveOutputMuted(_ muted: Bool) {
        receiveOutputMuted = muted
        playerNode.volume = muted ? 0 : 1
    }
    private var playerNode = AVAudioPlayerNode()
#if DEBUG
    private var auditScheduledSamples = 0
    private var auditTrimCount = 0
    private var auditTrimmedSamples = 0
    private var auditConcealmentSkippedSamples = 0
    private var auditScheduleEvents: [[String: Double]] = []

    var auditPlaybackSnapshot: [String: Int] {
        ["scheduledSamples": auditScheduledSamples, "backlogTrims": auditTrimCount,
         "trimmedSamples": auditTrimmedSamples, "playoutDiscardedPackets": receivePlayout.discardedPackets,
         "concealmentSkippedSamples": auditConcealmentSkippedSamples,
         "remainingSamples": remainingPlaybackSamples, "running": isRunning ? 1 : 0]
    }

    var auditPlaybackSchedule: [[String: Double]] { auditScheduleEvents }

    func beginAuditRenderCapture(url: URL) throws -> AudioAuditRenderCapture {
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1", engine.isRunning else {
            throw CocoaError(.featureUnsupported)
        }
        auditScheduledSamples = 0
        auditTrimCount = 0
        auditTrimmedSamples = 0
        auditConcealmentSkippedSamples = 0
        auditScheduleEvents.removeAll()
        let mixer = engine.mainMixerNode
        let capture = try AudioAuditRenderCapture(url: url, format: mixer.outputFormat(forBus: 0))
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil, block: capture.makeTap())
        return capture
    }

    func endAuditRenderCapture(_ capture: AudioAuditRenderCapture) async -> [String: Double] {
        engine.mainMixerNode.removeTap(onBus: 0)
        return await capture.finish()
    }
#endif
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
    private nonisolated let captureDSP = CaptureDSPProcessor()
    private var nativeCaptureGeneration: UInt64?
    private var captureDSPNextOrdinal: UInt64 = 0
    private var captureDSPResults: [UInt64: (CaptureDSPProcessor.Result, Int, Bool)] = [:]
    private var prepareCaptureTask: Task<Void, Never>?
    private var inputPreparationGeneration: UInt64 = 0
    private var playbackDesired = false
    private var isAudioInterrupted = false
    private var automaticPlaybackAllowed = true
    private var isDeviceRecovering = false
    private var audioDeviceRecoveryTask: Task<Void, Never>?
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
    private var routePreferenceSubscription: AnyCancellable?

    init() {
        routePreferenceSubscription = NotificationCenter.default.publisher(for: AudioRoutePreferences.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadRoutePreferences() }
    }

    private func reloadRoutePreferences() {
        selectedInputDeviceID = AudioRoutePreferences.inputUID()
#if os(watchOS)
        outputPreference = AudioRoutePreferences.output(defaultValue: .speaker)
#else
        outputPreference = AudioRoutePreferences.output(defaultValue: .system)
#endif
    }

    private func replaceEngineAfterSessionActivation() {
        // An input node created while its hardware route was disabled can keep
        // reporting 0 Hz even after the session becomes valid. A new engine
        // creates a new input node against the now-active route.
        stopPlaybackTimeline()
        engine.stop()
        if engine.attachedNodes.contains(playerNode) {
            engine.detach(playerNode)
        }
        for token in sessionObservers {
            NotificationCenter.default.removeObserver(token.rawValue)
        }
        sessionObservers.removeAll()
        hasInstalledSessionObservers = false
        playerNode = AVAudioPlayerNode()
        playerNode.volume = receiveOutputMuted ? 0 : 1
        engine = AVAudioEngine()
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // Software gain handles automatic/manual levels. Keep voice I/O
            // echo cancellation, but do not run two competing gain controls.
            engine.inputNode.isVoiceProcessingAGCEnabled = false
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
    var onCaptureSuspended: (@MainActor () -> Void)?

    // MARK: - Configuration

    private let sampleRate: Double = 8000
    private let channelCount: AVAudioChannelCount = 1
    private var playbackGain = ReceivePlaybackGain()
    private var playbackQueue = ReceivePlaybackQueue()
    private var playbackHistory = ReceivePlaybackHistory()
    private let receiveClock = ReceiveClockCompensator()
    private let receiveSpeech = ReceiveSpeechSmoother()
    private var receivePlayout = ReceiveAdaptivePlayoutBuffer()
    private var receivePlayoutTask: Task<Void, Never>?
    private var receivePlayoutGeneration: UInt64 = 0
    private var playbackEndSampleTime: Int64 = 0
    private var lastReceiveArrival = -Double.infinity

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
        audioDeviceRecoveryTask?.cancel()
        for token in sessionObservers {
            NotificationCenter.default.removeObserver(token.rawValue)
        }
    }

    /// Start playback/capture engine so received audio can be rendered even when not transmitting.
    func startPlayback(rebuildGraph: Bool = false) {
        playbackDesired = true
        automaticPlaybackAllowed = true
        guard !isAudioInterrupted, !isRunning else { return }

        RecordingAudioSession.shared.beginLiveAudio(owner: self)
        do {
            installAudioSessionObserversIfNeeded()
            try configureAudioSession()
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            // Build the input node only after the session owns a hardware mic
            // route. Reusing the preactivation engine leaves it at 0 Hz on
            // physical iPhone even though AVAudioSession reports 48 kHz input.
            replaceEngineAfterSessionActivation()
#else
            if rebuildGraph { replaceEngineAfterSessionActivation() }
#endif
            try setupEngineIfNeeded()
            playerNode.volume = receiveOutputMuted ? 0 : 1
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
            RecordingAudioSession.shared.endLiveAudio(owner: self)
        }
    }

    /// Prepare the microphone while the station is connected, before a PTT
    /// gesture. Automatic preparation never presents a permission prompt.
    /// RX remains available if permission or the input route fails.
    func prepareCaptureInput(requestPermission: Bool = true) async -> Bool {
#if targetEnvironment(simulator)
        return false
#else
        guard !isCaptureReady else { return true }
        guard requestPermission || MicrophoneAccess.status == .granted else { return false }
        guard !isPreparingCapture else { return false }
        let preparationGeneration = inputPreparationGeneration
        isPreparingCapture = true
        capturePreparationFailed = false
        defer {
            if inputPreparationGeneration == preparationGeneration { isPreparingCapture = false }
        }

        for attempt in 0..<3 {
            guard !Task.isCancelled, inputPreparationGeneration == preparationGeneration else { return false }
            if tapInstalled { stopCaptureTap(preservingIntent: false) }
            let installed = await startCapture(requestPermission: requestPermission)
            guard !Task.isCancelled, inputPreparationGeneration == preparationGeneration else { return false }
            captureRequested = false
            if installed {
                for _ in 0..<20 {
                    guard !Task.isCancelled, inputPreparationGeneration == preparationGeneration else { return false }
                    if isCaptureReady { return true }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            guard !Task.isCancelled, inputPreparationGeneration == preparationGeneration else { return false }
            VoiceDiagnosticLog.record("capture preparation attempt=\(attempt + 1) inputCallback=\(isCaptureReady)")
            stopCaptureTap(preservingIntent: false)
            guard !Task.isCancelled, inputPreparationGeneration == preparationGeneration else { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard !Task.isCancelled, inputPreparationGeneration == preparationGeneration else { return false }
        capturePreparationFailed = true
        return false
#endif
    }

    /// Start capturing audio from the microphone (PTT pressed).
    func startCapture(requestPermission: Bool = true) async -> Bool {
        guard !isAudioInterrupted, !isDeviceRecovering else { return false }
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
            activateCaptureDelivery(generation: captureGeneration)
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
        let hasPermission = await ensureRecordPermission(requestPermission: requestPermission)
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
            if !isPreparingCapture { activateCaptureDelivery(generation: generation) }
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
            if !isPreparingCapture { activateCaptureDelivery(generation: generation) }
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
        VoiceDiagnosticLog.record("capture admission rejected=\(barrier.snapshot.rejectedBuffers)")
        guard captureGeneration == generation,
              captureDrainGeneration == generation else { return Data() }

        let finalAudio = nativeCaptureGeneration == generation
            ? await captureDSP.flush(generation: generation) : flushCaptureEncoderToPacketBoundary()
        guard captureGeneration == generation, captureDrainGeneration == generation else { return Data() }
        captureDSP.end(generation: generation)
        nativeCaptureGeneration = nil
        captureDSPResults.removeAll(keepingCapacity: true)
        captureGeneration &+= 1
        captureDrainGeneration = nil
        captureRecoveryFailureCount = 0
        recordCaptureLevelSummary()
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
            stopPlaybackTimeline()
            playerNode.play()
            ensurePlaybackOutputRoute()
            logger.info("Playback resumed after PTT engineRunning=\(self.engine.isRunning) playerPlaying=\(self.playerNode.isPlaying)")
        }
#endif
        return finalAudio
    }

    /// Fully stop audio playback + capture for session teardown.
    func stopAll() {
        playbackDesired = false
        isAudioInterrupted = false
        automaticPlaybackAllowed = true
        audioDeviceRecoveryTask?.cancel()
        audioDeviceRecoveryTask = nil
        isDeviceRecovering = false
        rxWindowActive = false
        inputPreparationGeneration &+= 1
        prepareCaptureTask?.cancel()
        prepareCaptureTask = nil
        isPreparingCapture = false
        isCaptureReady = false
        capturePreparationFailed = false
        invalidateCaptureStart(preservingIntent: false)
        captureRecoveryFailureCount = 0
        stopPlaybackTimeline()
        engine.stop()
        if engine.attachedNodes.contains(playerNode) {
            engine.detach(playerNode)
        }
        for token in sessionObservers {
            NotificationCenter.default.removeObserver(token.rawValue)
        }
        sessionObservers.removeAll()
        hasInstalledSessionObservers = false
        // Discard the stopped I/O graph without touching a fresh input node.
        // The next connection builds its hardware graph after activation.
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        playerNode.volume = receiveOutputMuted ? 0 : 1
        isConfigured = false
        isRunning = false
        // Deactivate only after taps and I/O are stopped. The shared owner
        // coordinator leaves the session active for another live radio.
        RecordingAudioSession.shared.endLiveAudio(owner: self)
        outputLevelDecayTask?.cancel()
        outputLevelDecayTask = nil
        outputLevel = 0
        inputLevel = 0
        // Reset all codec state for a clean session.
        codec.resetAll()
        speexCodec.reset()
        speexReceiveDecoder.reset()
        playbackGain.reset()
        resetReceiveProcessing()
        resetCaptureEncodingCounters()
    }

    /// Reset codec state without stopping the engine.
    ///
    /// Call at the start of a new QSO session to ensure no stale
    /// encoder/decoder state leaks across connections.
    func resetCodecState() {
        codec.resetAll()
        speexCodec.reset()
        speexReceiveDecoder.reset()
        playbackGain.reset()
        resetReceiveProcessing()
        resetCaptureEncodingCounters()
    }

    /// Play received encoded audio data through the speaker.
    ///
    /// Each call corresponds to a self-contained network packet, so we use
    /// `decodePacket()` which discards any stale partial-frame bytes from
    /// prior packets. This prevents audio corruption after packet loss.
    func playReceivedAudio(_ data: Data, metadata: EchoLinkVoicePacketMetadata? = nil,
                           diagnoseFirstRXAfterPTT: Bool = false) {
        let pcmSamples = codec.decodePacket(data)
        playReceivedPCM(pcmSamples, metadata: metadata,
                        diagnoseFirstRXAfterPTT: diagnoseFirstRXAfterPTT)
    }

    /// Decode an EchoLink Speex datagram before receive activity/mute decisions.
    func decodeReceivedSpeex(_ payload: Data, metadata: EchoLinkVoicePacketMetadata?) -> SpeexReceiveStreamDecoder.Audio? {
        speexReceiveDecoder.decode(payload, metadata: metadata)
    }

    /// Records real network samples; smoothing and concealment affect playback only.
    func playReceivedPCM(_ samples: [Int16], metadata: EchoLinkVoicePacketMetadata? = nil, nativeConcealment: [Int16]? = nil,
                         diagnoseFirstRXAfterPTT: Bool = false) {
        guard !samples.isEmpty else { return }
        onRecordingPCM?(samples)
        guard !isAudioInterrupted, automaticPlaybackAllowed, !isDeviceRecovering else { return }
        if !isRunning { startPlayback() }
        guard isRunning else { return }
        accumulateRXWindow(samples: samples)
        recordOutputLevel(from: samples)
        if diagnoseFirstRXAfterPTT { recordFirstRXDiagnostics(samples: samples, codec: "PCM") }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReceiveArrival >= 0.5 { receiveClock.reset() }
        lastReceiveArrival = now
        let playbackSamples: [Int16]
        if let nativeConcealment {
            receiveSpeech.reset()
            let retained = playbackQueue.retainedConcealment(nativeConcealment,
                receivedSamples: samples.count, remainingSamples: remainingPlaybackSamples)
#if DEBUG
            auditConcealmentSkippedSamples += nativeConcealment.count - retained.count
#endif
            playbackSamples = Array(retained) + samples
        } else { playbackSamples = receiveSpeech.process(samples, metadata: metadata, now: now) }
        receivePlayout.enqueue(playbackSamples, networkSampleCount: samples.count, playbackQueuedSamples: remainingPlaybackSamples, now: now)
        scheduleReceivePlayout()
    }

    private func scheduleReceivePlayout() {
        guard receivePlayoutTask == nil, let deadline = receivePlayout.nextDeadline else { return }
        let generation = receivePlayoutGeneration
        receivePlayoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
            catch { return }
            guard let self, !Task.isCancelled, self.receivePlayoutGeneration == generation else { return }
            self.receivePlayoutTask = nil
            for samples in self.receivePlayout.drain() {
                guard self.isRunning, let format = self.captureFormat else { continue }
                let corrected = self.receiveClock.process(samples, queuedSamples: self.remainingPlaybackSamples,
                    targetQueuedSamples: Int(self.receivePlayout.targetDelay * 8000))
                guard let buffer = self.pcmBuffer(from: corrected, format: format) else { continue }
                self.schedulePlaybackBuffer(buffer)
                if !self.playerNode.isPlaying { self.playerNode.play() }
            }
            self.scheduleReceivePlayout()
        }
    }

    private func resetReceiveProcessing() {
        receivePlayoutGeneration &+= 1
        receivePlayoutTask?.cancel()
        receivePlayoutTask = nil
        receivePlayout.reset()
        receiveSpeech.reset()
        receiveClock.reset()
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
        reloadRoutePreferences()
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
            try session.setPreferredIOBufferDuration(0.02)
        } catch {
            logger.debug("Preferred IO buffer duration not applied error='\(error.localizedDescription, privacy: .public)'")
        }
#endif
#endif
        try session.setActive(true)
#if !os(watchOS) && !targetEnvironment(simulator)
        if session.maximumInputNumberOfChannels > 0 {
            try? session.setPreferredInputNumberOfChannels(1)
        }
#endif
        logRouteDiagnostics(context: "session-activated")
        refreshAvailableInputDevices(session: session)
        ensurePlaybackOutputRoute(session: session)
        if !isDeviceRecovering { applyPreferredInput(session: session) }
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
        AudioRoutePreferences.save(output: preference)
#if !os(watchOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord else { return }
        do {
            switch preference {
            case .speaker, .receiver:
                try session.overrideOutputAudioPort(preference == .speaker ? .speaker : .none)
            case .system:
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

    func setInputDevice(id: String?) {
        selectedInputDeviceID = id
        AudioRoutePreferences.save(inputUID: id)
#if os(iOS) && !os(watchOS) && !targetEnvironment(simulator)
        let session = AVAudioSession.sharedInstance()
        refreshAvailableInputDevices(session: session)
        applyPreferredInput(session: session)
        updateOutputRouteName(session: session)
#endif
    }

    private func refreshAvailableInputDevices(session: AVAudioSession = .sharedInstance()) {
#if os(iOS) && !os(watchOS) && !targetEnvironment(simulator)
        availableInputDevices = (session.availableInputs ?? []).map {
            AudioInputDevice(id: $0.uid, name: $0.portName, portType: $0.portType.rawValue)
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
#else
        availableInputDevices = []
#endif
    }

    private func applyPreferredInput(session: AVAudioSession) {
#if os(iOS) && !os(watchOS) && !targetEnvironment(simulator)
        do {
            guard let selectedInputDeviceID else {
                guard session.preferredInput != nil else { return }
                try session.setPreferredInput(nil)
                return
            }
            // Keep the saved choice if it is temporarily disconnected. A later
            // available-inputs notification restores it when the device returns.
            guard let input = session.availableInputs?.first(where: { $0.uid == selectedInputDeviceID }) else {
                return
            }
            guard session.preferredInput?.uid != input.uid else { return }
            try session.setPreferredInput(input)
        } catch {
            logger.error("Could not select audio input: \(error.localizedDescription, privacy: .public)")
        }
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

    private func pcmBuffer(from samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let floatData = buffer.floatChannelData else {
            logger.error("Playback buffer missing float channel data")
            return nil
        }

        let amplified = playbackGain.process(samples)
        let channels = Int(format.channelCount)
        for i in 0..<samples.count {
            for channel in 0..<channels {
                floatData[channel][i] = amplified[i]
            }
        }

        return buffer
    }

    private func schedulePlaybackBuffer(_ buffer: AVAudioPCMBuffer) {
        let incomingCount = Int(buffer.frameLength)
        guard let incomingData = buffer.floatChannelData else { return }
        let incomingSamples = Array(UnsafeBufferPointer(start: incomingData[0], count: incomingCount))
        let renderedSnapshot = renderedPlaybackSampleTime
        if let rendered = renderedSnapshot { playbackHistory.prune(renderedSampleTime: rendered) }
        let remaining = playbackHistory.remainingSamples(renderedSampleTime: renderedSnapshot)
        var start = max(playbackEndSampleTime, max(0, renderedSnapshot ?? 0))
        var scheduledBuffer = buffer
        var scheduledSamples = incomingSamples
#if DEBUG
        let auditEventIndex = auditScheduleEvents.count
        if ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" {
            auditScheduledSamples += incomingCount
            auditScheduleEvents.append(["time": ProcessInfo.processInfo.systemUptime,
                "rendered": Double(renderedSnapshot ?? -1),
                "priorEnd": Double(playbackEndSampleTime), "count": Double(incomingCount)])
        }
#endif
        if playbackQueue.needsReset(adding: incomingCount, remainingSamples: remaining) {
            let replacement = playbackHistory.boundedReplacement(adding: incomingSamples, maximumSamples: playbackQueue.recoverySamples)
            guard let combined = playbackBuffer(fromProcessedSamples: replacement.samples, format: buffer.format) else { return }
#if DEBUG
            auditTrimCount += 1
            auditTrimmedSamples += replacement.discardedSamples
            if auditScheduleEvents.count > auditEventIndex {
                auditScheduleEvents[auditEventIndex]["discardedSamples"] = Double(replacement.discardedSamples)
                auditScheduleEvents[auditEventIndex]["retainedSamples"] = Double(max(0, replacement.samples.count - incomingCount))
            }
#endif
            // Preserve recent unrendered speech, discarding only the excess.
            trimPlaybackTimeline()
            // stop() resets the player timeline; lastRenderTime can still
            // expose the previous generation's cursor until rendering resumes.
            start = 0
            scheduledBuffer = combined
            scheduledSamples = replacement.samples
            logger.debug("Trimmed receive playback backlog to bounded recent speech")
        }
        let count = scheduledSamples.count
        playbackEndSampleTime = start + Int64(count)
        playbackHistory.append(scheduledSamples, startingAt: start)
#if DEBUG
        if auditScheduleEvents.count > auditEventIndex {
            auditScheduleEvents[auditEventIndex]["scheduledCount"] = Double(count)
            auditScheduleEvents[auditEventIndex]["scheduledStart"] = Double(start)
            auditScheduleEvents[auditEventIndex]["generation"] = Double(playbackQueue.generation)
        }
#endif
        let end = playbackEndSampleTime
        let token = playbackQueue.reserve(count)
        playerNode.scheduleBuffer(scheduledBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackQueue.generation == token else { return }
                self.playbackQueue.complete(count, generation: token)
                self.playbackHistory.prune(renderedSampleTime: end)
            }
        }
    }

    private func playbackBuffer(fromProcessedSamples samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(format.channelCount) {
            for index in samples.indices { channels[channel][index] = samples[index] }
        }
        return buffer
    }

    private var renderedPlaybackSampleTime: Int64? {
        guard let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else { return nil }
        return playerTime.sampleTime
    }

    private var remainingPlaybackSamples: Int {
        playbackHistory.remainingSamples(renderedSampleTime: renderedPlaybackSampleTime)
    }

    private func trimPlaybackTimeline() {
        playbackQueue.reset()
        playbackHistory.reset()
        playbackEndSampleTime = 0
        receiveClock.reset()
        playerNode.stop()
    }

    private func stopPlaybackTimeline() {
        resetReceiveProcessing()
        lastReceiveArrival = -Double.infinity
        trimPlaybackTimeline()
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

    private func ensureRecordPermission(requestPermission: Bool) async -> Bool {
        await MicrophoneAccess.request(reason: requestPermission ? .userInitiated : .automaticPreparation)
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
            bufferSize: LiveCaptureBacklogPolicy.tapFrames(sampleRate: format.sampleRate),
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

    private func activateCaptureDelivery(generation: UInt64) {
        nativeCaptureGeneration = generation
        captureDSPNextOrdinal = 0
        captureDSPResults.removeAll(keepingCapacity: true)
        captureDSP.begin(generation: generation)
        captureTapGate.activate(captureBufferBarrier, generation: generation, configuration: .init(
            codec: transmitCodec, gainMode: MicrophoneGainSettings.mode(),
            manualGainMultiplier: MicrophoneGainSettings.load()
        ))
    }

    private nonisolated static func captureTapBlock(
        engine: AudioEngine,
        gate: CaptureTapGate,
        tapVersion: UInt64
    ) -> AVAudioNodeTapBlock {
        let processor = engine.captureDSP
        return { [weak engine, gate, processor] buffer, _ in
            if buffer.frameLength > 0 && gate.markFirstBuffer() {
                let firstBufferRate = buffer.format.sampleRate
                let firstBufferFrames = buffer.frameLength
                Task { @MainActor [weak engine] in
                    guard engine?.tapInstalled == true, engine?.tapVersion == tapVersion else { return }
                    engine?.isCaptureReady = true
                    VoiceDiagnosticLog.record("input graph ready first callback rate=\(firstBufferRate) frames=\(firstBufferFrames) durationMs=\(1000 * Double(firstBufferFrames) / firstBufferRate)")
                }
            }
            guard let ticket = gate.admitBuffer() else { return }
            let capturedAt = ProcessInfo.processInfo.systemUptime
            // AVAudioEngine delivers tap buffers on a real-time audio thread.
            // Copy PCM before the callback returns, then pass only Sendable
            // samples to the serial DSP queue; only delivery and meters use MainActor.
            let samples = NativeCapturePCM.extractSamples(from: buffer)
            let sampleRate = buffer.format.sampleRate
            processor.submit(normalizedSamples: samples, sampleRate: sampleRate, generation: ticket.generation,
                             capturedAt: capturedAt, configuration: ticket.configuration) { [weak engine] result in
                ticket.barrier.finishDSP()
                Task { @MainActor [weak engine, barrier = ticket.barrier] in
                    defer { barrier.leave() }
                    guard let result else { return }
                    engine?.acceptCaptureDSPResult(result, sourceSampleCount: samples.count,
                        fresh: LiveCaptureBacklogPolicy.isFresh(capturedAt: capturedAt,
                            now: ProcessInfo.processInfo.systemUptime))
                }
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

    private func acceptCaptureDSPResult(_ result: CaptureDSPProcessor.Result, sourceSampleCount: Int, fresh: Bool) {
        guard result.generation == captureGeneration, nativeCaptureGeneration == result.generation else { return }
        captureDSPResults[result.ordinal] = (result, sourceSampleCount, fresh)
        while let next = captureDSPResults.removeValue(forKey: captureDSPNextOrdinal) {
            captureDSPNextOrdinal &+= 1
            if next.2 { applyCaptureDSPResult(next.0, sourceSampleCount: next.1) }
        }
    }

    private func applyCaptureDSPResult(_ result: CaptureDSPProcessor.Result, sourceSampleCount: Int) {
        let generation = result.generation
        guard (isCapturing && isCaptureRequestCurrent(generation)) ||
              (captureDrainGeneration == generation && captureGeneration == generation) else { return }
        captureBufferCount += 1
        captureSampleCount += sourceSampleCount
        let metrics = result.metrics
        capturePeakRawRMS = max(capturePeakRawRMS, metrics.rawRMS)
        capturePeakRawSample = max(capturePeakRawSample, metrics.rawPeak)
        capturePeakCodecRMS = max(capturePeakCodecRMS, metrics.codecRMS)
        capturePeakCodecSample = max(capturePeakCodecSample, metrics.codecPeak)
        captureMaximumAppliedGain = max(captureMaximumAppliedGain, metrics.appliedGain)
        capturePeakTransmittedRMS = max(capturePeakTransmittedRMS, metrics.transmittedRMS)
        capturePeakTransmittedSample = max(capturePeakTransmittedSample, metrics.transmittedPeak)
        captureCodecSampleRemainder = metrics.gsmSampleRemainder
        captureEncodedFrameRemainder = metrics.gsmFrameRemainder
        if !result.transmittedPCM.isEmpty {
            onRecordingPCM?(result.transmittedPCM)
            onCapturedPCM?(result.transmittedPCM)
        }
        for packet in result.encodedPackets {
            captureEncodedByteCount += packet.count
            onCapturedAudio?(packet)
        }
        inputLevel = min(1, metrics.transmittedRMS / 10000)
        capturePeakLevel = max(capturePeakLevel, inputLevel)
        if captureBufferCount == 1 {
            VoiceDiagnosticLog.record("first capture DSP buffers codecRMS=\(metrics.codecRMS) txRMS=\(metrics.transmittedRMS) gain=\(metrics.appliedGain)")
        }
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
#if !os(watchOS) && !targetEnvironment(simulator)
        guard session.isInputAvailable else { return }
        if selectedInputDeviceID != nil {
            applyPreferredInput(session: session)
            return
        }
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
                try session.setPreferredIOBufferDuration(0.02)
            } catch {
                logger.debug("Capture recovery preferred IO buffer duration step failed error='\(error.localizedDescription, privacy: .public)'")
            }
#endif
            try session.setActive(true)
            logRouteDiagnostics(context: "full-reset-session-activated")
            normalizePreferredInputIfNeeded(session: session)
            ensurePlaybackOutputRoute(session: session)
            applyPreferredInput(session: session)

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
        captureDSP.end(generation: captureGeneration)
        nativeCaptureGeneration = nil
        captureDSPResults.removeAll(keepingCapacity: true)
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
        inputPreparationGeneration &+= 1
        let generation = inputPreparationGeneration
        prepareCaptureTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            _ = await self.prepareCaptureInput(requestPermission: false)
            if self.inputPreparationGeneration == generation { self.prepareCaptureTask = nil }
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

        let observedEngine = engine
        let engineConfigObserver = center.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self, weak observedEngine] _ in
            Task { @MainActor [weak self, weak observedEngine] in
                guard let self, let observedEngine, self.engine === observedEngine else { return }
                self.handleEngineConfigurationChange()
            }
        }

        sessionObservers = [
            SessionObserverToken(rawValue: routeObserver),
            SessionObserverToken(rawValue: interruptionObserver),
            SessionObserverToken(rawValue: mediaResetObserver),
            SessionObserverToken(rawValue: engineConfigObserver),
        ]
#if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            let availableInputsObserver = center.addObserver(
            forName: AVAudioSession.availableInputsChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let session = AVAudioSession.sharedInstance()
                let previous = Set(self.availableInputDevices.map(\.id))
                self.refreshAvailableInputDevices(session: session)
                if let selected = self.selectedInputDeviceID, !previous.contains(selected),
                   self.availableInputDevices.contains(where: { $0.id == selected }) {
                    self.applyPreferredInput(session: session)
                }
            }
        }
            sessionObservers.append(SessionObserverToken(rawValue: availableInputsObserver))
        }
#endif
        hasInstalledSessionObservers = true
    }

    private func handleRouteChange(reasonValue: UInt) {
        refreshAvailableInputDevices()
        updateOutputRouteName()
        guard playbackDesired || captureRequested else { return }
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        if reason == .categoryChange {
            recoverAudioDevice(for: .categoryChange(inputUsable: hasUsableCaptureRoute()))
            return
        }
        if reason == .override { return }
        guard !isPreparingCapture, !isPerformingCaptureRecovery, !isDeviceRecovering else { return }
        recoverAudioDevice(for: .deviceChange)
    }

    private func recoverAudioDevice(for event: AudioDeviceRecoveryPolicy.Event) {
        let plan = AudioDeviceRecoveryPolicy.plan(for: event,
            playbackActive: playbackDesired && automaticPlaybackAllowed && !isAudioInterrupted, captureRequested: captureRequested,
            preparingOrRecovering: isPreparingCapture || isPerformingCaptureRecovery || isDeviceRecovering)
        guard plan != .none else { return }
        if plan.rebuildGraph || plan.discardBufferedReceive {
            prepareCaptureTask?.cancel()
            prepareCaptureTask = nil
        }
        if plan.stopCapture {
            invalidateCaptureStart(preservingIntent: false)
            onCaptureSuspended?()
        } else if tapInstalled && (plan.rebuildGraph || plan.discardBufferedReceive) {
            stopCaptureTap(preservingIntent: false)
        }
        if plan.discardBufferedReceive { stopPlaybackTimeline() }
        if case .interruptionBegan = event {
            engine.pause()
            isRunning = false
            return
        }
        guard plan.rebuildGraph || plan.restartPlayback || plan.prepareMicrophone else { return }
        audioDeviceRecoveryTask?.cancel()
        isDeviceRecovering = true
        audioDeviceRecoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            defer { self.isDeviceRecovering = false; self.audioDeviceRecoveryTask = nil }
            if plan.rebuildGraph {
                self.engine.stop()
                self.isRunning = false
            }
            if plan.restartPlayback && self.playbackDesired && !self.isAudioInterrupted {
                self.startPlayback(rebuildGraph: plan.rebuildGraph)
            } else if plan.rebuildGraph {
                self.replaceEngineAfterSessionActivation()
            }
            if plan.prepareMicrophone && self.playbackDesired && !self.isAudioInterrupted {
                self.scheduleInputPreparation()
            }
        }
    }

    private func hasUsableCaptureRoute() -> Bool {
        let inputNode = engine.inputNode
        let outputFormat = inputNode.outputFormat(forBus: 0)
        return isUsableHardwareFormat(outputFormat)
    }

    private func handleInterruption(typeValue: UInt, optionsValue: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .began {
            isAudioInterrupted = true
            automaticPlaybackAllowed = false
            audioDeviceRecoveryTask?.cancel()
            audioDeviceRecoveryTask = nil
            isDeviceRecovering = false
            recoverAudioDevice(for: .interruptionBegan)
        } else {
            isAudioInterrupted = false
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            automaticPlaybackAllowed = shouldResume
            recoverAudioDevice(for: .interruptionEnded(shouldResume: shouldResume))
        }
    }

    private func handleMediaServicesReset() {
        recoverAudioDevice(for: .mediaReset)
    }

    private func handleEngineConfigurationChange() {
        guard (isRunning && !engine.isRunning) || (captureRequested && !hasUsableCaptureRoute()) else { return }
        recoverAudioDevice(for: .engineConfigurationChanged)
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
        stopPlaybackTimeline()
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
        guard outputPreference == .speaker else { return }

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
