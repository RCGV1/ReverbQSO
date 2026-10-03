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
    private static let maximumQueuedSamples = 4_000 // 500 ms at 8 kHz

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

        guard !samples.isEmpty,
              queuedSampleCount + samples.count <= Self.maximumQueuedSamples,
              startIfNeeded(),
              let buffer = makeBuffer(samples) else { return false }

        queuedSampleCount += samples.count
        let generation = playbackGeneration
        let sampleCount = samples.count
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedSampleCount = max(0, self.queuedSampleCount - sampleCount)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        return true
    }

    /// Stops forwarded audio and resets decoder and queue state for a new phone QSO.
    func stop() {
        RecordingAudioSession.shared.endLiveAudio(owner: self)
        playbackGeneration &+= 1
        queuedSampleCount = 0
        if isConfigured { playerNode.stop() }
        engine.stop()
        gsmCodec.resetAll()
        speexCodec.reset()
        if ownsPlaybackSession {
            ownsPlaybackSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
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
        for index in samples.indices {
            channel[index] = max(-1, min(1, Float(samples[index]) / Float(Int16.max) * 2.5))
        }
        return buffer
    }
}
#endif
