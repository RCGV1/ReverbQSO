// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class QSORecordingTests: XCTestCase {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testWAVHeaderAndSampleByteOrderMatchWrittenAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("voice.wav")
        let writer = try QSOAudioFileWriter(url: url, maximumSamples: 8_000)
        try writer.append([0x1234, -2, 32767, -32768])
        try writer.finish()
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 52)
        XCTAssertEqual(String(data: bytes.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(Array(bytes[24..<28]), [0x40, 0x1f, 0, 0])
        XCTAssertEqual(Array(bytes[40..<44]), [8, 0, 0, 0])
        XCTAssertEqual(Array(bytes[44..<52]), [0x34, 0x12, 0xfe, 0xff, 0xff, 0x7f, 0, 0x80])
        XCTAssertThrowsError(try writer.append([1]))
    }

    func testRecordingLimitCannotGrowFileIndefinitely() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try QSOAudioFileWriter(url: url, maximumSamples: 3)
        try writer.append([1, 2, 3, 4, 5])
        XCTAssertEqual(writer.sampleCount, 3)
        XCTAssertTrue(writer.isAtLimit)
        try writer.finish()
        XCTAssertEqual(try Data(contentsOf: url).count, 50)
    }

    @MainActor func testFinishedRecordingsCanBeListedAndDeleted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = QSORecordingService(folder: folder)
        try recorder.start(callsign: "../../KO6CNT-R")
        recorder.append([1000, -1000, 4000, -4000])
        recorder.stop()
        let recording = try XCTUnwrap(recorder.recordings.first)
        XCTAssertTrue(recording.url.path.hasPrefix(folder.path + "/"))
        XCTAssertEqual(recording.duration, 4.0 / 8000)
        let reloaded = QSORecordingService(folder: folder)
        XCTAssertEqual(reloaded.recordings.count, 1)
        try reloaded.delete(recording)
        XCTAssertTrue(reloaded.recordings.isEmpty)
    }

    @MainActor func testEmptyRecordingIsDiscarded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = QSORecordingService(folder: folder)
        try recorder.start(callsign: "K6TEST")
        recorder.stop()
        XCTAssertTrue(recorder.recordings.isEmpty)
    }

    @MainActor func testAutomaticRecordingDefaultsOffAndDemoPreferenceIsIsolated() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "QSORecordingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initiallyOff = QSORecordingCoordinator(folder: folder, defaults: defaults)
        initiallyOff.startSession(callsign: "K6OFF")
        XCTAssertFalse(initiallyOff.isAutomaticallyRecording)
        initiallyOff.stopSession()

        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey(demo: false))

        let live = QSORecordingCoordinator(folder: folder, defaults: defaults)
        live.startSession(callsign: "K6LIVE")
        XCTAssertTrue(live.isAutomaticallyRecording)

        let demo = QSORecordingCoordinator(folder: folder, demo: true, defaults: defaults)
        demo.startSession(callsign: "K6DEMO")
        XCTAssertFalse(demo.isAutomaticallyRecording)
    }

    @MainActor func testManualClipRecordsOnlySamplesBetweenClipBoundaries() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "QSORecordingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = QSORecordingCoordinator(folder: folder, defaults: defaults)
        coordinator.startSession(callsign: "K6TEST")
        coordinator.append([1, 2])
        coordinator.toggleClip()
        coordinator.append([3, 4, 5])
        coordinator.toggleClip()
        coordinator.append([6])

        let clip = try XCTUnwrap(QSORecordingService(folder: folder).recordings.first(where: { $0.kind == .clip }))
        XCTAssertEqual(clip.kind, .clip)
        XCTAssertEqual(clip.duration, 3.0 / 8_000)
    }

    @MainActor func testAutomaticAndManualRecordingsCanRunTogether() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "QSORecordingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey())
        let coordinator = QSORecordingCoordinator(folder: folder, defaults: defaults)

        coordinator.startSession(callsign: "K6TEST")
        coordinator.append([1, 2])
        coordinator.toggleClip()
        coordinator.append([3, 4, 5])
        coordinator.toggleClip()
        coordinator.append([6])
        coordinator.stopSession()

        let recordings = QSORecordingService(folder: folder).recordings
        XCTAssertEqual(recordings.first(where: { $0.kind == .qso })?.duration, 6.0 / 8_000)
        XCTAssertEqual(recordings.first(where: { $0.kind == .clip })?.duration, 3.0 / 8_000)
    }

    @MainActor func testDisablingAutomaticRecordingLeavesManualClipRunning() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "QSORecordingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = RecordingPreferences.alwaysRecordKey()
        defaults.set(true, forKey: key)
        let coordinator = QSORecordingCoordinator(folder: folder, defaults: defaults)
        coordinator.startSession(callsign: "K6TEST")
        coordinator.toggleClip()
        coordinator.append([1, 2])

        defaults.set(false, forKey: key)
        coordinator.refreshAutomaticRecording()
        XCTAssertFalse(coordinator.isAutomaticallyRecording)
        XCTAssertTrue(coordinator.isRecordingClip)
        coordinator.append([3, 4])
        coordinator.stopSession()

        let recordings = QSORecordingService(folder: folder).recordings
        XCTAssertEqual(recordings.first(where: { $0.kind == .qso })?.duration, 2.0 / 8_000)
        XCTAssertEqual(recordings.first(where: { $0.kind == .clip })?.duration, 4.0 / 8_000)
    }

    @MainActor func testStoppingSessionFinishesBothRecordingsAndClearsState() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "QSORecordingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey())
        let coordinator = QSORecordingCoordinator(folder: folder, defaults: defaults)
        coordinator.startSession(callsign: "K6TEST")
        coordinator.toggleClip()
        coordinator.append([1])

        coordinator.stopSession()

        XCTAssertFalse(coordinator.isRecordingClip)
        XCTAssertFalse(coordinator.isAutomaticallyRecording)
        XCTAssertEqual(QSORecordingService(folder: folder).recordings.count, 2)
    }

    @MainActor func testFailedAutomaticStartDoesNotRetryUntilPreferenceChanges() throws {
        let folder = temporaryFolder()
        try Data().write(to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "QSORecordingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = RecordingPreferences.alwaysRecordKey()
        defaults.set(true, forKey: key)
        let coordinator = QSORecordingCoordinator(folder: folder, defaults: defaults)

        coordinator.startSession(callsign: "K6TEST")
        XCTAssertFalse(coordinator.isAutomaticallyRecording)
        XCTAssertNotNil(coordinator.errorMessage)

        try FileManager.default.removeItem(at: folder)
        coordinator.refreshAutomaticRecording()
        XCTAssertFalse(coordinator.isAutomaticallyRecording)

        defaults.set(false, forKey: key)
        coordinator.refreshAutomaticRecording()
        defaults.set(true, forKey: key)
        coordinator.refreshAutomaticRecording()
        XCTAssertTrue(coordinator.isAutomaticallyRecording)
        coordinator.stopSession()
    }

    @MainActor func testLegacyMetadataDecodesAsQSOAndKeepsKindWhenURLIsRewritten() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        let legacyURL = URL(fileURLWithPath: "/old/container/\(id.uuidString).wav")
        let encoder = JSONEncoder()
        let recording = QSORecording(id: id, callsign: "K6OLD", startedAt: Date(timeIntervalSince1970: 1_000), duration: 1, url: legacyURL, kind: .qso)
        var object = try JSONSerialization.jsonObject(with: encoder.encode(recording)) as! [String: Any]
        object.removeValue(forKey: "kind")
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent(id.uuidString + ".json"))
        FileManager.default.createFile(atPath: folder.appendingPathComponent(id.uuidString + ".wav").path, contents: Data())

        let service = QSORecordingService(folder: folder)
        let loaded = try XCTUnwrap(service.recordings.first)
        XCTAssertEqual(loaded.kind, .qso)
        XCTAssertEqual(loaded.url, folder.appendingPathComponent(id.uuidString + ".wav"))
    }
}
