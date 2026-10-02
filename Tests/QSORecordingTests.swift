// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class QSORecordingTests: XCTestCase {
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
}
