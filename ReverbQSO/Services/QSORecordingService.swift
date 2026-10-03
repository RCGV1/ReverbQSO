// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

/// Streams 8 kHz, mono, signed 16-bit PCM to disk. Silence between turns is
/// omitted; memory usage is bounded by one audio callback.
final class QSOAudioFileWriter {
    private var handle: FileHandle?
    private let maximumSamples: Int
    private(set) var sampleCount = 0
    var isAtLimit: Bool { sampleCount >= maximumSamples }
    init(url: URL, maximumSamples: Int = 8_000 * 3_600) throws {
        guard maximumSamples > 0, maximumSamples <= (Int(UInt32.max) - 36) / 2 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        self.maximumSamples = maximumSamples
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(samples: 0)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }
    func append(_ samples: [Int16]) throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        let count = min(samples.count, maximumSamples - sampleCount)
        guard count > 0 else { return }
        var data = Data(capacity: count * 2)
        for sample in samples.prefix(count) {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        try handle.write(contentsOf: data)
        sampleCount += count
    }
    func finish() throws {
        guard let file = handle else { return }
        handle = nil
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(44 + sampleCount * 2))
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Self.header(samples: sampleCount))
        try file.synchronize()
    }
    deinit { try? handle?.close() }
    private static func header(samples: Int) -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        func u16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        u32(UInt32(36 + samples * 2)); data.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(UInt32(samples * 2))
        return data
    }
}

enum QSORecordingKind: String, Codable {
    case clip
    case qso
}

struct QSORecording: Identifiable, Codable, Equatable {
    let id: UUID
    let callsign: String
    let startedAt: Date
    var duration: TimeInterval
    let url: URL
    let kind: QSORecordingKind

    init(id: UUID, callsign: String, startedAt: Date, duration: TimeInterval, url: URL,
         kind: QSORecordingKind = .qso) {
        self.id = id
        self.callsign = callsign
        self.startedAt = startedAt
        self.duration = duration
        self.url = url
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, callsign, startedAt, duration, url, kind
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        callsign = try values.decode(String.self, forKey: .callsign)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        url = try values.decode(URL.self, forKey: .url)
        kind = try values.decodeIfPresent(QSORecordingKind.self, forKey: .kind) ?? .qso
    }
}

@MainActor
final class QSORecordingService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recordings: [QSORecording] = []
    @Published private(set) var errorMessage: String?
    private let folder: URL
    private var writer: QSOAudioFileWriter?
    private var current: QSORecording?
    private var temporaryURL: URL?

    init(folder: URL? = nil, demo: Bool = false) {
        self.folder = folder ?? Self.storageFolder(demo: demo)
        reload()
    }
    static func storageFolder(demo: Bool = false) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReverbQSO/Recordings/\(demo ? "Demo" : "QSOs")", isDirectory: true)
    }
    func start(callsign: String, kind: QSORecordingKind = .qso) throws {
        guard !isRecording else { return }
        errorMessage = nil
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        let fileURL = folder.appendingPathComponent(id.uuidString + ".wav")
        let partial = folder.appendingPathComponent(id.uuidString + ".partial")
        writer = try QSOAudioFileWriter(url: partial)
        current = QSORecording(id: id, callsign: callsign, startedAt: Date(), duration: 0,
                               url: fileURL, kind: kind)
        temporaryURL = partial
        isRecording = true
    }
    func append(_ samples: [Int16]) {
        guard let writer else { return }
        do {
            try writer.append(samples)
            if writer.isAtLimit { errorMessage = "Recording stopped after one hour of audio."; stop() }
        } catch {
            errorMessage = "Could not write the recording: \(error.localizedDescription)"
            stop()
        }
    }
    func stop() {
        guard let writer, var recording = current, let partial = temporaryURL else { return }
        self.writer = nil; current = nil; temporaryURL = nil; isRecording = false
        do {
            try writer.finish()
            if writer.sampleCount == 0 { try FileManager.default.removeItem(at: partial); return }
            recording.duration = Double(writer.sampleCount) / 8_000
            try FileManager.default.moveItem(at: partial, to: recording.url)
            try JSONEncoder().encode(recording).write(to: recording.url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            reload()
        } catch {
            errorMessage = "Could not save the recording: \(error.localizedDescription)"
        }
    }
    func reload() {
        recordings = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), var item = try? JSONDecoder().decode(QSORecording.self, from: data) else { return nil }
                // Resolve inside our storage directory; app container paths change on upgrades.
                item = QSORecording(id: item.id, callsign: item.callsign, startedAt: item.startedAt,
                                    duration: item.duration, url: folder.appendingPathComponent(item.id.uuidString + ".wav"),
                                    kind: item.kind)
                return FileManager.default.fileExists(atPath: item.url.path) ? item : nil
            }.sorted { $0.startedAt > $1.startedAt }
    }
    func delete(_ recording: QSORecording) throws {
        guard recordings.contains(where: { $0.id == recording.id }) else { return }
        // IDs, rather than caller-provided paths, determine which files can be deleted.
        let url = folder.appendingPathComponent(recording.id.uuidString + ".wav")
        try FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
        reload()
    }
}
