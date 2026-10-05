// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import XCTest
#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif
@testable import ReverbQSO

@MainActor
final class AudioEngineDeviceRecoveryTests: XCTestCase {
    func testMacReceiveDoesNotReserveHeadsetMicrophoneAndReleaseRestoresPlayback() async throws {
#if DEBUG && targetEnvironment(macCatalyst)
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else {
            throw XCTSkip("Mac microphone route audit is opt-in")
        }
        guard MicrophoneAccess.status == .granted else { throw XCTSkip("Microphone permission must already be granted") }
        let priorInput = AudioRoutePreferences.inputUID()
        defer { AudioRoutePreferences.save(inputUID: priorInput) }
        AudioRoutePreferences.save(inputUID: nil)
        let engine = AudioEngine()
        defer { engine.stopAll() }
        let session = AVAudioSession.sharedInstance()
        var encodedBytes = 0
        engine.onCapturedAudio = { encodedBytes += $0.count }
        engine.startPlayback()
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(session.category, .playback, "Receive-only radio must not activate a headset microphone")
        XCTAssertEqual(session.mode, .default)
        XCTAssertFalse(engine.isCaptureReady)
        let started = await engine.startCapture(requestPermission: false)
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(engine.isCapturing)
        XCTAssertTrue(engine.isCaptureReady, "Native microphone must deliver actual PCM callbacks")
        XCTAssertGreaterThan(encodedBytes, 0, "PTT must deliver encoded microphone packets")
        XCTAssertEqual(session.category, .playback, "Native capture must not change the receive session")
        XCTAssertEqual(session.mode, .default, "Voice-chat mode forces Bluetooth call routing")
        XCTAssertFalse(session.categoryOptions.contains(.allowBluetoothHFP), "Automatic input should preserve stereo headphones")
        _ = await engine.stopCaptureAndFlushPendingBuffers()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(engine.isCapturing)
        XCTAssertFalse(engine.isCaptureReady, "Release must retire the native microphone tap")
        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(engine.isRunning)
        print("Mac route audit after release category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=\(session.currentRoute.outputs.map(\.portType.rawValue))")
#else
        throw XCTSkip("Requires opted-in Mac Catalyst microphone route audit")
#endif
    }

    func testMacIntersamplePeaksStayBelowFullScaleAfterNativeResampling() async throws {
#if DEBUG && targetEnvironment(macCatalyst)
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else {
            throw XCTSkip("Mac output peak audit is opt-in")
        }
        let engine = AudioEngine()
        defer { engine.stopAll() }
        engine.startPlayback()
        try await Task.sleep(for: .milliseconds(200))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-peaks-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try engine.beginAuditRenderCapture(url: url)
        // A 2 kHz sine halfway between samples has a reconstructed peak larger
        // than every 8 kHz sample. A sample-peak limiter alone misses it.
        let tone = (0..<640).map { Int16(20_000 * sin(2 * Double.pi * 2_000 * Double($0) / 8_000 + .pi / 4)) }
        for _ in 0..<4 {
            engine.playReceivedPCM(tone)
            try await Task.sleep(for: .milliseconds(80))
        }
        try await Task.sleep(for: .milliseconds(300))
        let report = await engine.endAuditRenderCapture(capture)
        XCTAssertEqual(report["writeErrors"], 0)
        XCTAssertEqual(report["droppedTapBuffers"], 0)
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let peak = (0..<Int(buffer.format.channelCount)).flatMap { channel in
            (0..<Int(buffer.frameLength)).map { abs(channels[channel][$0]) }
        }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.2, "The tone must actually render")
        XCTAssertLessThan(peak, 1, "Native sample-rate conversion must not create clipped output")
        let snapshot = engine.auditPlaybackSnapshot
        XCTAssertEqual(snapshot["nativePeakLimiterActive"], 1)
        let latency = try XCTUnwrap(snapshot["nativePeakLimiterLatencyMicroseconds"])
        XCTAssertLessThanOrEqual(latency, 5_000, "Peak protection must not introduce a large reported delay")
        print("Native peak audit peak=\(peak) limiterLatencyMicroseconds=\(latency)")
#else
        throw XCTSkip("Requires opted-in Mac Catalyst native render audit")
#endif
    }

    func testPhysicalWarmInputRemainsSilentUntilPTTAndDeliversEncodedAudio() async throws {
#if DEBUG && os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else {
            throw XCTSkip("Physical microphone audit is opt-in")
        }
        guard MicrophoneAccess.status == .granted else { throw XCTSkip("Microphone permission must already be granted") }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while UIApplication.shared.applicationState != .active, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard UIApplication.shared.applicationState == .active else { throw XCTSkip("Unlock the foreground app for this audit") }
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let engine = AudioEngine()
        var payloadBytes = 0
        engine.onCapturedAudio = { payloadBytes += $0.count }
        defer { engine.onCapturedAudio = nil; engine.stopAll() }
        engine.startPlayback()
        let prepared = await engine.prepareCaptureInput(requestPermission: false)
        XCTAssertTrue(prepared)
        XCTAssertEqual(engine.auditPlaybackSnapshot["actualEngineRunning"], 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(payloadBytes, 0, "Warm microphone must never encode before PTT")
        let before = engine.auditPlaybackSnapshot
        let started = await engine.startCapture(requestPermission: false)
        XCTAssertTrue(started)
        XCTAssertTrue(engine.isCapturing)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(payloadBytes, 0, "Prepared PTT must deliver encoded microphone audio")
        XCTAssertEqual(engine.auditPlaybackSnapshot["actualEngineRunning"], 1)
        XCTAssertEqual(engine.auditPlaybackSnapshot["graphReplacements"], before["graphReplacements"])
        XCTAssertEqual(engine.auditPlaybackSnapshot["timelineResets"], before["timelineResets"])
        _ = await engine.stopCaptureAndFlushPendingBuffers()
        let bytesAtRelease = payloadBytes
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(payloadBytes, bytesAtRelease, "PTT release must seal audio delivery while keeping the input graph ready")
        XCTAssertEqual(engine.auditPlaybackSnapshot["actualEngineRunning"], 1)
        XCTAssertEqual(engine.auditPlaybackSnapshot["graphReplacements"], before["graphReplacements"])
        XCTAssertEqual(engine.auditPlaybackSnapshot["timelineResets"], before["timelineResets"])
#else
        throw XCTSkip("Requires opted-in physical iPhone audit")
#endif
    }

    func testMacPTTReleasePreservesQueuedReceiveTone() async throws {
#if DEBUG && targetEnvironment(macCatalyst)
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else {
            throw XCTSkip("Mac mixer audit is opt-in")
        }
        guard MicrophoneAccess.status == .granted else { throw XCTSkip("Microphone permission must already be granted") }
        let engine = AudioEngine()
        defer { engine.stopAll() }
        engine.startPlayback()
        let started = await engine.startCapture(requestPermission: false)
        XCTAssertTrue(started)
        guard started else { return }
        var payloadBytes = 0
        engine.onCapturedAudio = { payloadBytes += $0.count }
        defer { engine.onCapturedAudio = nil }
        let inputDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !engine.isCaptureReady, ProcessInfo.processInfo.systemUptime < inputDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(engine.isCaptureReady, "Input graph must deliver a callback before testing release")
        // Capture starts after native I/O startup has had time to settle.
        try await Task.sleep(for: .milliseconds(500))
        // Only the synthetic receive tone reaches the mixer capture. Microphone
        // payloads have no consumer and never leave this standalone engine.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ptt-receive-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try engine.beginAuditRenderCapture(url: url)
        let tone = (0..<2400).map { Int16(8000 * sin(2 * Double.pi * 700 * Double($0) / 8000)) }
        print("PTT receive tone source samples=\(tone.count) peak=\(tone.map { abs(Int($0)) }.max() ?? 0)")
        engine.playReceivedPCM(tone)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while (engine.auditPlaybackSnapshot["remainingSamples"] ?? 0) < 1600,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let before = engine.auditPlaybackSnapshot
        XCTAssertGreaterThan(before["remainingSamples"] ?? 0, 1600)
        _ = await engine.stopCaptureAndFlushPendingBuffers()
        XCTAssertEqual(engine.auditPlaybackSnapshot["timelineResets"], before["timelineResets"])
        XCTAssertEqual(engine.auditPlaybackSnapshot["actualEngineRunning"], 1)
        try await Task.sleep(for: .milliseconds(450))
        let report = await engine.endAuditRenderCapture(capture)
        XCTAssertEqual(report["writeErrors"], 0)
        XCTAssertEqual(report["droppedTapBuffers"], 0)
        let file = try AVAudioFile(forReading: url)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        print("Mixer file diagnostic report=\(report) bytes=\(bytes) length=\(file.length) processingFormat=\(file.processingFormat) fileFormat=\(file.fileFormat)")
        XCTAssertGreaterThan(file.length, 0, "Mixer capture must contain rendered frames")
        guard file.length > 0 else { return }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        print("Mixer buffer diagnostic frameLength=\(buffer.frameLength) format=\(buffer.format)")
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let energies = (0..<Int(buffer.format.channelCount)).map { channel -> [String: Double] in
            var squareSum = 0.0
            var peak = 0.0
            var audible = 0
            for frame in 0..<Int(buffer.frameLength) {
                let value = Double(channels[channel][frame])
                squareSum += value * value
                peak = max(peak, abs(value))
                if abs(value) > 0.02 { audible += 1 }
            }
            return ["channel": Double(channel), "peak": peak,
                    "rms": sqrt(squareSum / Double(max(1, buffer.frameLength))),
                    "audibleSeconds": Double(audible) / file.processingFormat.sampleRate]
        }
        print("PTT mixer audit before=\(before) after=\(engine.auditPlaybackSnapshot) render=\(report) energies=\(energies) schedule=\(engine.auditPlaybackSchedule.suffix(6)) events=\(engine.auditEngineEvents.suffix(12))")
        XCTAssertGreaterThan(energies.map { $0["audibleSeconds"] ?? 0 }.max() ?? 0, 0.18,
                             "The queued synthetic tone tail must render across PTT release")
        XCTAssertFalse(engine.isCapturing)
        XCTAssertFalse(engine.isCaptureReady)
        let postReleaseAudible = try await captureMacReceiveTone(engine, label: "post-release")
        XCTAssertGreaterThan(postReleaseAudible, 0.18, "Receive tone queued after release must render")
        let sealedBytes = payloadBytes
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(payloadBytes, sealedBytes, "Closed microphone must not encode while PTT is released")
        let beforeSecondPTT = engine.auditPlaybackSnapshot
        let restarted = await engine.startCapture(requestPermission: false)
        XCTAssertTrue(restarted)
        XCTAssertTrue(engine.isCapturing)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(payloadBytes, sealedBytes, "Second PTT must renew microphone capture and DSP delivery")
        XCTAssertEqual(engine.auditPlaybackSnapshot["graphReplacements"], beforeSecondPTT["graphReplacements"])
        XCTAssertEqual(engine.auditPlaybackSnapshot["timelineResets"], beforeSecondPTT["timelineResets"])
        _ = await engine.stopCaptureAndFlushPendingBuffers()
        let sealedSecondBytes = payloadBytes
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(payloadBytes, sealedSecondBytes)
        XCTAssertFalse(engine.isCapturing)
#else
        throw XCTSkip("Requires opted-in Mac Catalyst mixer audit")
#endif
    }

    func testMacFirstPTTPreservesReceiveToneQueuedBeforeCaptureStarts() async throws {
#if DEBUG && targetEnvironment(macCatalyst)
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else {
            throw XCTSkip("Mac mixer audit is opt-in")
        }
        guard MicrophoneAccess.status == .granted else { throw XCTSkip("Microphone permission must already be granted") }
        let engine = AudioEngine()
        defer { engine.stopAll() }
        engine.startPlayback()
        try await Task.sleep(for: .milliseconds(500))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("receive-restart-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try engine.beginAuditRenderCapture(url: url)
        // A standalone engine has no microphone consumer and no network peer.
        let tone = (0..<1920).map { Int16(8000 * sin(2 * Double.pi * 700 * Double($0) / 8000)) }
        engine.playReceivedPCM(tone)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while (engine.auditPlaybackSnapshot["remainingSamples"] ?? 0) <= 1600,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let before = engine.auditPlaybackSnapshot
        XCTAssertGreaterThan(before["remainingSamples"] ?? 0, 1600)
        let started = await engine.startCapture(requestPermission: false)
        XCTAssertTrue(started)
        XCTAssertEqual(engine.auditPlaybackSnapshot["actualEngineRunning"], 1)
        XCTAssertEqual(engine.auditPlaybackSnapshot["timelineResets"], before["timelineResets"])
        XCTAssertEqual(engine.auditPlaybackSnapshot["graphReplacements"], before["graphReplacements"])
        XCTAssertEqual(engine.auditPlaybackSnapshot["backlogTrims"], 0)
        XCTAssertEqual(engine.auditPlaybackSnapshot["trimmedSamples"], 0)
        try await Task.sleep(for: .milliseconds(450))
        _ = await engine.stopCaptureAndFlushPendingBuffers()
        let report = await engine.endAuditRenderCapture(capture)
        let file = try AVAudioFile(forReading: url)
        print("Restart tone diagnostic before=\(before) after=\(engine.auditPlaybackSnapshot) report=\(report) length=\(file.length) format=\(file.processingFormat) events=\(engine.auditEngineEvents.suffix(12))")
        XCTAssertGreaterThan(file.length, 0)
        guard file.length > 0 else { return }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let audibleSeconds = (0..<Int(buffer.format.channelCount)).map { channel in
            Double((0..<Int(buffer.frameLength)).filter { abs(channels[channel][$0]) > 0.02 }.count) / file.processingFormat.sampleRate
        }
        print("Restart tone audibleSeconds=\(audibleSeconds) schedule=\(engine.auditPlaybackSchedule.suffix(6))")
        XCTAssertGreaterThan(audibleSeconds.max() ?? 0, 0.18,
                             "Receive speech queued before the first PTT must survive native microphone startup")
        XCTAssertEqual(report["writeErrors"], 0)
        XCTAssertEqual(report["droppedTapBuffers"], 0)
        XCTAssertEqual(engine.auditPlaybackSnapshot["timelineResets"], before["timelineResets"])
#else
        throw XCTSkip("Requires opted-in Mac Catalyst mixer audit")
#endif
    }

    func testMacStandaloneReceiveToneRendersWithoutPTT() async throws {
#if DEBUG && targetEnvironment(macCatalyst)
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else {
            throw XCTSkip("Mac mixer audit is opt-in")
        }
        let engine = AudioEngine()
        defer { engine.stopAll() }
        engine.startPlayback()
        XCTAssertEqual(engine.auditPlaybackSnapshot["actualEngineRunning"], 1)
        try await Task.sleep(for: .milliseconds(500))
        let audible = try await captureMacReceiveTone(engine, label: "standalone")
        XCTAssertGreaterThan(audible, 0.18, "A synthetic receive tone must render without microphone or PTT")
#else
        throw XCTSkip("Requires opted-in Mac Catalyst mixer audit")
#endif
    }

    func testMacFivePacketBurstPreservesSpeechWithoutReset() async throws {
#if DEBUG && targetEnvironment(macCatalyst)
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else {
            throw XCTSkip("Mac mixer audit is opt-in")
        }
        let engine = AudioEngine()
        defer { engine.stopAll() }
        engine.startPlayback()
        XCTAssertEqual(engine.auditPlaybackSnapshot["actualEngineRunning"], 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("receive-burst-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try engine.beginAuditRenderCapture(url: url)
        let tone = (0..<640).map { Int16(8000 * sin(2 * Double.pi * 700 * Double($0) / 8000)) }
        engine.playReceivedPCM(tone)
        try await Task.sleep(for: .milliseconds(500))
        let before = engine.auditPlaybackSnapshot
        // A network receive burst can deliver several packets in one actor
        // turn, before the playout task gets an opportunity to drain them.
        for _ in 0..<5 { engine.playReceivedPCM(tone) }
        try await Task.sleep(for: .seconds(1))
        let after = engine.auditPlaybackSnapshot
        let report = await engine.endAuditRenderCapture(capture)
        XCTAssertEqual(after["playoutDiscardedPackets"], before["playoutDiscardedPackets"])
        XCTAssertEqual(after["overflowIncomingDrops"], before["overflowIncomingDrops"])
        XCTAssertEqual(after["timelineResets"], before["timelineResets"])
        XCTAssertEqual(after["actualEngineRunning"], 1)
        XCTAssertEqual(report["writeErrors"], 0)
        XCTAssertEqual(report["droppedTapBuffers"], 0)

        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let rate = file.processingFormat.sampleRate
        let windowFrames = max(1, Int((rate * 0.01).rounded()))
        // Count energetic 10 ms windows rather than individual sine samples:
        // zero crossings are audible tone duration too. Including the warmup
        // packet gives 480 ms expected audio; dropping two burst packets gives
        // only 320 ms and cannot satisfy this 400 ms render requirement.
        let audibleSeconds = (0..<Int(buffer.format.channelCount)).map { channel in
            var audibleFrames = 0
            for start in stride(from: 0, to: Int(buffer.frameLength), by: windowFrames) {
                let end = min(start + windowFrames, Int(buffer.frameLength))
                let squareSum = (start..<end).reduce(0.0) { sum, frame in
                    let value = Double(channels[channel][frame])
                    return sum + value * value
                }
                if sqrt(squareSum / Double(end - start)) > 0.02 { audibleFrames += end - start }
            }
            return Double(audibleFrames) / rate
        }
        print("Receive burst before=\(before) after=\(after) audibleSeconds=\(audibleSeconds) render=\(report)")
        XCTAssertGreaterThanOrEqual(audibleSeconds.max() ?? 0, 0.4,
                                   "All five queued speech packets must reach the mixer")
#else
        throw XCTSkip("Requires opted-in Mac Catalyst mixer audit")
#endif
    }

#if DEBUG && targetEnvironment(macCatalyst)
    private func captureMacReceiveTone(_ engine: AudioEngine, label: String) async throws -> Double {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("receive-control-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try engine.beginAuditRenderCapture(url: url)
        let tone = (0..<1920).map { Int16(8000 * sin(2 * Double.pi * 700 * Double($0) / 8000)) }
        print("Receive tone source label=\(label) samples=\(tone.count) peak=\(tone.map { abs(Int($0)) }.max() ?? 0)")
        engine.playReceivedPCM(tone)
        try await Task.sleep(for: .milliseconds(450))
        let report = await engine.endAuditRenderCapture(capture)
        XCTAssertEqual(report["writeErrors"], 0)
        XCTAssertEqual(report["droppedTapBuffers"], 0)
        let file = try AVAudioFile(forReading: url)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        print("Receive tone file label=\(label) report=\(report) bytes=\(bytes) length=\(file.length) processingFormat=\(file.processingFormat) fileFormat=\(file.fileFormat)")
        XCTAssertGreaterThan(file.length, 0, "Mixer capture must contain rendered frames")
        guard file.length > 0 else { return 0 }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        print("Receive tone buffer label=\(label) frameLength=\(buffer.frameLength) format=\(buffer.format)")
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let energies = (0..<Int(buffer.format.channelCount)).map { channel -> [String: Double] in
            var peak = 0.0
            var audible = 0
            for frame in 0..<Int(buffer.frameLength) {
                let value = abs(Double(channels[channel][frame]))
                peak = max(peak, value)
                if value > 0.02 { audible += 1 }
            }
            return ["channel": Double(channel), "peak": peak,
                    "audibleSeconds": Double(audible) / file.processingFormat.sampleRate]
        }
        print("Receive tone control label=\(label) snapshot=\(engine.auditPlaybackSnapshot) render=\(report) energies=\(energies) schedule=\(engine.auditPlaybackSchedule.suffix(6)) events=\(engine.auditEngineEvents.suffix(12))")
        return energies.map { $0["audibleSeconds"] ?? 0 }.max() ?? 0
    }
#endif

    func testUnconfiguredEngineCleanupAndAuditDoNotRequireAttachedPlayer() {
        let engine = AudioEngine()
        XCTAssertFalse(engine.isRunning)
        // These paths also run after session activation fails before graph setup.
        engine.resetCodecState()
        engine.stopAll()
        engine.resetCodecState()
        engine.stopAll()
        XCTAssertFalse(engine.isRunning)
#if DEBUG
        XCTAssertEqual(engine.auditPlaybackSnapshot["remainingSamples"], 0)
        XCTAssertEqual(engine.auditPlaybackSnapshot["actualEngineRunning"], 0)
#endif
    }

    func testInterruptionBlocksPlaybackAndStillRecordsReceivedSamples() async {
        let engine = AudioEngine()
        engine.startPlayback()
        defer { engine.stopAll() }
        postInterruption(.began)
        await settle()
        XCTAssertFalse(engine.isRunning)
        var recorded: [Int16] = []
        engine.onRecordingPCM = { recorded = $0 }
        engine.playReceivedPCM([100, -100])
        XCTAssertEqual(recorded, [100, -100])
        XCTAssertFalse(engine.isRunning)
    }

    func testInterruptionWithoutResumeDoesNotRestartOnReceivedAudio() async {
        let engine = AudioEngine()
        engine.startPlayback()
        defer { engine.stopAll() }
        postInterruption(.began)
        await settle()
        postInterruption(.ended)
        await settle()
        engine.playReceivedPCM([100, -100])
        XCTAssertFalse(engine.isRunning)
    }

    func testStoppedSessionCannotRestartAfterInterruptionOrMediaReset() async {
        let engine = AudioEngine()
        engine.startPlayback()
        postInterruption(.began)
        await settle()
        engine.stopAll()
        postInterruption(.ended, options: .shouldResume)
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification,
                                        object: AVAudioSession.sharedInstance())
        await settle()
        XCTAssertFalse(engine.isRunning)
    }

    func testMacQueuedInterruptionFromStoppedSessionCannotBlockReconnect() async throws {
#if DEBUG && targetEnvironment(macCatalyst)
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else {
            throw XCTSkip("Mac output graph audit is opt-in")
        }
        let engine = AudioEngine()
        defer { engine.stopAll() }
        engine.startPlayback()
        XCTAssertTrue(engine.isRunning, "Initial output graph must start for observer installation")
        guard engine.isRunning else { return }

        // Posting on MainActor invokes the observer synchronously, but its
        // handling Task cannot run until this turn yields. Teardown must make
        // that queued notification belong only to the previous connection.
        postInterruption(.began)
        engine.stopAll()
        await settle()
        XCTAssertFalse(engine.isRunning)

        engine.startPlayback()
        XCTAssertTrue(engine.isRunning, "An old queued interruption must not block a fresh connection")
        XCTAssertEqual(engine.auditPlaybackSnapshot["actualEngineRunning"], 1)
#else
        throw XCTSkip("Requires opted-in Mac Catalyst output graph audit")
#endif
    }

    private func postInterruption(_ type: AVAudioSession.InterruptionType,
                                  options: AVAudioSession.InterruptionOptions = []) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), userInfo: [
                AVAudioSessionInterruptionTypeKey: NSNumber(value: type.rawValue),
                AVAudioSessionInterruptionOptionKey: NSNumber(value: options.rawValue)
            ])
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
}
