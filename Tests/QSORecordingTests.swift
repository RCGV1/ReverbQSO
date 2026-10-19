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

    @MainActor func testDeletionCleansMetadataWhenAudioWasAlreadyRemoved() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = QSORecordingService(folder: folder)
        try recorder.start(callsign: "K6MISSING")
        recorder.append([1])
        recorder.stop()
        let item = try XCTUnwrap(recorder.recordings.first)
        try FileManager.default.removeItem(at: item.url)
        XCTAssertNoThrow(try recorder.delete(item))
        XCTAssertTrue(recorder.recordings.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty)
    }

    @MainActor func testAutomaticModeRotatesWithoutDroppingCallbackSamples() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = QSORecordingService(folder: folder, maximumSamples: 3, rotatesAtLimit: true)
        try recorder.start(callsign: "K6ROTATE")

        recorder.append([1, 2, 3, 4, 5, 6, 7])
        recorder.stop()

        let recordings = recorder.recordings.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(recordings.map(\.duration), [3.0 / 8_000, 3.0 / 8_000, 1.0 / 8_000])
        let samples = try recordings.flatMap { recording -> [Int16] in
            let data = try Data(contentsOf: recording.url).dropFirst(44)
            return stride(from: 0, to: data.count, by: 2).map { offset in
                Int16(bitPattern: UInt16(data[data.startIndex + offset]) |
                    UInt16(data[data.startIndex + offset + 1]) << 8)
            }
        }
        XCTAssertEqual(samples, [1, 2, 3, 4, 5, 6, 7])
    }

    @MainActor func testFinishedRecordingRefreshesOtherServiceInstances() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = QSORecordingService(folder: folder)
        let recorder = QSORecordingService(folder: folder)

        try recorder.start(callsign: "K6LIST")
        recorder.append([1])
        recorder.stop()

        XCTAssertEqual(list.recordings.count, 1)
        try recorder.delete(try XCTUnwrap(recorder.recordings.first))
        XCTAssertTrue(list.recordings.isEmpty)
    }

    @MainActor func testFailedSaveCleansUpTemporaryAndOrphanedFiles() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = QSORecordingService(folder: folder)
        try recorder.start(callsign: "K6FAIL")
        recorder.append([1])
        let partial = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "partial" }))
        let metadataTemporary = folder.appendingPathComponent(partial.deletingPathExtension().lastPathComponent + ".json.partial")
        try FileManager.default.createDirectory(at: metadataTemporary, withIntermediateDirectories: true)

        recorder.stop()

        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty)
    }

    @MainActor func testPartialWriteFailureSavesConfirmedAudioAndStopsRetrying() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var writes = 0
        let recorder = QSORecordingService(folder: folder, rotatesAtLimit: true) { handle, data in
            writes += 1
            if writes == 2 {
                try handle.write(contentsOf: data.prefix(1))
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try handle.write(contentsOf: data)
        }
        try recorder.start(callsign: "K6DISK")
        recorder.append([0x1234, -2])
        recorder.append([99, 100])
        recorder.append([101])
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertEqual(writes, 2)
        let saved = try XCTUnwrap(recorder.recordings.first)
        XCTAssertEqual(saved.duration, 2.0 / 8_000)
        let bytes = try Data(contentsOf: saved.url)
        XCTAssertEqual(bytes.count, 48)
        XCTAssertEqual(Array(bytes.suffix(4)), [0x34, 0x12, 0xfe, 0xff])
        XCTAssertEqual(Array(bytes[40..<44]), [4, 0, 0, 0])
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

    @MainActor func testAutomaticRecordingRetriesAfterStartFailureWithoutStartingNewSession() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(FileManager.default.createFile(atPath: folder.path, contents: Data()))
        let suite = "QSORecordingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey())
        let coordinator = QSORecordingCoordinator(folder: folder, defaults: defaults)

        coordinator.startSession(callsign: "K6RETRY")
        XCTAssertFalse(coordinator.isAutomaticallyRecording)

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        coordinator.refreshAutomaticRecording()

        XCTAssertTrue(coordinator.isAutomaticallyRecording,
                      "Always Record should retry after its storage becomes available during the same session")
        XCTAssertNil(coordinator.errorMessage)
        coordinator.stopSession()
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

    @MainActor func testAutomaticRetryDoesNotClearLaterClipStartError() throws {
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
        coordinator.toggleClip()
        let clipError = try XCTUnwrap(coordinator.errorMessage)
        XCTAssertTrue(clipError.contains("clip"))

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        coordinator.refreshAutomaticRecording()
        XCTAssertTrue(coordinator.isAutomaticallyRecording)
        XCTAssertEqual(coordinator.errorMessage, clipError)
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
