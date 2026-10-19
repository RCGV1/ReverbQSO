// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class SessionRecordingTests: XCTestCase {
    func testAutomaticRecordingRecoveryClearsItsWarningButPreservesOtherAudioStatus() async throws {
        for otherStatus in [nil, "Microphone input is unavailable."] as [String?] {
            let suite = "recording-test-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: folder)
            }
            try Data().write(to: folder)
            defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey())
            let service = EchoLinkConnectionService(recordingDefaults: defaults, recordingFolder: folder)
            service.session = QSOSession(station: Station(callsign: "K6RETRY", ipAddress: "192.0.2.1"), state: .connected)
            XCTAssertTrue(try XCTUnwrap(service.audioStatusMessage).contains("recording"))
            if let otherStatus { service.audioStatusMessage = otherStatus }

            try FileManager.default.removeItem(at: folder)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            let deadline = Date().addingTimeInterval(2)
            while !service.isAutomaticallyRecording && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(service.isAutomaticallyRecording)
            XCTAssertEqual(service.audioStatusMessage, otherStatus)
            service.session = nil
        }
    }

    func testHubRetainsRecordingFailureAfterPrimaryAndSecondaryEntriesClose() async throws {
        let suite = "recording-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let engine = AudioEngine()
        let primary = EchoLinkConnectionService(audioEngine: engine,
            recordingDefaults: defaults, recordingFolder: folder)
        let relay = EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
        let hub = QSOHub(primary: primary, networkConfigurationProvider: { relay },
            connectOperation: { service, station in service.installSimulatorDemoSession(station: station) })
        _ = await hub.connect(to: Station(callsign: "K1PRIMARY", ipAddress: "192.0.2.1"), as: "N0FIRST")
        let secondary = await hub.connect(to: Station(callsign: "K2SECONDARY", ipAddress: "192.0.2.2"), as: "N0SECOND")
        let secondaryFailure = "Could not save the secondary recording."
        secondary.onRecordingFailure?(secondaryFailure)
        secondary.session = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(hub.entries.contains { $0.service === secondary })
        XCTAssertEqual(hub.recordingError, secondaryFailure)
        hub.recordingError = nil

        primary.toggleRecording()
        engine.onRecordingPCM?([100, -100])
        try FileManager.default.removeItem(at: folder)
        await primary.disconnect()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(hub.entries.isEmpty)
        XCTAssertTrue(try XCTUnwrap(hub.recordingError).localizedCaseInsensitiveContains("recording"))
        XCTAssertNil(primary.error)
        await hub.disconnectAll()
    }

    func testConnectedSessionRecordsMutedReceiveOnceAndIndependentClip() async throws {
        let suite = "recording-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey())
        let engine = AudioEngine()
        let service = EchoLinkConnectionService(audioEngine: engine, recordingDefaults: defaults, recordingFolder: folder)
        let station = Station(callsign: "K6TEST-R", ipAddress: "192.0.2.1", type: .repeater)
        service.session = QSOSession(station: station, state: .connecting)
        XCTAssertFalse(service.isAutomaticallyRecording)
        service.session?.state = .connected
        XCTAssertTrue(service.isAutomaticallyRecording)
        XCTAssertFalse(service.isRecording)
        engine.onRecordingPCM?([100, 200])
        service.toggleRecording()
        XCTAssertTrue(service.isRecording)
        service.setBackgroundMuted(true)
        let voice = Data([0xC0, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
            + Data(repeating: 0x80, count: 160)
        await service.handleAudioData(voice)
        await service.handleAudioData(voice)
        service.toggleRecording()
        XCTAssertFalse(service.isRecording)
        XCTAssertTrue(service.isAutomaticallyRecording)
        engine.onRecordingPCM?([300])
        service.session = nil
        XCTAssertFalse(service.isAutomaticallyRecording)
        XCTAssertNil(engine.onRecordingPCM)
        let recordings = QSORecordingService(folder: folder).recordings
        let full = try XCTUnwrap(recordings.first { $0.kind == .qso })
        let clip = try XCTUnwrap(recordings.first { $0.kind == .clip })
        XCTAssertEqual(recordings.count, 2)
        XCTAssertEqual(full.duration, 163.0 / 8000)
        XCTAssertEqual(clip.duration, 160.0 / 8000)
        XCTAssertEqual(try Data(contentsOf: full.url).count, 44 + 326)
        XCTAssertEqual(try Data(contentsOf: clip.url).count, 44 + 320)
    }

    func testLivePreferenceChangeStartsAutomaticRecordingWithoutEndingClip() async throws {
        let suite = "recording-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let engine = AudioEngine()
        let service = EchoLinkConnectionService(audioEngine: engine, recordingDefaults: defaults, recordingFolder: folder)
        service.session = QSOSession(station: Station(callsign: "K6TEST", ipAddress: "192.0.2.1"), state: .connected)
        XCTAssertFalse(service.isAutomaticallyRecording)
        service.toggleRecording()
        engine.onRecordingPCM?([100])
        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey())
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        let deadline = Date().addingTimeInterval(2)
        while !service.isAutomaticallyRecording && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(service.isAutomaticallyRecording)
        XCTAssertTrue(service.isRecording)
        engine.onRecordingPCM?([200])
        service.session = nil
        let recordings = QSORecordingService(folder: folder).recordings
        XCTAssertEqual(recordings.first { $0.kind == .clip }?.duration, 2.0 / 8000)
        XCTAssertEqual(recordings.first { $0.kind == .qso }?.duration, 1.0 / 8000)
    }

    func testClipSaveFailureOnDisconnectIsSurfacedThroughRecordingFailureCallback() async throws {
        let suite = "recording-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }

        let engine = AudioEngine()
        let service = EchoLinkConnectionService(
            audioEngine: engine,
            recordingDefaults: defaults,
            recordingFolder: folder
        )
        var recordingFailure: String?
        service.onRecordingFailure = { recordingFailure = $0 }
        service.session = QSOSession(
            station: Station(callsign: "K6SAVEFAIL", ipAddress: "192.0.2.1"),
            state: .connected
        )
        service.toggleRecording()
        engine.onRecordingPCM?([100, -100])
        try FileManager.default.removeItem(at: folder)

        await service.disconnect()

        let message = try XCTUnwrap(recordingFailure, "A failed clip save must remain visible after QSO teardown")
        XCTAssertTrue(message.localizedCaseInsensitiveContains("recording"))
        XCTAssertNil(service.error, "Recording failure should not be promoted to a connection error")
    }

    #if DEBUG
    func testIncomingCallStartsAutomaticRecordingOnlyAfterAnswerAndSavesOnStop() async throws {
        let suite = "recording-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey(demo: true))
        let engine = AudioEngine()
        let host = EchoLinkConferenceHostService(audioEngine: engine, recordingDefaults: defaults, recordingFolder: folder)
        host.installSimulatorDemoIncomingCall()
        XCTAssertNotNil(host.pendingCall)
        XCTAssertFalse(host.isAutomaticallyRecording)
        await host.acceptPendingCall()
        XCTAssertTrue(host.isAutomaticallyRecording)
        host.toggleRecording()
        engine.onRecordingPCM?([10, 20, 30])
        await host.stop()
        XCTAssertFalse(host.isRecording)
        XCTAssertFalse(host.isAutomaticallyRecording)
        XCTAssertNil(engine.onRecordingPCM)
        XCTAssertEqual(Set(QSORecordingService(folder: folder).recordings.map(\.kind)), [.qso, .clip])
    }
    #endif
}
