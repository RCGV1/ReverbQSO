// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO
final class SpeexReceiveStreamDecoderTests: XCTestCase {
    private func metadata(_ sequence: UInt16, timestamp: UInt32 = 0, ssrc: UInt32 = 1) -> EchoLinkVoicePacketMetadata {
        .init(payloadType: 0x96, sequenceNumber: sequence, timestamp: timestamp, ssrc: ssrc)
    }
    private func payload() throws -> Data {
        let speech = (0..<640).map { Int16(10000 * sin(Double($0) * .pi / 40)) }
        return try XCTUnwrap(SpeexCodec().encode(speech)?.first)
    }
    func testShortGapUsesNativeDecoderBeforeReturningReceivedAudio() throws {
        let decoder = SpeexReceiveStreamDecoder()
        let packet = try payload()
        let first = try XCTUnwrap(decoder.decode(packet, metadata: metadata(1, timestamp: 100), now: 0))
        XCTAssertEqual(first.received.count, 640)
        XCTAssertTrue(first.concealed.isEmpty)
        let after = try XCTUnwrap(decoder.decode(packet, metadata: metadata(3, timestamp: 1380), now: 0.16))
        XCTAssertEqual(after.concealed.count, 640)
        XCTAssertTrue(after.concealed.contains { abs(Int($0)) > 10 })
        let reference = SpeexCodec()
        _ = reference.decodePacket(packet)
        XCTAssertEqual(after.concealed, reference.concealMissingSamples(640))
        XCTAssertEqual(after.received, reference.decodePacket(packet))
    }
    func testSequenceGapDeterminesConcealmentWhenTimestampSuggestsPartialPacket() throws {
        let decoder = SpeexReceiveStreamDecoder()
        let packet = try payload()
        _ = try XCTUnwrap(decoder.decode(packet, metadata: metadata(1, timestamp: 100), now: 0))

        let after = try XCTUnwrap(decoder.decode(packet, metadata: metadata(3, timestamp: 900), now: 0.16))

        let reference = SpeexCodec()
        _ = reference.decodePacket(packet)
        XCTAssertEqual(after.concealed, reference.concealMissingSamples(640))
        XCTAssertEqual(after.received, reference.decodePacket(packet))
    }
    func testMalformedPacketDoesNotConsumeSequenceOrChangePlaybackDecoder() throws {
        let decoder = SpeexReceiveStreamDecoder()
        let packet = try payload()
        let first = try XCTUnwrap(decoder.decode(packet, metadata: metadata(10), now: 0))
        XCTAssertNil(decoder.decode(Data([0]), metadata: metadata(11), now: 0.01))
        let valid = try XCTUnwrap(decoder.decode(packet, metadata: metadata(11), now: 0.02))
        XCTAssertTrue(valid.concealed.isEmpty)
        let reference = SpeexCodec()
        XCTAssertEqual(first.received, reference.decodePacket(packet))
        XCTAssertEqual(valid.received, reference.decodePacket(packet))
    }
    func testLongGapsAndNewTalkersDoNotSynthesizeOldSpeech() throws {
        let decoder = SpeexReceiveStreamDecoder()
        let packet = try payload()
        _ = decoder.decode(packet, metadata: metadata(1), now: 0)
        XCTAssertTrue(try XCTUnwrap(decoder.decode(packet, metadata: metadata(6), now: 0.3)).concealed.isEmpty)
        XCTAssertTrue(try XCTUnwrap(decoder.decode(packet, metadata: metadata(9, ssrc: 2), now: 0.4)).concealed.isEmpty)
        decoder.reset()
        XCTAssertTrue(try XCTUnwrap(decoder.decode(packet, metadata: metadata(11), now: 0.41)).concealed.isEmpty)
    }
    func testWrapAndDuplicateRejection() throws {
        let decoder = SpeexReceiveStreamDecoder()
        let packet = try payload()
        _ = decoder.decode(packet, metadata: metadata(.max), now: 0)
        XCTAssertEqual(try XCTUnwrap(decoder.decode(packet, metadata: metadata(1), now: 0.16)).concealed.count, 640)
        XCTAssertNil(decoder.decode(packet, metadata: metadata(1), now: 0.17))
    }
    func testMetadataFreePacketsKeepDecoderStateUntilIdle() throws {
        let decoder = SpeexReceiveStreamDecoder()
        let packet = try payload()
        let first = try XCTUnwrap(decoder.decode(packet, metadata: nil, now: 0))
        let second = try XCTUnwrap(decoder.decode(packet, metadata: nil, now: 0.1))

        let reference = SpeexCodec()
        XCTAssertEqual(first.received, reference.decodePacket(packet))
        XCTAssertEqual(second.received, reference.decodePacket(packet))

        let afterIdle = try XCTUnwrap(decoder.decode(packet, metadata: nil, now: 0.7))
        XCTAssertEqual(afterIdle.received, SpeexCodec().decodePacket(packet))
    }
}
