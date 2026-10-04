// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Protocol for audio codecs used in EchoLink communication.
///
/// EchoLink uses GSM 06.10 Full Rate encoding:
/// - 8 kHz sample rate
/// - 160 samples per frame
/// - Each encoded frame is 33 bytes
/// - Audio packets have a 4-byte header: 0xBE 0xEF 0xBE 0xEF
protocol AudioCodec {
    /// Encode PCM samples into the codec's compressed format.
    func encode(_ pcm: [Int16]) -> Data

    /// Decode compressed data back into PCM samples.
    func decode(_ data: Data) -> [Int16]
}

/// GSM 06.10 Full Rate codec backed by native libgsm.
///
/// EchoLink audio packet format:
/// `[0xBE][0xEF][0xBE][0xEF][33-byte GSM frame][33-byte GSM frame]...`
final class GSMCodec: AudioCodec {
    /// Indicates this build uses a placeholder codec implementation.
    static let isStubImplementation = false

    /// The magic header bytes that prefix every EchoLink audio UDP packet.
    static let packetHeader: [UInt8] = [0xBE, 0xEF, 0xBE, 0xEF]

    /// Number of PCM samples per GSM frame (20 ms at 8 kHz).
    static let samplesPerFrame = 160

    /// Size in bytes of a single encoded GSM 06.10 frame.
    static let encodedFrameSize = 33

    /// Sample rate in Hz.
    static let sampleRate = 8000

    private let logger = Logger(subsystem: "org.reverbqso.app", category: "GSMCodec")
    private var encoder: gsm?
    private var decoder: gsm?
    private var encodeRemainder: [Int16] = []
    private var decodeRemainder: [UInt8] = []
    private let encodeLock = NSLock()
    private let decodeLock = NSLock()

    init() {
        self.encoder = gsm_create()
        self.decoder = gsm_create()

        // EchoLink uses standard GSM 06.10 (not WAV49).
        // gsm_create() defaults to standard mode, so no options needed.

        if encoder == nil {
            logger.error("Failed to create GSM encoder state — gsm_create() returned NULL")
        }
        if decoder == nil {
            logger.error("Failed to create GSM decoder state — gsm_create() returned NULL")
        }
    }

    deinit {
        if let encoder { gsm_destroy(encoder) }
        if let decoder { gsm_destroy(decoder) }
    }

    /// Encode PCM samples into GSM 06.10 format.
    ///
    func encode(_ pcm: [Int16]) -> Data {
        guard !pcm.isEmpty else { return Data() }

        encodeLock.lock()
        defer { encodeLock.unlock() }
        guard let encoder else { return Data() }

        encodeRemainder.append(contentsOf: pcm)

        var payload = Data()
        var cursor = 0
        while encodeRemainder.count - cursor >= Self.samplesPerFrame {
            let frameSamples = encodeRemainder[cursor..<(cursor + Self.samplesPerFrame)]
            cursor += Self.samplesPerFrame

            var inFrame = frameSamples.map { sample in
                gsm_signal(sample)
            }
            var outFrame = [gsm_byte](repeating: 0, count: Self.encodedFrameSize)

            inFrame.withUnsafeMutableBufferPointer { inBuffer in
                outFrame.withUnsafeMutableBufferPointer { outBuffer in
                    gsm_encode(encoder, inBuffer.baseAddress, outBuffer.baseAddress)
                }
            }
            payload.append(contentsOf: outFrame)
        }

        if cursor > 0 {
            encodeRemainder = Array(encodeRemainder[cursor...])
        }

        guard !payload.isEmpty else { return Data() }
        var packet = Data(Self.packetHeader)
        packet.append(payload)
        return packet
    }

    /// Decode GSM 06.10 data back into PCM samples.
    ///
    /// This method accumulates partial frames across calls via `decodeRemainder`.
    /// Use `decodePacket(_:)` for network packets that should be decoded independently.
    func decode(_ data: Data) -> [Int16] {
        guard !data.isEmpty else { return [] }

        decodeLock.lock()
        defer { decodeLock.unlock() }
        guard let decoder else { return [] }

        let payload = Self.stripHeader(data) ?? data
        decodeRemainder.append(contentsOf: payload)

        return decodeRemainder_locked(decoder: decoder)
    }

    /// Decode a self-contained network packet of GSM 06.10 data.
    ///
    /// Unlike `decode(_:)`, this method discards any leftover partial frame
    /// bytes from prior calls. Each UDP datagram is self-contained, so carrying
    /// partial frames across packets corrupts audio after packet loss or reordering.
    func decodePacket(_ data: Data) -> [Int16] {
        guard !data.isEmpty else { return [] }

        decodeLock.lock()
        defer { decodeLock.unlock() }
        guard let decoder else { return [] }

        let payload = Self.stripHeader(data) ?? data

        // Discard stale partial frame from previous packet.
        if !decodeRemainder.isEmpty {
            logger.debug("Discarding \(self.decodeRemainder.count) stale decode remainder bytes")
            decodeRemainder.removeAll(keepingCapacity: true)
        }

        decodeRemainder.append(contentsOf: payload)
        return decodeRemainder_locked(decoder: decoder)
    }

    /// Internal: drain full frames from `decodeRemainder`. Caller must hold `decodeLock`.
    private func decodeRemainder_locked(decoder: gsm) -> [Int16] {
        var decodedSamples: [Int16] = []
        var cursor = 0
        while decodeRemainder.count - cursor >= Self.encodedFrameSize {
            let frameBytes = decodeRemainder[cursor..<(cursor + Self.encodedFrameSize)]
            cursor += Self.encodedFrameSize

            var inFrame = frameBytes.map { byte in
                gsm_byte(byte)
            }
            var outFrame = [gsm_signal](repeating: 0, count: Self.samplesPerFrame)

            let status: Int32 = inFrame.withUnsafeMutableBufferPointer { inBuffer in
                outFrame.withUnsafeMutableBufferPointer { outBuffer in
                    gsm_decode(decoder, inBuffer.baseAddress, outBuffer.baseAddress)
                }
            }

            if status == 0 {
                decodedSamples.append(contentsOf: outFrame.map { sample in
                    Int16(sample)
                })
            } else {
                logger.error("gsm_decode failed with status=\(status)")
            }
        }

        if cursor > 0 {
            decodeRemainder = Array(decodeRemainder[cursor...])
        }

        return decodedSamples
    }

    /// Wrap raw encoded GSM frames with the EchoLink audio packet header.
    static func wrapWithHeader(_ gsmData: Data) -> Data {
        var packet = Data(packetHeader)
        packet.append(gsmData)
        return packet
    }

    /// Strip the EchoLink audio packet header, returning only GSM frame data.
    static func stripHeader(_ packet: Data) -> Data? {
        guard packet.count >= 4 else { return nil }
        let header = [UInt8](packet.prefix(4))
        guard header == packetHeader else { return nil }
        return packet.dropFirst(4).asData
    }

    // MARK: - State Management

    /// Clear partial samples and reset the native encoder predictor history.
    ///
    /// Call between PTT sessions so stale partial frames don't leak
    /// into the next transmission.
    func resetEncodeState() {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        encodeRemainder.removeAll(keepingCapacity: true)
        if let encoder { gsm_destroy(encoder) }
        encoder = gsm_create()
    }

    /// Clear partial bytes and reset the native decoder predictor history.
    ///
    /// Call between sessions or when a decode stream is interrupted.
    func resetDecodeState() {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        decodeRemainder.removeAll(keepingCapacity: true)
        if let decoder { gsm_destroy(decoder) }
        decoder = gsm_create()
    }

    /// Reset all codec state for a fresh session.
    ///
    /// Recreates both native states so the next talker or capture generation
    /// cannot inherit the prior speech's filter and pitch predictor history.
    func resetAll() {
        resetEncodeState()
        resetDecodeState()
    }
}

// MARK: - Data Helpers

private extension Data.SubSequence {
    var asData: Data { Data(self) }
}
