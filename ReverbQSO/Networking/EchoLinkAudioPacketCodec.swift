// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Parsed incoming audio payload types accepted by the client.
enum ParsedIncomingAudioPacket: Equatable {
    case gsm(Data)
    case pcm([Int16])
    case speex(Data)
    case unsupportedPayloadType(UInt8)
}

/// RTP/legacy voice metadata parsed from packet headers when available.
struct EchoLinkVoicePacketMetadata: Equatable {
    let payloadType: UInt8
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
}

/// Parsed incoming audio outcome plus optional RTP-style metadata.
struct ParsedIncomingAudioDatagram: Equatable {
    let packet: ParsedIncomingAudioPacket
    let metadata: EchoLinkVoicePacketMetadata?
}

/// Helpers for EchoLink/RTP packet encoding and decoding.
enum EchoLinkAudioPacketCodec {
    static let legacyVoiceHeaderLength = 12
    static let maxGSMFramesPerPacket = 4

    /// Build the legacy EchoLink voice packet header used by many clients.
    ///
    /// Header layout:
    /// - byte 0: version (0xC0)
    /// - byte 1: payload type (0x03 for GSM)
    /// - bytes 2-3: sequence number (big-endian)
    /// - bytes 4-7: RTP timestamp (big-endian, in 8 kHz sample ticks)
    /// - bytes 8-11: SSRC (legacy clients often use zero)
    ///
    /// Pass a monotonically increasing `timestamp` so receiving jitter buffers
    /// can correctly schedule playout. The increment per packet equals the number
    /// of PCM samples contained: `GSMCodec.samplesPerFrame × framesInPacket`.
    static func buildLegacyVoicePacket(gsmPayload: Data, sequence: UInt16, timestamp: UInt32 = 0) -> Data {
        var packet = Data(capacity: legacyVoiceHeaderLength + gsmPayload.count)
        packet.append(0xC0)
        packet.append(0x03)
        packet.append(UInt8((sequence >> 8) & 0xFF))
        packet.append(UInt8(sequence & 0xFF))
        packet.append(UInt8((timestamp >> 24) & 0xFF))
        packet.append(UInt8((timestamp >> 16) & 0xFF))
        packet.append(UInt8((timestamp >>  8) & 0xFF))
        packet.append(UInt8( timestamp        & 0xFF))
        packet.append(contentsOf: [0, 0, 0, 0]) // ssrc
        packet.append(gsmPayload)
        return packet
    }

    /// Consume complete EchoLink GSM packets from a streaming buffer.
    ///
    /// EchoLink peers expect a fixed four GSM frames per voice datagram. Complete
    /// GSM frames that do not yet fill a packet remain buffered for the next call.
    /// Any partial trailing frame is preserved as well.
    static func consumeOutgoingGSMPayloadPackets(
        buffer: inout Data,
        frameSize: Int = GSMCodec.encodedFrameSize,
        maxFramesPerPacket: Int = maxGSMFramesPerPacket
    ) -> [Data] {
        guard frameSize > 0, maxFramesPerPacket > 0 else { return [] }

        var packets: [Data] = []
        let (packetSize, overflow) = maxFramesPerPacket.multipliedReportingOverflow(by: frameSize)
        guard !overflow else { return [] }
        while buffer.count >= packetSize {
            packets.append(Data(buffer.prefix(packetSize)))
            buffer.removeFirst(packetSize)
        }
        return packets
    }

    /// Parse incoming EchoLink/RTP audio packets with conservative fallback behavior.
    static func parseIncomingAudioPacket(_ data: Data) -> ParsedIncomingAudioPacket? {
        parseIncomingAudioDatagram(data)?.packet
    }

    /// Parse incoming EchoLink/RTP audio packets, preserving RTP-style metadata when present.
    static func parseIncomingAudioDatagram(_ data: Data) -> ParsedIncomingAudioDatagram? {
        if let stripped = GSMCodec.stripHeader(data), !stripped.isEmpty {
            return ParsedIncomingAudioDatagram(packet: .gsm(stripped), metadata: nil)
        }

        if data.count >= legacyVoiceHeaderLength, data[data.startIndex] == 0xC0 {
            // Legacy peers use 0x96 for Speex. For standard payload types,
            // the high bit is the RTP marker flag, not part of the codec ID.
            let wirePayloadType = data[data.startIndex + 1]
            let payloadType = wirePayloadType == 0x96 ? wirePayloadType : wirePayloadType & 0x7F
            let sequenceNumber = readUInt16(data, offset: 2)
            let timestamp = readUInt32(data, offset: 4)
            let ssrc = readUInt32(data, offset: 8)
            let payload = Data(data.dropFirst(legacyVoiceHeaderLength))
            guard !payload.isEmpty else { return nil }
            return ParsedIncomingAudioDatagram(
                packet: decodePayload(payload, payloadType: payloadType),
                metadata: EchoLinkVoicePacketMetadata(
                    payloadType: payloadType,
                    sequenceNumber: sequenceNumber,
                    timestamp: timestamp,
                    ssrc: ssrc
                )
            )
        }

        guard data.count >= 12 else {
            if isFrameAlignedGSM(data) {
                return ParsedIncomingAudioDatagram(packet: .gsm(data), metadata: nil)
            }
            return nil
        }

        guard let parsedRTP = parseRTPPayload(from: data) else {
            if isFrameAlignedGSM(data) {
                return ParsedIncomingAudioDatagram(packet: .gsm(data), metadata: nil)
            }
            return nil
        }

        return ParsedIncomingAudioDatagram(
            packet: decodePayload(parsedRTP.payload, payloadType: parsedRTP.payloadType),
            metadata: parsedRTP.metadata
        )
    }

    // MARK: - G.711 Decoders

    static func decodeMuLaw(_ byte: UInt8) -> Int16 {
        let mu = ~Int(byte) & 0xFF
        let sign = mu & 0x80
        let exponent = (mu >> 4) & 0x07
        let mantissa = mu & 0x0F

        var sample = ((mantissa << 3) + 0x84) << exponent
        sample -= 0x84

        if sign != 0 {
            sample = -sample
        }
        return Int16(clamping: sample)
    }

    static func decodeALaw(_ byte: UInt8) -> Int16 {
        let a = Int(byte ^ 0x55) & 0xFF
        let sign = a & 0x80
        let exponent = (a >> 4) & 0x07
        let mantissa = a & 0x0F

        let sample: Int
        if exponent == 0 {
            sample = (mantissa << 4) + 8
        } else {
            sample = ((mantissa << 4) + 0x108) << (exponent - 1)
        }

        // G.711 A-law uses a set sign bit for positive PCM after the
        // alternate-bit inversion (0xD5 is positive near-silence).
        return Int16(clamping: sign != 0 ? sample : -sample)
    }

    // MARK: - Private

    private static func decodePayload(_ payload: Data, payloadType: UInt8) -> ParsedIncomingAudioPacket {
        switch payloadType {
        case 3:
            return .gsm(payload)
        case 0:
            return .pcm(payload.map(decodeMuLaw))
        case 8:
            return .pcm(payload.map(decodeALaw))
        case 0x96:
            return .speex(payload)
        default:
            if let fallback = fallbackDecodePayload(payload, payloadType: payloadType) {
                return fallback
            }
            return .unsupportedPayloadType(payloadType)
        }
    }

    private static func fallbackDecodePayload(_ payload: Data, payloadType: UInt8) -> ParsedIncomingAudioPacket? {
        if isFrameAlignedGSM(payload) {
            return .gsm(payload)
        }

        // Conservative fallback: treat dynamic RTP payload numbers as G.711-like only when
        // payload shape is plausible for 8k telephony audio.
        if payloadType >= 96, payload.count >= 160, payload.count % 80 == 0 {
            return .pcm(payload.map(decodeMuLaw))
        }
        return nil
    }

    private static func isFrameAlignedGSM(_ data: Data) -> Bool {
        data.count >= GSMCodec.encodedFrameSize && data.count % GSMCodec.encodedFrameSize == 0
    }

    private static func parseRTPPayload(
        from data: Data
    ) -> (payloadType: UInt8, payload: Data, metadata: EchoLinkVoicePacketMetadata)? {
        let bytes = [UInt8](data)
        guard data.count >= 12 else { return nil }
        let version = bytes[0] >> 6
        // Accept both RTP v2 (standard) and v3 (used by many EchoLink nodes for
        // packets that don't start with 0xC0, e.g. version-3 packets with CSRCs).
        guard version == 2 || version == 3 else { return nil }

        let hasPadding = (bytes[0] & 0x20) != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        let hasExtension = (bytes[0] & 0x10) != 0
        let payloadType = version == 3 && bytes[1] == 0x96 ? bytes[1] : bytes[1] & 0x7F
        let sequenceNumber = readUInt16(data, offset: 2)
        let timestamp = readUInt32(data, offset: 4)
        let ssrc = readUInt32(data, offset: 8)

        var headerLength = 12 + (csrcCount * 4)
        guard data.count >= headerLength else { return nil }

        if hasExtension {
            guard data.count >= headerLength + 4 else { return nil }
            let extensionLengthWords =
                (Int(bytes[headerLength + 2]) << 8) | Int(bytes[headerLength + 3])
            let (extensionBytes, overflow) = extensionLengthWords.multipliedReportingOverflow(by: 4)
            guard !overflow else { return nil }
            let extensionTotalLength = 4 + extensionBytes
            guard data.count >= headerLength + extensionTotalLength else { return nil }
            headerLength += extensionTotalLength
        }

        var payloadEnd = data.count
        if hasPadding {
            guard let paddingCount = bytes.last.map(Int.init),
                  paddingCount > 0,
                  paddingCount <= data.count - headerLength else {
                return nil
            }
            payloadEnd -= paddingCount
        }

        guard payloadEnd > headerLength else { return nil }
        return (
            payloadType,
            Data(data.dropFirst(headerLength).prefix(payloadEnd - headerLength)),
            EchoLinkVoicePacketMetadata(
                payloadType: payloadType,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                ssrc: ssrc
            )
        )
    }

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        let index = data.startIndex + offset
        return (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let index = data.startIndex + offset
        return (UInt32(data[index]) << 24) |
        (UInt32(data[index + 1]) << 16) |
        (UInt32(data[index + 2]) << 8) |
        UInt32(data[index + 3])
    }
}
