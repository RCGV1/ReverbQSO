// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import Combine
@testable import ReverbQSO

final class AudioRoutePreferenceTests: XCTestCase {
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
