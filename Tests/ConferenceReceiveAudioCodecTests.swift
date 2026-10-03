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

    private func metadata(_ sequence: UInt16) -> EchoLinkVoicePacketMetadata {
        EchoLinkVoicePacketMetadata(payloadType: 0, sequenceNumber: sequence, timestamp: UInt32(sequence) * 640, ssrc: 1)
    }
}
