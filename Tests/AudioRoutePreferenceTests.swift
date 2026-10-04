// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import Combine
import AVFoundation
@testable import ReverbQSO

final class AudioRoutePreferenceTests: XCTestCase {
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
