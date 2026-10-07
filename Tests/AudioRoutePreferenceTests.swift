// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import Combine
import AVFoundation
@testable import ReverbQSO

final class AudioRoutePreferenceTests: XCTestCase {
    func testSystemA2DPRouteKeepsReceiveProfileUntilPTT() {
        var policy = AudioSessionRoutePolicy()
        policy.observeReceiveRoute(outputPortTypes: [.bluetoothA2DP], outputPreference: .system)

        XCTAssertTrue(policy.prefersHighQualityBluetoothReceive)
        XCTAssertEqual(policy.profile(captureRequested: false), .highQualityReceive)
        XCTAssertEqual(policy.profile(captureRequested: true), .voiceCapture)
        XCTAssertEqual(policy.profile(captureRequested: false), .highQualityReceive,
                       "The pre-PTT A2DP intent must survive the temporary HFP route")
    }

    func testSystemRouteLearnsA2DPAfterSpeakerOverrideIsRemoved() {
        var policy = AudioSessionRoutePolicy()
        policy.observeReceiveRoute(outputPortTypes: [.builtInSpeaker], outputPreference: .system)
        XCTAssertFalse(policy.prefersHighQualityBluetoothReceive)

        policy.observeIdleRouteChange(
            outputPortTypes: [.bluetoothA2DP],
            outputPreference: .system,
            removedDevice: false
        )

        XCTAssertEqual(policy.profile(captureRequested: false), .highQualityReceive)
    }

    func testTransientHFPRouteDoesNotEraseStickyA2DPButHeadsetRemovalDoes() {
        var policy = AudioSessionRoutePolicy()
        policy.observeReceiveRoute(outputPortTypes: [.bluetoothA2DP], outputPreference: .system)
        policy.observeIdleRouteChange(
            outputPortTypes: [.bluetoothHFP],
            outputPreference: .system,
            removedDevice: false
        )
        XCTAssertTrue(policy.prefersHighQualityBluetoothReceive)

        policy.observeIdleRouteChange(
            outputPortTypes: [.builtInSpeaker],
            outputPreference: .system,
            removedDevice: true
        )
        XCTAssertFalse(policy.prefersHighQualityBluetoothReceive)
    }

    func testDeferredMicrophoneEligibilitySurvivesPlaybackCategoryInputReport() {
        var eligibility = DeferredMicrophoneEligibility()
        eligibility.observeHardware(
            isInputAvailable: true,
            maximumInputChannels: 1,
            availableInputCount: 1,
            receiveOnlyCategory: false
        )
        eligibility.observeHardware(
            isInputAvailable: false,
            maximumInputChannels: 0,
            availableInputCount: 0,
            receiveOnlyCategory: true
        )
        XCTAssertTrue(eligibility.hasEligibleInput)

        eligibility.observeHardware(
            isInputAvailable: false,
            maximumInputChannels: 0,
            availableInputCount: 0,
            receiveOnlyCategory: false
        )
        XCTAssertTrue(eligibility.hasEligibleInput,
                      "A transient empty input report must not erase confirmed iPhone microphone hardware")
    }

    func testFirstPlaybackOnlyInputReportAllowsDeferredPTTAttempt() {
        var eligibility = DeferredMicrophoneEligibility()
        eligibility.observeHardware(
            isInputAvailable: false,
            maximumInputChannels: 0,
            availableInputCount: 0,
            receiveOnlyCategory: true
        )

        XCTAssertTrue(eligibility.hasEligibleInput,
                      "Playback category hides iPhone input capability; PTT must validate after switching category")
    }

    func testRecoveryAlwaysReplacesReceiveOnlyGraphWithoutRequestingCapture() {
        var policy = AudioSessionRoutePolicy()
        policy.observeReceiveRoute(outputPortTypes: [.bluetoothA2DP], outputPreference: .system)
        XCTAssertFalse(policy.shouldReplaceEngineGraph(rebuildRequested: false, captureRequested: false))
        XCTAssertTrue(policy.shouldReplaceEngineGraph(rebuildRequested: true, captureRequested: false))
        XCTAssertFalse(policy.shouldConfigureInputNode(captureRequested: false))
        XCTAssertTrue(policy.shouldConfigureInputNode(captureRequested: true))
    }

    func testExplicitSpeakerAndNonBluetoothRoutesKeepWarmCaptureProfile() {
        for (ports, preference) in [
            ([AVAudioSession.Port.bluetoothA2DP], AudioOutputPreference.speaker),
            ([AVAudioSession.Port.builtInSpeaker], AudioOutputPreference.system),
            ([AVAudioSession.Port.headphones], AudioOutputPreference.system),
        ] {
            var policy = AudioSessionRoutePolicy()
            policy.observeReceiveRoute(outputPortTypes: ports, outputPreference: preference)
            XCTAssertFalse(policy.prefersHighQualityBluetoothReceive)
            XCTAssertEqual(policy.profile(captureRequested: false), .warmCapture)
            XCTAssertEqual(policy.profile(captureRequested: true), .voiceCapture)
        }
    }

    @MainActor
    func testEngineUsesStickyA2DPIntentAcrossCaptureTransition() {
        let engine = AudioEngine()
        defer { engine.stopAll() }
        engine.auditObserveReceiveRoute(
            outputPortTypes: [.bluetoothA2DP],
            outputPreference: .system
        )

        XCTAssertEqual(engine.auditAudioSessionProfile(captureRequested: false), .highQualityReceive)
        XCTAssertEqual(engine.auditAudioSessionProfile(captureRequested: true), .voiceCapture)
        XCTAssertEqual(engine.auditAudioSessionProfile(captureRequested: false), .highQualityReceive)
    }

    @MainActor
    func testEngineLearnsAndRetiresIdleA2DPRoute() {
        let engine = AudioEngine()
        defer { engine.stopAll() }
        engine.auditObserveReceiveRoute(
            outputPortTypes: [.builtInSpeaker],
            outputPreference: .system
        )
        engine.auditObserveIdleRoute(
            outputPortTypes: [.bluetoothA2DP],
            outputPreference: .system,
            removedDevice: false
        )
        XCTAssertEqual(engine.auditAudioSessionProfile(captureRequested: false), .highQualityReceive)

        engine.auditObserveIdleRoute(
            outputPortTypes: [.builtInSpeaker],
            outputPreference: .system,
            removedDevice: true
        )
        XCTAssertEqual(engine.auditAudioSessionProfile(captureRequested: false), .warmCapture)
    }

    @MainActor
    func testEngineKeepsSpeakerOnWarmCaptureProfile() {
        let engine = AudioEngine()
        defer { engine.stopAll() }
        engine.auditObserveReceiveRoute(
            outputPortTypes: [.bluetoothA2DP],
            outputPreference: .speaker
        )

        XCTAssertEqual(engine.auditAudioSessionProfile(captureRequested: false), .warmCapture)
        XCTAssertEqual(engine.auditAudioSessionProfile(captureRequested: true), .voiceCapture)
    }

    func testSpeakerDefaultsSurviveRouteChangesWithoutForcingHeadphonesOff() {
        let options = AudioRoutePreferences.playAndRecordOptions(output: .speaker, allowsA2DP: false)
        XCTAssertTrue(options.contains(.defaultToSpeaker))
        XCTAssertTrue(options.contains(.allowBluetoothHFP))
        XCTAssertFalse(options.contains(.allowBluetoothA2DP))
        XCTAssertFalse(AudioRoutePreferences.playAndRecordOptions(output: .receiver, allowsA2DP: false).contains(.defaultToSpeaker))
        XCTAssertFalse(AudioRoutePreferences.playAndRecordOptions(output: .system, allowsA2DP: true).contains(.defaultToSpeaker))
        XCTAssertTrue(AudioRoutePreferences.playAndRecordOptions(output: .speaker, allowsA2DP: true).contains(.allowBluetoothA2DP))
    }

    func testNewRoutePreferenceUsesSpeakerOnPhoneAndSystemOnMac() throws {
        let suite = "AudioRoutePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #if targetEnvironment(macCatalyst)
        XCTAssertEqual(AudioRoutePreferences.defaultOutput, .system)
        #else
        XCTAssertEqual(AudioRoutePreferences.defaultOutput, .speaker)
        #endif
        XCTAssertEqual(AudioRoutePreferences.output(defaults: defaults), AudioRoutePreferences.defaultOutput)
        // Explicit choices must survive the new default.
        AudioRoutePreferences.save(output: .receiver, defaults: defaults)
        XCTAssertEqual(AudioRoutePreferences.output(defaults: defaults), .receiver)
        AudioRoutePreferences.save(output: .system, defaults: defaults)
        XCTAssertEqual(AudioRoutePreferences.output(defaults: defaults), .system)
    }

    @MainActor func testMultipleEnginesRefreshSharedMicrophoneSelection() async {
        let oldInput = AudioRoutePreferences.inputUID()
        defer { AudioRoutePreferences.save(inputUID: oldInput) }
        let first = AudioEngine(), second = AudioEngine()
        let updated = expectation(description: "Other QSO updates microphone selection")
        let subscription = second.$selectedInputDeviceID
            .filter { $0 == "test-shared-microphone" }.prefix(1)
            .sink { _ in updated.fulfill() }
        first.setInputDevice(id: "test-shared-microphone")
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(second.selectedInputDeviceID, first.selectedInputDeviceID)
        withExtendedLifetime(subscription) {}
    }

    func testRouteChoicesRoundTripAndAutomaticInputClearsSavedDevice() throws {
        let suite = "AudioRoutePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        AudioRoutePreferences.save(output: .system, defaults: defaults)
        AudioRoutePreferences.save(inputUID: "usb-microphone", defaults: defaults)
        XCTAssertEqual(AudioRoutePreferences.output(defaultValue: .speaker, defaults: defaults), .system)
        XCTAssertEqual(AudioRoutePreferences.inputUID(defaults: defaults), "usb-microphone")

        AudioRoutePreferences.save(inputUID: nil, defaults: defaults)
        XCTAssertNil(AudioRoutePreferences.inputUID(defaults: defaults))
    }

    func testUnknownSavedOutputUsesPlatformDefault() throws {
        let suite = "AudioRoutePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-route", forKey: AudioRoutePreferences.outputKey)

        XCTAssertEqual(AudioRoutePreferences.output(defaultValue: .receiver, defaults: defaults), .receiver)
    }
}
