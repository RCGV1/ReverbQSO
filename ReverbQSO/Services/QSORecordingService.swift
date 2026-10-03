// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

/// Streams 8 kHz, mono, signed 16-bit PCM to disk. Silence between turns is
/// omitted; memory usage is bounded by one audio callback.
final class QSOAudioFileWriter {
    private var handle: FileHandle?
    private let maximumSamples: Int
    private let writeSamples: (FileHandle, Data) throws -> Void
    private(set) var sampleCount = 0
    var isAtLimit: Bool { sampleCount >= maximumSamples }
    var remainingCapacity: Int { maximumSamples - sampleCount }
    init(url: URL, maximumSamples: Int = 8_000 * 3_600,
         writeSamples: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws {
        guard maximumSamples > 0, maximumSamples <= (Int(UInt32.max) - 36) / 2 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        self.maximumSamples = maximumSamples
        self.writeSamples = writeSamples
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(samples: 0)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }
    @discardableResult
    func append(_ samples: [Int16]) throws -> Int {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        let count = min(samples.count, remainingCapacity)
        guard count > 0 else { return 0 }
        var data = Data(capacity: count * 2)
        for sample in samples.prefix(count) {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        try writeSamples(handle, data)
        sampleCount += count
        return count
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
    private static let recordingsChanged = Notification.Name("QSORecordingService.recordingsChanged")
    @Published private(set) var isRecording = false
    @Published private(set) var recordings: [QSORecording] = []
    @Published private(set) var errorMessage: String?
    private let folder: URL
    private let maximumSamples: Int
    private let rotatesAtLimit: Bool
    private let writeSamples: (FileHandle, Data) throws -> Void
    private var writer: QSOAudioFileWriter?
    private var current: QSORecording?
    private var temporaryURL: URL?
    private var recordingsChangedObserver: AnyCancellable?

    init(folder: URL? = nil, demo: Bool = false,
         maximumSamples: Int = 8_000 * 3_600, rotatesAtLimit: Bool = false,
         writeSamples: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) {
        self.folder = folder ?? Self.storageFolder(demo: demo)
        self.maximumSamples = maximumSamples
        self.rotatesAtLimit = rotatesAtLimit
        self.writeSamples = writeSamples
        reload()
        recordingsChangedObserver = NotificationCenter.default.publisher(for: Self.recordingsChanged)
            .sink { [weak self] notification in
                guard let self,
                      notification.object as? String == self.folder.standardizedFileURL.path else { return }
                self.reload()
            }
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
        do {
            writer = try QSOAudioFileWriter(url: partial, maximumSamples: maximumSamples, writeSamples: writeSamples)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        current = QSORecording(id: id, callsign: callsign, startedAt: Date(), duration: 0,
                               url: fileURL, kind: kind)
        temporaryURL = partial
        isRecording = true
    }
    func append(_ samples: [Int16]) {
        var offset = 0
        while offset < samples.count, let writer {
            do {
                offset += try writer.append(Array(samples[offset...]))
                guard writer.isAtLimit else { return }
                guard rotatesAtLimit, let recording = current else {
                    errorMessage = "Recording stopped after one hour of audio."
                    stop()
                    return
                }
                let callsign = recording.callsign
                let kind = recording.kind
                try finishCurrentRecording()
                try start(callsign: callsign, kind: kind)
            } catch {
                errorMessage = "Could not write the recording: \(error.localizedDescription)"
                if self.writer === writer {
                    // A failed callback may have written only part of its
                    // bytes. Finish truncates to the confirmed sample count,
                    // preserving earlier speech while stopping further writes.
                    stop()
                } else {
                    discardCurrentRecording()
                }
                return
            }
        }
    }
    func stop() {
        guard writer != nil else { return }
        do {
            try finishCurrentRecording()
        } catch {
            errorMessage = "Could not save the recording: \(error.localizedDescription)"
            discardCurrentRecording()
        }
    }

    private func finishCurrentRecording() throws {
        guard let writer, var recording = current, let partial = temporaryURL else { return }
        self.writer = nil; current = nil; temporaryURL = nil; isRecording = false
        let metadataURL = recording.url.deletingPathExtension().appendingPathExtension("json")
        let temporaryMetadataURL = metadataURL.appendingPathExtension("partial")
        do {
            try writer.finish()
            guard writer.sampleCount > 0 else {
                try FileManager.default.removeItem(at: partial)
                return
            }
            recording.duration = Double(writer.sampleCount) / 8_000
            try JSONEncoder().encode(recording).write(to: temporaryMetadataURL, options: .atomic)
            try FileManager.default.moveItem(at: partial, to: recording.url)
            try FileManager.default.moveItem(at: temporaryMetadataURL, to: metadataURL)
            notifyRecordingsChanged()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: temporaryMetadataURL)
            try? FileManager.default.removeItem(at: recording.url)
            try? FileManager.default.removeItem(at: metadataURL)
            throw error
        }
    }

    private func discardCurrentRecording() {
        let partial = temporaryURL
        writer = nil; current = nil; temporaryURL = nil; isRecording = false
        if let partial { try? FileManager.default.removeItem(at: partial) }
    }

    private func notifyRecordingsChanged() {
        NotificationCenter.default.post(name: Self.recordingsChanged,
                                        object: folder.standardizedFileURL.path)
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
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { /* Audio was already removed. */ }
        let metadata = url.deletingPathExtension().appendingPathExtension("json")
        do { try FileManager.default.removeItem(at: metadata) }
        catch CocoaError.fileNoSuchFile { /* Metadata was already removed. */ }
        notifyRecordingsChanged()
    }
}
