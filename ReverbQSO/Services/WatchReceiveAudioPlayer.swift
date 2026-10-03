// SPDX-License-Identifier: GPL-3.0-or-later

#if os(watchOS)
import AVFoundation
import Foundation
import os

/// Plays phone-forwarded EchoLink receive audio on Watch without opening an
/// input route or requesting microphone permission.
@MainActor
final class WatchReceiveAudioPlayer {
    private static let sampleRate = 8_000.0
    private static let maximumQueuedSamples = 1_936 // 242 ms including clock correction at 8 kHz

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let gsmCodec = GSMCodec()
    private let speexCodec = SpeexCodec()
    private let logger = Logger(subsystem: "org.reverbqso.app", category: "WatchReceiveAudio")
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private var isConfigured = false
    private var ownsPlaybackSession = false
    private var queuedSampleCount = 0
    private var playbackGeneration: UInt64 = 0
    private var playbackGain = ReceivePlaybackGain()
    private let receiveClock = ReceiveClockCompensator()
    private let receiveSpeech = ReceiveSpeechSmoother()
    private var receivePlayout = ReceiveAdaptivePlayoutBuffer()
    private var playoutTask: Task<Void, Never>?
    private var playbackEndSampleTime: Int64 = 0
    private var lastReceiveArrival = -Double.infinity

    /// Parses and plays one complete EchoLink/RTP voice datagram.
    @discardableResult
    func play(_ datagram: Data) -> Bool {
        guard let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(datagram) else { return false }

        let samples: [Int16]
        switch parsed.packet {
        case .gsm(let payload):
            samples = gsmCodec.decodePacket(payload)
        case .speex(let payload):
            guard let decoded = speexCodec.decodePacket(payload) else { return false }
            samples = decoded
        case .pcm(let decoded):
            samples = decoded
        case .unsupportedPayloadType:
            return false
        }

        guard !samples.isEmpty, startIfNeeded() else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReceiveArrival >= 0.5 { receiveClock.reset() }
        lastReceiveArrival = now
        receivePlayout.enqueue(receiveSpeech.process(samples, metadata: parsed.metadata, now: now), networkSampleCount: samples.count, playbackQueuedSamples: remainingPlaybackSamples, now: now)
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
                let corrected = self.receiveClock.process(packet, queuedSamples: self.remainingPlaybackSamples,
                    targetQueuedSamples: Int(self.receivePlayout.targetDelay * 8000))
                guard let buffer = self.makeBuffer(corrected) else { continue }
                if self.queuedSampleCount + corrected.count > Self.maximumQueuedSamples {
                    self.playbackGeneration &+= 1
                    self.playerNode.stop()
                    self.queuedSampleCount = 0
                    self.playbackEndSampleTime = 0
                    self.receiveClock.reset()
                }
                let token = self.playbackGeneration
                let count = corrected.count
                self.playbackEndSampleTime = max(self.playbackEndSampleTime, self.renderedPlaybackSampleTime ?? 0) + Int64(count)
                self.queuedSampleCount += count
                self.playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.playbackGeneration == token else { return }
                        self.queuedSampleCount = max(0, self.queuedSampleCount - count)
                    }
                }
                if !self.playerNode.isPlaying { self.playerNode.play() }
            }
            self.schedulePlayout()
        }
    }

    /// Stops forwarded audio and resets decoder and queue state for a new phone QSO.
    func stop() {
        RecordingAudioSession.shared.endLiveAudio(owner: self)
        playbackGeneration &+= 1
        queuedSampleCount = 0
        playbackEndSampleTime = 0
        lastReceiveArrival = -Double.infinity
        playbackGain.reset()
        playoutTask?.cancel()
        playoutTask = nil
        receivePlayout.reset()
        receiveSpeech.reset()
        receiveClock.reset()
        if isConfigured { playerNode.stop() }
        engine.stop()
        gsmCodec.resetAll()
        speexCodec.reset()
        if ownsPlaybackSession {
            ownsPlaybackSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private var renderedPlaybackSampleTime: Int64? {
        guard let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else { return nil }
        return playerTime.sampleTime
    }
    private var remainingPlaybackSamples: Int {
        guard let rendered = renderedPlaybackSampleTime else { return queuedSampleCount }
        return max(0, Int(playbackEndSampleTime - rendered))
    }

    private func startIfNeeded() -> Bool {
        if engine.isRunning { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            ownsPlaybackSession = true

            if !isConfigured {
                engine.attach(playerNode)
                engine.connect(playerNode, to: engine.mainMixerNode, format: format)
                isConfigured = true
            }
            if !engine.isRunning {
                try engine.start()
            }
            RecordingAudioSession.shared.beginLiveAudio(owner: self)
            return true
        } catch {
            logger.error("Watch receive playback could not start error='\(error.localizedDescription, privacy: .public)'")
            if ownsPlaybackSession {
                ownsPlaybackSession = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            return false
        }
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
