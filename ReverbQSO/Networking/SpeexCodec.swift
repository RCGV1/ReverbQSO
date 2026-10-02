// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// EchoLink's four-frame, 8 kHz narrowband Speex receive codec.
/// Each packet contains one packed bitstream, not byte-aligned individual frames.
final class SpeexCodec {
    static let samplesPerPacket = 640
    private let decoder: UnsafeMutableRawPointer?
    private let lock = NSLock()

    init() { decoder = oe_speex_create() }
    deinit { oe_speex_destroy(decoder) }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        oe_speex_reset(decoder)
    }

    /// Reject the entire datagram on corruption; never retain partial packet bytes.
    func decodePacket(_ payload: Data) -> [Int16]? {
        guard !payload.isEmpty, payload.count <= 512 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var output = [Int16](repeating: 0, count: Self.samplesPerPacket)
        let count = payload.withUnsafeBytes { bytes in
            output.withUnsafeMutableBufferPointer { samples in
                oe_speex_decode(decoder, bytes.bindMemory(to: UInt8.self).baseAddress,
                                payload.count, samples.baseAddress)
            }
        }
        return count == Self.samplesPerPacket ? output : nil
    }
}
