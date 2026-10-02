// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Temporary, bounded diagnostics for physical-device voice bring-up.
///
/// The file contains state transitions and counters only. It never records
/// audio samples, station identities, peer addresses, chat, or credentials.
enum VoiceDiagnosticLog {
    private static let queue = DispatchQueue(label: "org.reverbqso.app.voice-diagnostic")
    private static let maximumBytes: UInt64 = 64 * 1024
    private static let fileURL: URL? = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("voice-diagnostic.log", isDirectory: false)
    }()

    static func reset() {
        queue.async {
            guard let fileURL else { return }
            try? Data().write(to: fileURL, options: .atomic)
            append("diagnostic reset", to: fileURL)
        }
    }

    static func record(_ message: String) {
        queue.async {
            guard let fileURL else { return }
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               UInt64(size) >= maximumBytes {
                try? Data().write(to: fileURL, options: .atomic)
                append("diagnostic rolled over", to: fileURL)
            }
            append(message, to: fileURL)
        }
    }

    private static func append(_ message: String, to fileURL: URL) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }
}
