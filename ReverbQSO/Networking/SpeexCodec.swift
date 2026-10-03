// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// EchoLink's four-frame, 8 kHz narrowband Speex receive codec.
/// Each packet contains one packed bitstream, not byte-aligned individual frames.
final class SpeexCodec {
    static let samplesPerPacket = 640
    private static let maximumPacketBytes = 512
    private let decoder: UnsafeMutableRawPointer?
    private let encoder: UnsafeMutableRawPointer?
    private let lock = NSLock()
    private var encoderReady: Bool
    private var pendingEncodingSamples: [Int16] = []

    init() {
        decoder = oe_speex_create()
        encoder = oe_speex_encoder_create()
        encoderReady = encoder != nil
        pendingEncodingSamples.reserveCapacity(Self.samplesPerPacket)
    }

    deinit {
        oe_speex_destroy(decoder)
        oe_speex_encoder_destroy(encoder)
    }

    var isEncoderAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return encoderReady
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        oe_speex_reset(decoder)
        resetEncodingLocked()
    }

    func resetEncoding() {
        lock.lock()
        defer { lock.unlock() }
        resetEncodingLocked()
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

    /// Advances receive state and synthesizes 20 ms frames for a bounded packet gap.
    func concealMissingSamples(_ sampleCount: Int) -> [Int16]? {
        guard sampleCount > 0, sampleCount <= 1_280, sampleCount.isMultiple(of: 160) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        var output = [Int16](repeating: 0, count: sampleCount)
        let count = output.withUnsafeMutableBufferPointer { samples in
            oe_speex_conceal(decoder, sampleCount / 160, samples.baseAddress, samples.count)
        }
        return count == sampleCount ? output : nil
    }

    /// Buffers incomplete input and emits one packet for each complete 640-sample block.
    /// An empty result means more samples are needed; nil means the encoder is unavailable.
    func encode(_ samples: [Int16]) -> [Data]? {
        lock.lock()
        defer { lock.unlock() }
        guard encoderReady else { return nil }

        var packets: [Data] = []
        var offset = 0

        if !pendingEncodingSamples.isEmpty {
            let copied = min(Self.samplesPerPacket - pendingEncodingSamples.count, samples.count)
            pendingEncodingSamples.append(contentsOf: samples.prefix(copied))
            offset = copied
            if pendingEncodingSamples.count == Self.samplesPerPacket {
                guard let packet = encodePacket(pendingEncodingSamples) else {
                    recoverEncoderAfterFailure()
                    return nil
                }
                packets.append(packet)
                pendingEncodingSamples.removeAll(keepingCapacity: true)
            }
        }

        while samples.count - offset >= Self.samplesPerPacket {
            let end = offset + Self.samplesPerPacket
            guard let packet = samples.withUnsafeBufferPointer({ buffer in
                encodePacket(UnsafeBufferPointer(rebasing: buffer[offset..<end]))
            }) else {
                recoverEncoderAfterFailure()
                return nil
            }
            packets.append(packet)
            offset = end
        }

        if offset < samples.count {
            pendingEncodingSamples.append(contentsOf: samples[offset...])
        }
        return packets
    }

    /// Pads a final short packet with silence at the end of a transmission.
    func flushEncoding() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard encoderReady, !pendingEncodingSamples.isEmpty else { return nil }
        pendingEncodingSamples.append(contentsOf: repeatElement(
            0, count: Self.samplesPerPacket - pendingEncodingSamples.count
        ))
        guard let packet = encodePacket(pendingEncodingSamples) else {
            recoverEncoderAfterFailure()
            return nil
        }
        pendingEncodingSamples.removeAll(keepingCapacity: true)
        return packet
    }

    private func encodePacket(_ samples: [Int16]) -> Data? {
        samples.withUnsafeBufferPointer(encodePacket)
    }

    private func encodePacket(_ samples: UnsafeBufferPointer<Int16>) -> Data? {
        guard samples.count == Self.samplesPerPacket else { return nil }
        var bytes = [UInt8](repeating: 0, count: Self.maximumPacketBytes)
        let count = bytes.withUnsafeMutableBufferPointer { output in
            oe_speex_encode(encoder, samples.baseAddress, samples.count,
                            output.baseAddress, output.count)
        }
        guard count > 0, count <= bytes.count else { return nil }
        return Data(bytes.prefix(Int(count)))
    }

    private func resetEncodingLocked() {
        pendingEncodingSamples.removeAll(keepingCapacity: true)
        encoderReady = oe_speex_encoder_reset(encoder) == 1
    }

    private func recoverEncoderAfterFailure() {
        pendingEncodingSamples.removeAll(keepingCapacity: true)
        encoderReady = oe_speex_encoder_reset(encoder) == 1
    }
}
