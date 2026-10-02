// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class AudioEngineMeterTests: XCTestCase {
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
