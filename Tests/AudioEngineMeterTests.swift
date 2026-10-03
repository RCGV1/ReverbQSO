// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class AudioEngineMeterTests: XCTestCase {
    func testReceivedPCMReachesRecordingBeforeSpeakerStartup() {
        let engine = AudioEngine()
        var received: [Int16] = []
        var outputWasRunning: Bool?
        engine.onRecordingPCM = { samples in
            received = samples
            outputWasRunning = engine.isRunning
        }
        engine.playReceivedPCM([7, -8, 9])
        defer { engine.stopAll() }
        XCTAssertEqual(received, [7, -8, 9])
        XCTAssertEqual(outputWasRunning, false)
    }

    func testReceivedAudioLevelReturnsToZeroAfterPlaybackActivityEnds() async {
        let engine = AudioEngine()

        engine.recordOutputLevel(from: [10_000, -10_000], decayAfter: .milliseconds(30))
        XCTAssertGreaterThan(engine.outputLevel, 0)

        try? await Task.sleep(for: .milliseconds(70))

        XCTAssertEqual(engine.outputLevel, 0)
    }

    func testNewReceivedAudioRestartsLevelExpiry() async {
        let engine = AudioEngine()

        engine.recordOutputLevel(from: [10_000], decayAfter: .milliseconds(50))
        try? await Task.sleep(for: .milliseconds(30))
        engine.recordOutputLevel(from: [5_000], decayAfter: .milliseconds(50))
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertGreaterThan(engine.outputLevel, 0)

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(engine.outputLevel, 0)
    }

    func testQuietSpeechGetsImmediateBoundedTransmitGain() {
        var gain = AdaptiveMicrophoneGain()
        let quietVoice: [Int16] = Array(repeating: [Int16(200), Int16(-200)], count: 400).flatMap { $0 }

        let result = gain.process(quietVoice)

        XCTAssertGreaterThan(result.appliedGain, 1)
        XCTAssertLessThanOrEqual(result.appliedGain, 8)
        XCTAssertGreaterThan(result.samples.map { abs(Int($0)) }.max() ?? 0, 1_000)
        XCTAssertLessThanOrEqual(result.samples.map { abs(Int($0)) }.max() ?? 0, 30_000)
    }

    func testNearSilencePassesThroughAndLoudSpeechIsNotBoosted() {
        var gain = AdaptiveMicrophoneGain()

        XCTAssertEqual(gain.process([0, 20, -20, 0]).samples, [0, 20, -20, 0])
        XCTAssertEqual(gain.process([50, -50]).samples, [50, -50])
        XCTAssertGreaterThan(gain.process([200, -200]).appliedGain, 1)
        let loud = gain.process([10_000, -10_000])
        XCTAssertEqual(loud.appliedGain, 1)
        XCTAssertEqual(loud.samples, [10_000, -10_000])
    }

    func testTransmitPeakLimiterAndReset() {
        var gain = AdaptiveMicrophoneGain()
        let clippedRisk = gain.process([32_000, -32_000])
        XCTAssertLessThanOrEqual(clippedRisk.samples.map { abs(Int($0)) }.max() ?? 0, 30_000)

        gain.reset()
        let quietAfterReset = gain.process([200, -200])
        XCTAssertGreaterThan(quietAfterReset.appliedGain, 1)
    }

    func testAutomaticGainHasNoAbruptJumpAtNoiseFloor() {
        var prior = 1.0
        for level in 50...120 {
            var gain = AdaptiveMicrophoneGain()
            let value = Int16(level)
            let applied = gain.process([value, -value]).appliedGain
            XCTAssertLessThan(abs(applied - prior), 0.3, "Gain jump near RMS \(level)")
            prior = applied
        }
    }

    func testAutomaticGainRecoveryDependsOnAudioTimeInsteadOfCallbackSize() {
        var whole = AdaptiveMicrophoneGain()
        var chunked = AdaptiveMicrophoneGain()
        _ = whole.process([Int16](repeating: 400, count: 640))
        _ = chunked.process([Int16](repeating: 400, count: 640))
        let expected = whole.process([Int16](repeating: 200, count: 640)).appliedGain
        var actual = 0.0
        for _ in 0..<4 {
            actual = chunked.process([Int16](repeating: 200, count: 160)).appliedGain
        }
        XCTAssertEqual(actual, expected, accuracy: 0.000001)
    }

    func testManualMicrophoneGainAdjustsEncodedSamples() {
        XCTAssertEqual(MicrophoneGainSettings.apply([1_000, -1_000], multiplier: 0.5),
                       [500, -500])
        XCTAssertEqual(MicrophoneGainSettings.apply([1_000, -1_000], multiplier: 2),
                       [2_000, -2_000])
        XCTAssertEqual(MicrophoneGainSettings.apply([20_000, -20_000], multiplier: 4),
                       [30_000, -30_000])
    }

    func testAutomaticMicrophoneGainIsDefaultAndManualValueIsClamped() {
        let suite = "AudioEngineMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(MicrophoneGainSettings.mode(defaults: defaults), .automatic)
        XCTAssertEqual(MicrophoneGainSettings.load(defaults: defaults), 1)
        defaults.set(MicrophoneGainMode.manual.rawValue, forKey: MicrophoneGainSettings.modeKey)
        XCTAssertEqual(MicrophoneGainSettings.mode(defaults: defaults), .manual)
        defaults.set(10, forKey: MicrophoneGainSettings.key)
        XCTAssertEqual(MicrophoneGainSettings.load(defaults: defaults), 4)
        defaults.set(0, forKey: MicrophoneGainSettings.key)
        XCTAssertEqual(MicrophoneGainSettings.load(defaults: defaults), 0.25)
        defaults.set("unknown", forKey: MicrophoneGainSettings.modeKey)
        XCTAssertEqual(MicrophoneGainSettings.mode(defaults: defaults), .automatic)
    }
}
