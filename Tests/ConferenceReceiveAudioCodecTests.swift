// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

@MainActor
final class ConferenceReceiveAudioCodecTests: XCTestCase {
    func testPCMTranscodesAndForwardsValidTimestampedGSM() throws {
        let codec = ConferenceReceiveAudioCodec()
        let samples = (0..<640).map { Int16(10_000 * sin(Double($0) * 0.17)) }
        let incoming = ParsedIncomingAudioDatagram(packet: .pcm(samples), metadata: metadata(1))
        let decoded = try XCTUnwrap(codec.decode(incoming))
        XCTAssertEqual(decoded.samples, samples)
        XCTAssertEqual(decoded.gsmPayload.count, 132)
        let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: decoded.gsmPayload, sequence: 7, timestamp: 640
        )
        let forwarded = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet))
        XCTAssertEqual(forwarded.metadata?.sequenceNumber, 7)
        XCTAssertEqual(forwarded.metadata?.timestamp, 640)
        XCTAssertEqual(forwarded.packet, .gsm(decoded.gsmPayload))
        XCTAssertNil(codec.decode(incoming))
        XCTAssertNil(codec.decode(ParsedIncomingAudioDatagram(packet: .pcm(samples), metadata: metadata(0))))
    }

    func testInvalidFramesDoNotPoisonSequenceAndPeerDecodersAreIndependent() throws {
        let codec = ConferenceReceiveAudioCodec()
        let bad = ParsedIncomingAudioDatagram(packet: .pcm([1, 2]), metadata: metadata(3))
        XCTAssertNil(codec.decode(bad))
        let samples = [Int16](repeating: 2_000, count: 640)
        let incoming = ParsedIncomingAudioDatagram(packet: .pcm(samples), metadata: metadata(3))
        let first = try XCTUnwrap(codec.decode(incoming))
        let second = try XCTUnwrap(ConferenceReceiveAudioCodec().decode(incoming))
        XCTAssertEqual(first.gsmPayload, second.gsmPayload)
        XCTAssertNil(codec.decode(ParsedIncomingAudioDatagram(
            packet: .gsm(Data(repeating: 0, count: 132)), metadata: metadata(4)
        )))
    }

    func testSpeexTranscodesFourPackedFramesToGSM() throws {
        let codec = ConferenceReceiveAudioCodec()
        let incoming = ParsedIncomingAudioDatagram(
            packet: .speex(SpeexCodecTests.fixture),
            metadata: EchoLinkVoicePacketMetadata(payloadType: 0x96, sequenceNumber: 1, timestamp: 0, ssrc: 1)
        )
        let decoded = try XCTUnwrap(codec.decode(incoming))
        XCTAssertEqual(decoded.samples.count, 640)
        XCTAssertEqual(decoded.nativeConcealment, [])
        XCTAssertEqual(decoded.gsmPayload.count, 132)
        XCTAssertEqual(GSMCodec().decodePacket(decoded.gsmPayload).count, 640)
        XCTAssertNil(codec.decode(incoming))
    }

    func testLostSpeexPacketConcealsLocallyButForwardsOnlyReceivedPacket() throws {
        let codec = ConferenceReceiveAudioCodec()
        let first = ParsedIncomingAudioDatagram(
            packet: .speex(SpeexCodecTests.fixture),
            metadata: EchoLinkVoicePacketMetadata(
                payloadType: 0x96, sequenceNumber: 1, timestamp: 0, ssrc: 7
            )
        )
        let afterLoss = ParsedIncomingAudioDatagram(
            packet: .speex(SpeexCodecTests.fixture),
            metadata: EchoLinkVoicePacketMetadata(
                payloadType: 0x96, sequenceNumber: 3, timestamp: 1_280, ssrc: 7
            )
        )
        _ = try XCTUnwrap(codec.decode(first))

        let decoded = try XCTUnwrap(codec.decode(afterLoss))

        XCTAssertEqual(decoded.nativeConcealment?.count, 640)
        XCTAssertTrue(try XCTUnwrap(decoded.nativeConcealment).contains { abs(Int($0)) > 0 })
        XCTAssertEqual(decoded.samples.count, 640)
        XCTAssertEqual(decoded.gsmPayload.count, 132)
        XCTAssertEqual(GSMCodec().decodePacket(decoded.gsmPayload).count, 640)
    }

    func testMalformedNewTalkerDoesNotResetGSMHistory() throws {
        let codec = ConferenceReceiveAudioCodec()
        let reference = ConferenceReceiveAudioCodec()
        let encoder = GSMCodec()
        let speech = (0..<640).map { Int16($0 % 40 < 20 ? 12_000 : -12_000) }
        func packet(_ sequence: UInt16) throws -> ParsedIncomingAudioDatagram {
            .init(packet: .gsm(try XCTUnwrap(GSMCodec.stripHeader(encoder.encode(speech)))),
                metadata: .init(payloadType: 3, sequenceNumber: sequence,
                    timestamp: UInt32(sequence) * 640, ssrc: 1))
        }
        for sequence in UInt16(1)...5 {
            let incoming = try packet(sequence)
            XCTAssertEqual(try XCTUnwrap(codec.decode(incoming)).samples,
                           try XCTUnwrap(reference.decode(incoming)).samples)
        }
        XCTAssertNil(codec.decode(.init(packet: .gsm(Data(repeating: 0, count: 132)),
            metadata: .init(payloadType: 3, sequenceNumber: 1, timestamp: 0, ssrc: 2))))
        let next = try packet(6)
        XCTAssertEqual(try XCTUnwrap(codec.decode(next)).samples,
                       try XCTUnwrap(reference.decode(next)).samples)
    }

    func testMalformedCodecSwitchDoesNotResetSpeexHistoryOrGSMTranscoder() throws {
        let codec = ConferenceReceiveAudioCodec()
        let reference = ConferenceReceiveAudioCodec()
        func packet(_ sequence: UInt16) -> ParsedIncomingAudioDatagram {
            .init(packet: .speex(SpeexCodecTests.fixture),
                metadata: .init(payloadType: 0x96, sequenceNumber: sequence,
                    timestamp: UInt32(sequence) * 640, ssrc: 1))
        }
        for sequence in UInt16(1)...3 {
            let incoming = packet(sequence)
            _ = try XCTUnwrap(codec.decode(incoming))
            _ = try XCTUnwrap(reference.decode(incoming))
        }
        XCTAssertNil(codec.decode(.init(packet: .pcm([1, 2]),
            metadata: .init(payloadType: 0, sequenceNumber: 4, timestamp: 2560, ssrc: 1))))
        XCTAssertNil(codec.decode(.init(packet: .speex(Data([0])),
            metadata: .init(payloadType: 0x96, sequenceNumber: 1, timestamp: 0, ssrc: 2))))
        let actual = try XCTUnwrap(codec.decode(packet(4)))
        let expected = try XCTUnwrap(reference.decode(packet(4)))
        XCTAssertEqual(actual.samples, expected.samples)
        XCTAssertEqual(actual.gsmPayload, expected.gsmPayload)
    }

    private func metadata(_ sequence: UInt16) -> EchoLinkVoicePacketMetadata {
        EchoLinkVoicePacketMetadata(payloadType: 0, sequenceNumber: sequence, timestamp: UInt32(sequence) * 640, ssrc: 1)
    }
}
