// SPDX-License-Identifier: GPL-3.0-or-later

#if os(watchOS)
import AVFoundation
import Foundation
import os

/// Plays phone-forwarded EchoLink receive audio on Watch without opening an
/// input route or requesting microphone permission.
@MainActor
final class WatchReceiveAudioPlayer {
    private struct ObserverToken: @unchecked Sendable {
        let rawValue: NSObjectProtocol
    }

    private static let sampleRate = 8_000.0
    private static let maximumQueuedSamples = 1_936 // 242 ms including clock correction at 8 kHz
    private static let recoveryQueuedSamples = 1_280 // Leave one packet of output-preroll headroom.

    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private let gsmCodec = GSMCodec()
    private let speexCodec = SpeexReceiveStreamDecoder()
    private let logger = Logger(subsystem: "org.reverbqso.app", category: "WatchReceiveAudio")
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private var isConfigured = false
    private var queuedSampleCount = 0
    private var playbackGeneration: UInt64 = 0
    private var playbackGain = ReceivePlaybackGain()
    private var playbackHistory = ReceivePlaybackHistory()
    private let receiveClock = ReceiveClockCompensator()
    private let receiveSpeech = ReceiveSpeechSmoother()
    private var receivePlayout = ReceiveAdaptivePlayoutBuffer()
    private var playoutTask: Task<Void, Never>?
    private var playbackEndSampleTime: Int64 = 0
    private var lastReceiveArrival = -Double.infinity
    private var notificationObservers: [ObserverToken] = []
    private var engineConfigurationObserver: ObserverToken?
    private var playbackRequested = false
    private var resumeAfterInterruption = false
    private var isInterrupted = false
    private var automaticPlaybackAllowed = true
    private var isRebuildingGraph = false

    init() {
        installNotificationObservers()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer.rawValue)
        }
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver.rawValue)
        }
    }

    /// Parses and plays one complete EchoLink/RTP voice datagram.
    @discardableResult
    func play(_ datagram: Data) -> Bool {
        guard !isInterrupted, automaticPlaybackAllowed else { return false }
        guard let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(datagram) else { return false }

        switch parsed.packet {
        case .gsm(let payload):
            guard !payload.isEmpty,
                  payload.count.isMultiple(of: GSMCodec.encodedFrameSize) else { return false }
        case .speex(let payload):
            guard !payload.isEmpty else { return false }
        case .pcm(let decoded):
            guard !decoded.isEmpty else { return false }
        case .unsupportedPayloadType:
            return false
        }

        let priorPlaybackRequest = playbackRequested
        playbackRequested = true
        guard startIfNeeded() else {
            playbackRequested = priorPlaybackRequest
            return false
        }

        let samples: [Int16]
        var nativeConcealment: [Int16]?
        switch parsed.packet {
        case .gsm(let payload):
            samples = gsmCodec.decodePacket(payload)
        case .speex(let payload):
            guard let decoded = speexCodec.decode(payload, metadata: parsed.metadata) else { return false }
            samples = decoded.received
            nativeConcealment = decoded.concealed
        case .pcm(let decoded):
            samples = decoded
        case .unsupportedPayloadType:
            return false
        }

        guard !samples.isEmpty else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReceiveArrival >= 0.5 { receiveClock.reset() }
        lastReceiveArrival = now
        let playbackSamples: [Int16]
        if let nativeConcealment {
            receiveSpeech.reset()
            let retained = ReceivePlaybackQueue().retainedConcealment(nativeConcealment,
                receivedSamples: samples.count, remainingSamples: remainingPlaybackSamples)
            playbackSamples = Array(retained) + samples
        }
        else { playbackSamples = receiveSpeech.process(samples, metadata: parsed.metadata, now: now) }
        receivePlayout.enqueue(playbackSamples, networkSampleCount: samples.count, playbackQueuedSamples: remainingPlaybackSamples, now: now)
        schedulePlayout()
        return true
    }

    private func schedulePlayout() {
        guard playoutTask == nil, let deadline = receivePlayout.nextDeadline else { return }
        let generation = playbackGeneration
        playoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
            catch { return }
            guard let self, !Task.isCancelled, self.playbackGeneration == generation else { return }
            self.playoutTask = nil
            for packet in self.receivePlayout.drain() {
                let renderedSnapshot = self.renderedPlaybackSampleTime
                if let rendered = renderedSnapshot { self.playbackHistory.prune(renderedSampleTime: rendered) }
                let remaining = self.playbackHistory.remainingSamples(renderedSampleTime: renderedSnapshot)
                let corrected = self.receiveClock.process(packet, queuedSamples: remaining,
                    targetQueuedSamples: Int(self.receivePlayout.targetDelay * 8000))
                guard let buffer = self.makeBuffer(corrected), let data = buffer.floatChannelData else { continue }
                let incoming = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
                var start = max(self.playbackEndSampleTime, max(0, renderedSnapshot ?? 0))
                var scheduledBuffer = buffer
                var scheduledSamples = incoming
                if remaining + incoming.count > Self.maximumQueuedSamples {
                    let replacement = self.playbackHistory.boundedReplacement(adding: incoming, maximumSamples: Self.recoveryQueuedSamples)
                    guard let combined = self.makeProcessedBuffer(replacement.samples) else { continue }
                    self.playbackGeneration &+= 1
                    self.playerNode.stop()
                    self.queuedSampleCount = 0
                    self.playbackEndSampleTime = 0
                    self.playbackHistory.reset()
                    self.receiveClock.reset()
                    // Ignore any render cursor retained from the stopped generation.
                    start = 0
                    scheduledBuffer = combined
                    scheduledSamples = replacement.samples
                }
                let token = self.playbackGeneration
                let count = scheduledSamples.count
                self.playbackEndSampleTime = start + Int64(count)
                self.playbackHistory.append(scheduledSamples, startingAt: start)
                let end = self.playbackEndSampleTime
                self.queuedSampleCount += count
                self.playerNode.scheduleBuffer(scheduledBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.playbackGeneration == token else { return }
                        self.queuedSampleCount = max(0, self.queuedSampleCount - count)
                        self.playbackHistory.prune(renderedSampleTime: end)
                    }
                }
                if !self.playerNode.isPlaying { self.playerNode.play() }
            }
            self.schedulePlayout()
        }
    }

    /// Stops forwarded audio and resets decoder and queue state for a new phone QSO.
    func stop() {
        playbackRequested = false
        resumeAfterInterruption = false
        automaticPlaybackAllowed = true
        discardBufferedReceive()
        playbackGain.reset()
        engine.stop()
        RecordingAudioSession.shared.endLiveAudio(owner: self)
        gsmCodec.resetAll()
        speexCodec.reset()
    }

    private func makeProcessedBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices { data[0][index] = samples[index] }
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

    private func startIfNeeded() -> Bool {
        guard !isInterrupted, automaticPlaybackAllowed else { return false }
        if engine.isRunning { return true }
        RecordingAudioSession.shared.beginLiveAudio(owner: self)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            if !isConfigured {
                engine.attach(playerNode)
                engine.connect(playerNode, to: engine.mainMixerNode, format: format)
                isConfigured = true
            }
            if !engine.isRunning {
                try engine.start()
            }
            return true
        } catch {
            logger.error("Watch receive playback could not start error='\(error.localizedDescription, privacy: .public)'")
            discardBufferedReceive()
            engine.stop()
            RecordingAudioSession.shared.endLiveAudio(owner: self)
            return false
        }
    }

    private func discardBufferedReceive() {
        playbackGeneration &+= 1
        queuedSampleCount = 0
        playbackEndSampleTime = 0
        playbackHistory.reset()
        lastReceiveArrival = -Double.infinity
        playoutTask?.cancel()
        playoutTask = nil
        receivePlayout.reset()
        receiveSpeech.reset()
        receiveClock.reset()
        if isConfigured { playerNode.stop() }
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        notificationObservers.append(ObserverToken(rawValue: center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let rawReason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            Task { @MainActor [weak self] in
                self?.handleRouteChange(rawReason: rawReason)
            }
        }))

        notificationObservers.append(ObserverToken(rawValue: center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let rawOptions = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        }))

        notificationObservers.append(ObserverToken(rawValue: center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        }))

        installEngineConfigurationObserver()
    }

    private func installEngineConfigurationObserver() {
        let center = NotificationCenter.default
        if let engineConfigurationObserver {
            center.removeObserver(engineConfigurationObserver.rawValue)
        }
        let observedEngine = engine
        engineConfigurationObserver = ObserverToken(rawValue: center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: observedEngine,
            queue: .main
        ) { [weak self, weak observedEngine] _ in
            Task { @MainActor [weak self, weak observedEngine] in
                self?.handleEngineConfigurationChange(observedEngine: observedEngine)
            }
        })
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard !isRebuildingGraph,
              let rawReason,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange,
             .noSuitableRouteForCategory, .wakeFromSleep:
            discardBufferedReceive()
        case .categoryChange, .override:
            return
        case .unknown:
            discardBufferedReceive()
        @unknown default:
            discardBufferedReceive()
        }
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt) {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            isInterrupted = true
            automaticPlaybackAllowed = false
            resumeAfterInterruption = playbackRequested
            discardBufferedReceive()
            engine.stop()

        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            isInterrupted = false
            automaticPlaybackAllowed = shouldResume
            let resume = resumeAfterInterruption && playbackRequested && shouldResume
            resumeAfterInterruption = false
            guard resume else { return }
            _ = startIfNeeded()

        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        guard !isRebuildingGraph else { return }
        let shouldRestart = playbackRequested && !isInterrupted && automaticPlaybackAllowed
        discardBufferedReceive()
        rebuildAudioGraph()
        guard shouldRestart, playbackRequested else { return }
        _ = startIfNeeded()
    }

    private func handleEngineConfigurationChange(observedEngine: AVAudioEngine?) {
        guard !isRebuildingGraph,
              let observedEngine,
              observedEngine === engine,
              !engine.isRunning else { return }
        discardBufferedReceive()
        guard playbackRequested else { return }
        // Restart on the next forwarded packet. Restarting synchronously from
        // this notification can generate another configuration notification.
        engine.stop()
    }

    private func rebuildAudioGraph() {
        guard !isRebuildingGraph else { return }
        isRebuildingGraph = true
        defer { isRebuildingGraph = false }

        engine.stop()
        if isConfigured, engine.attachedNodes.contains(playerNode) {
            engine.detach(playerNode)
        }
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        isConfigured = false
        installEngineConfigurationObserver()
    }

    private func makeBuffer(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        let amplified = playbackGain.process(samples)
        for index in samples.indices { channel[index] = amplified[index] }
        return buffer
    }
}
#endif
