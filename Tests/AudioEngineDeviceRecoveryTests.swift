// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import XCTest
#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif
@testable import ReverbQSO

@MainActor
final class AudioEngineDeviceRecoveryTests: XCTestCase {
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
        XCTAssertTrue(engine.isCaptureReady)
        let postReleaseAudible = try await captureMacReceiveTone(engine, label: "post-release")
        XCTAssertGreaterThan(postReleaseAudible, 0.18, "Receive tone queued after release must render")
        let sealedBytes = payloadBytes
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(payloadBytes, sealedBytes, "Retained tap must not encode while PTT is released")
        let beforeSecondPTT = engine.auditPlaybackSnapshot
        let restarted = await engine.startCapture(requestPermission: false)
        XCTAssertTrue(restarted)
        XCTAssertTrue(engine.isCapturing)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(payloadBytes, sealedBytes, "Second PTT must renew DSP delivery from the retained tap")
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

    func testMacFirstPTTRestoresReceiveToneQueuedBeforeGraphRestart() async throws {
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
        XCTAssertEqual(engine.auditPlaybackSnapshot["timelineResets"], (before["timelineResets"] ?? 0) + 1)
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
                             "Receive speech queued before the first PTT must survive the capture graph restart")
        XCTAssertEqual(report["writeErrors"], 0)
        XCTAssertEqual(report["droppedTapBuffers"], 0)
        XCTAssertEqual(engine.auditPlaybackSnapshot["timelineResets"], (before["timelineResets"] ?? 0) + 1)
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
