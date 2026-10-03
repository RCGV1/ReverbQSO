// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class EchoLinkAudioPacketCodecTests: XCTestCase {

    func testParseSlicedLegacyVoicePacketPreservesPayloadAndMetadata() {
        let payload = Data(repeating: 0x22, count: GSMCodec.encodedFrameSize)
        let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: payload, sequence: 0x1234, timestamp: 0x01020304
        )
        var storage = Data(repeating: 0xFF, count: 17)
        storage.append(packet)
        let slice = storage.dropFirst(17)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(
            EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(slice),
            EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet)
        )
    }

    func testParseSlicedRTPPacketWithExtensionAndPadding() {
        // One CSRC, one extension word, two G.711 samples and two padding bytes.
        var packet = Data([0xB1, 0x08, 0x12, 0x34, 1, 2, 3, 4, 5, 6, 7, 8])
        packet.append(contentsOf: [9, 10, 11, 12, 0xBE, 0xDE, 0, 1, 13, 14, 15, 16])
        packet.append(contentsOf: [0xD5, 0x55, 0, 2])
        var storage = Data(repeating: 0xFF, count: 17)
        storage.append(packet)
        let slice = storage.dropFirst(17)
        XCTAssertNotEqual(slice.startIndex, 0)
        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(slice)
        XCTAssertEqual(parsed?.packet, .pcm([8, -8]))
        XCTAssertEqual(parsed?.metadata?.sequenceNumber, 0x1234)
        XCTAssertEqual(parsed?.metadata?.timestamp, 0x01020304)
        XCTAssertEqual(parsed?.metadata?.ssrc, 0x05060708)
    }

    func testParseLegacyBEEFHeaderAsGSM() {
        let payload = Data(repeating: 0x11, count: GSMCodec.encodedFrameSize * 2)
        var packet = Data(GSMCodec.packetHeader)
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertEqual(parsed, .gsm(payload))
    }

    func testParseLegacyVoiceHeaderPT3AsGSM() {
        let payload = Data(repeating: 0x22, count: GSMCodec.encodedFrameSize)
        var packet = Data([0xC0, 0x03, 0x00, 0x01])
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertEqual(parsed, .gsm(payload))
    }

    func testParseLegacyVoicePacketExposesSequenceTimestampAndSSRC() {
        let payload = Data(repeating: 0x22, count: GSMCodec.encodedFrameSize)
        var packet = Data([0xC0, 0x03, 0x12, 0x34])
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        packet.append(contentsOf: [0xA0, 0xB0, 0xC0, 0xD0])
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet)

        XCTAssertEqual(parsed?.packet, .gsm(payload))
        XCTAssertEqual(
            parsed?.metadata,
            EchoLinkVoicePacketMetadata(
                payloadType: 3,
                sequenceNumber: 0x1234,
                timestamp: 0x01020304,
                ssrc: 0xA0B0C0D0
            )
        )
    }

    func testParseLegacyVoiceHeaderPT0AsPCMMuLaw() {
        let payload = Data([0x80, 0x00, 0xFF])
        var packet = Data([0xC0, 0x00, 0x00, 0x01])
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        guard case .pcm(let samples)? = parsed else {
            return XCTFail("Expected PCM payload")
        }

        XCTAssertEqual(samples.count, payload.count)
        XCTAssertTrue(samples[0] > 0)
        XCTAssertTrue(samples[1] < 0)
    }

    func testParseLegacyVoiceHeaderPT8AsPCMALaw() {
        let payload = Data([0x55, 0xD5, 0x2A])
        var packet = Data([0xC0, 0x08, 0x00, 0x01])
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        guard case .pcm(let samples)? = parsed else {
            return XCTFail("Expected PCM payload")
        }

        XCTAssertEqual(samples.count, payload.count)
        XCTAssertTrue(samples[0] < 0)
        XCTAssertTrue(samples[1] > 0)
    }

    func testParseMarkedLegacyALawPacketUsesALawDecoder() {
        let payload = Data([0x55, 0xD5, 0x2A])
        var packet = Data([0xC0, 0x88, 0x00, 0x01]) // marker=1, PT=8
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet)
        XCTAssertEqual(parsed?.packet, .pcm([-8, 8, -32256]))
        XCTAssertEqual(parsed?.metadata?.payloadType, 8)
    }

    func testParseLegacyVoiceHeaderSpeexPreservesPackedPayload() {
        var packet = Data([0xC0, 0x96, 0x00, 0x01])
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(contentsOf: [0x01, 0x02, 0x03])

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertEqual(parsed, .speex(Data(packet.dropFirst(12))))
    }

    func testParseVersionThreeSpeexWithCSRC() {
        let packet = Data([0xC1, 0x96, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
                           1, 2, 3, 4, 0xAA, 0xBB])
        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet)
        XCTAssertEqual(parsed?.packet, .speex(Data([0xAA, 0xBB])))
        XCTAssertEqual(parsed?.metadata?.payloadType, 0x96)
    }

    func testParseRTPWithCSRCAndExtension() {
        let payload = Data(repeating: 0x33, count: GSMCodec.encodedFrameSize)
        var packet = Data()
        packet.append(0x91) // V=2, X=1, CC=1
        packet.append(0x03) // PT=GSM
        packet.append(contentsOf: [0x12, 0x34]) // sequence
        packet.append(contentsOf: [0, 0, 0, 1]) // timestamp
        packet.append(contentsOf: [0, 0, 0, 2]) // ssrc
        packet.append(contentsOf: [0, 0, 0, 3]) // one CSRC
        packet.append(contentsOf: [0, 1, 0, 1]) // extension profile + 1 word
        packet.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD]) // extension payload
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertEqual(parsed, .gsm(payload))
    }

    func testParseRTPPacketExposesSequenceTimestampAndSSRC() {
        let payload = Data(repeating: 0x33, count: GSMCodec.encodedFrameSize)
        var packet = Data()
        packet.append(0x80) // V=2
        packet.append(0x03) // PT=GSM
        packet.append(contentsOf: [0x56, 0x78])
        packet.append(contentsOf: [0x11, 0x22, 0x33, 0x44])
        packet.append(contentsOf: [0x99, 0x88, 0x77, 0x66])
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet)

        XCTAssertEqual(parsed?.packet, .gsm(payload))
        XCTAssertEqual(
            parsed?.metadata,
            EchoLinkVoicePacketMetadata(
                payloadType: 3,
                sequenceNumber: 0x5678,
                timestamp: 0x11223344,
                ssrc: 0x99887766
            )
        )
    }

    func testParseRTPWithPaddingStripsTrailingPadding() {
        let payload = Data(repeating: 0x34, count: GSMCodec.encodedFrameSize)
        var packet = Data()
        packet.append(0xA0) // V=2, P=1
        packet.append(0x03) // PT=GSM
        packet.append(contentsOf: [0x00, 0x09]) // sequence
        packet.append(contentsOf: [0, 0, 0, 1]) // timestamp
        packet.append(contentsOf: [0, 0, 0, 2]) // ssrc
        packet.append(payload)
        packet.append(contentsOf: [0, 0, 0, 4]) // 4 bytes of padding, count in last octet

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertEqual(parsed, .gsm(payload))
    }

    func testParseRTPRejectsInvalidPaddingCount() {
        var packet = Data()
        packet.append(0xA0) // V=2, P=1
        packet.append(0x03) // PT=GSM
        packet.append(contentsOf: [0x00, 0x01]) // sequence
        packet.append(contentsOf: [0, 0, 0, 1]) // timestamp
        packet.append(contentsOf: [0, 0, 0, 2]) // ssrc
        packet.append(Data(repeating: 0x11, count: 22))
        packet.append(40) // invalid padding count (> payload bytes)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertNil(parsed)
    }

    func testParseRTPRejectsOversizedExtensionBlock() {
        var packet = Data()
        packet.append(0x90) // V=2, X=1
        packet.append(0x03) // PT=GSM
        packet.append(contentsOf: [0x00, 0x01]) // sequence
        packet.append(contentsOf: [0, 0, 0, 1]) // timestamp
        packet.append(contentsOf: [0, 0, 0, 2]) // ssrc
        packet.append(contentsOf: [0xBE, 0xDE, 0x00, 0x04]) // extension claims 16 bytes
        packet.append(contentsOf: [0x01, 0x02, 0x03]) // too short for claimed extension

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertNil(parsed)
    }

    func testParseRTPHeaderOnlyReturnsNil() {
        let packet = Data([0x80, 0x03, 0x00, 0x01, 0, 0, 0, 1, 0, 0, 0, 2])
        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertNil(parsed)
    }

    func testParseInvalidRTPVersionFallsBackToRawFrameAlignedGSM() {
        let packet = Data(repeating: 0x44, count: GSMCodec.encodedFrameSize)
        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertEqual(parsed, .gsm(packet))
    }

    func testParseUnknownPayloadTypeReturnsUnsupported() {
        let payload = Data(repeating: 0x12, count: 17)
        var packet = Data([0x80, 0x13, 0x00, 0x01]) // PT=19
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertEqual(parsed, .unsupportedPayloadType(0x13))
    }

    func testParseDynamicPayloadFallbackToMuLawWhenShapePlausible() {
        let payload = Data(repeating: 0x7F, count: 160)
        var packet = Data([0x80, 100, 0x00, 0x01]) // dynamic PT
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        guard case .pcm(let samples)? = parsed else {
            return XCTFail("Expected PCM fallback decode")
        }
        XCTAssertEqual(samples.count, payload.count)
    }

    func testParseDynamicPayloadWithoutPlausibleShapeReturnsUnsupported() {
        let payload = Data(repeating: 0x7F, count: 159)
        var packet = Data([0x80, 100, 0x00, 0x01]) // dynamic PT
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertEqual(parsed, .unsupportedPayloadType(100))
    }

    func testUnknownLegacyPayloadTypeFallsBackToFrameAlignedGSM() {
        let payload = Data(repeating: 0x23, count: GSMCodec.encodedFrameSize * 2)
        var packet = Data([0xC0, 0x13, 0x00, 0x01]) // unknown PT=19
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertEqual(parsed, .gsm(payload))
    }

    func testConsumeOutgoingGSMPayloadPacketsLeavesRemainder() {
        var buffer = Data(repeating: 0x55, count: (9 * GSMCodec.encodedFrameSize) + 10)
        let chunks = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &buffer)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 4 * GSMCodec.encodedFrameSize)
        XCTAssertEqual(chunks[1].count, 4 * GSMCodec.encodedFrameSize)
        XCTAssertEqual(buffer.count, GSMCodec.encodedFrameSize + 10)
    }

    func testConsumeOutgoingGSMPayloadPacketsDoesNotEmitShortPacket() {
        var buffer = Data(repeating: 0x57, count: 3 * GSMCodec.encodedFrameSize)

        let chunks = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &buffer)

        XCTAssertTrue(chunks.isEmpty)
        XCTAssertEqual(buffer.count, 3 * GSMCodec.encodedFrameSize)
    }

    func testConsumeOutgoingGSMPayloadPacketsHonorsCustomMaxFramesPerPacket() {
        var buffer = Data(repeating: 0x66, count: 3 * GSMCodec.encodedFrameSize)
        let chunks = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(
            buffer: &buffer,
            frameSize: GSMCodec.encodedFrameSize,
            maxFramesPerPacket: 1
        )

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].count, GSMCodec.encodedFrameSize)
        XCTAssertEqual(chunks[1].count, GSMCodec.encodedFrameSize)
        XCTAssertEqual(chunks[2].count, GSMCodec.encodedFrameSize)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testConsumeOutgoingGSMPayloadPacketsWithInvalidParametersReturnsEmpty() {
        var buffer = Data(repeating: 0x77, count: GSMCodec.encodedFrameSize * 2)
        let chunks = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(
            buffer: &buffer,
            frameSize: 0,
            maxFramesPerPacket: 4
        )

        XCTAssertTrue(chunks.isEmpty)
        XCTAssertEqual(buffer.count, GSMCodec.encodedFrameSize * 2)
    }

    func testConsumeOutgoingGSMPayloadPacketsRejectsOverflowingPacketSize() {
        var buffer = Data(repeating: 0x77, count: GSMCodec.encodedFrameSize * 2)

        let chunks = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(
            buffer: &buffer,
            frameSize: Int.max,
            maxFramesPerPacket: 2
        )

        XCTAssertTrue(chunks.isEmpty)
        XCTAssertEqual(buffer.count, GSMCodec.encodedFrameSize * 2)
    }

    func testBuildLegacyVoicePacketEncodesSequenceAndPayload() {
        let payload = Data([0x01, 0x02, 0x03])
        let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: payload,
            sequence: 0x1234
        )

        XCTAssertEqual(packet.count, EchoLinkAudioPacketCodec.legacyVoiceHeaderLength + payload.count)
        XCTAssertEqual(packet[0], 0xC0)
        XCTAssertEqual(packet[1], 0x03)
        XCTAssertEqual(packet[2], 0x12)
        XCTAssertEqual(packet[3], 0x34)
        XCTAssertEqual(Data(packet.suffix(payload.count)), payload)
    }

    func testParseBEEFHeaderWithoutPayloadReturnsNil() {
        let packet = Data(GSMCodec.packetHeader)
        XCTAssertNil(EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet))
    }

    func testParseLegacyVoiceHeaderWithoutPayloadReturnsNil() {
        let packet = Data([0xC0, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertNil(EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet))
    }

    func testParseRTPMarkerBitDoesNotChangePayloadTypeHandling() {
        let payload = Data(repeating: 0x33, count: GSMCodec.encodedFrameSize)
        var packet = Data([0x80, 0x83, 0x00, 0x02]) // marker=1, PT=3
        packet.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 2])
        packet.append(payload)

        XCTAssertEqual(EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet), .gsm(payload))
    }

    func testParseRTPWithMultipleCSRCParsesPayload() {
        let payload = Data(repeating: 0x31, count: GSMCodec.encodedFrameSize)
        var packet = Data([0x82, 0x03, 0x00, 0x11]) // V=2, CC=2
        packet.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 2]) // ts, ssrc
        packet.append(contentsOf: [0, 0, 0, 3, 0, 0, 0, 4]) // 2 csrcs
        packet.append(payload)

        XCTAssertEqual(EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet), .gsm(payload))
    }

    func testParseRTPWithTruncatedCSRCListReturnsNil() {
        var packet = Data([0x81, 0x03, 0x00, 0x11]) // V=2, CC=1
        packet.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 2]) // ts, ssrc
        packet.append(contentsOf: [0, 0]) // incomplete csrc

        XCTAssertNil(EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet))
    }

    func testParseRTPWithExtensionHeaderTruncatedReturnsNil() {
        var packet = Data([0x90, 0x03, 0x00, 0x11]) // V=2, X=1
        packet.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 2]) // ts, ssrc
        packet.append(contentsOf: [0xBE, 0xDE, 0x00]) // truncated extension header

        XCTAssertNil(EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet))
    }

    func testParseRTPWithPaddingEqualToPayloadReturnsNil() {
        var packet = Data([0xA0, 0x03, 0x00, 0x11]) // V=2, P=1
        packet.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 2]) // ts, ssrc
        packet.append(contentsOf: [0x01]) // one payload byte
        packet.append(contentsOf: [0x02]) // padding count says payload+padding fully padding

        XCTAssertNil(EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet))
    }

    func testDynamicPayloadTooSmallForFallbackReturnsUnsupported() {
        let payload = Data(repeating: 0x7F, count: 80)
        var packet = Data([0x80, 100, 0x00, 0x01])
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(payload)

        XCTAssertEqual(
            EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet),
            .unsupportedPayloadType(100)
        )
    }

    func testParseRandomNonFrameGarbageReturnsNil() {
        let payload = Data(repeating: 0x55, count: 27)
        XCTAssertNil(EchoLinkAudioPacketCodec.parseIncomingAudioPacket(payload))
    }

    func testConsumeOutgoingGSMPayloadPacketsWithZeroMaxFramesReturnsEmpty() {
        var buffer = Data(repeating: 0x10, count: GSMCodec.encodedFrameSize * 2)
        let chunks = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(
            buffer: &buffer,
            frameSize: GSMCodec.encodedFrameSize,
            maxFramesPerPacket: 0
        )
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertEqual(buffer.count, GSMCodec.encodedFrameSize * 2)
    }

    func testReceiveSequencerDropsDuplicateSequence() {
        var sequencer = EchoLinkReceiveSequencer()
        let metadata = makeMetadata(sequenceNumber: 42)

        XCTAssertTrue(sequencer.shouldAcceptForPlayback(metadata))
        XCTAssertFalse(sequencer.shouldAcceptForPlayback(metadata))
    }

    func testReceiveSequencerDropsLateOutOfOrderPacket() {
        var sequencer = EchoLinkReceiveSequencer()

        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 100)))
        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 101)))
        XCTAssertFalse(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 100)))
    }

    func testReceiveSequencerDropsPacketFarBehindCurrentStream() {
        var sequencer = EchoLinkReceiveSequencer()

        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 5_000)))
        XCTAssertFalse(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 4_000)))
    }

    func testReceiveSequencerAcceptsNewSSRC() {
        var sequencer = EchoLinkReceiveSequencer()

        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 5_000, ssrc: 1)))
        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 10, ssrc: 2)))
    }

    func testReceiveSequencerDropsDuplicateAfterInterleavedSSRC() {
        var sequencer = EchoLinkReceiveSequencer()

        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 10, ssrc: 1)))
        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 20, ssrc: 2)))
        XCTAssertFalse(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 10, ssrc: 1)))
    }

    func testReceiveSequencerEvictsLeastRecentlyAcceptedSSRCWhenHistoryIsFull() {
        var sequencer = EchoLinkReceiveSequencer()

        for ssrc in UInt32(1)...UInt32(32) {
            XCTAssertTrue(
                sequencer.shouldAcceptForPlayback(
                    makeMetadata(sequenceNumber: 10, ssrc: ssrc),
                    now: TimeInterval(ssrc) / 100
                )
            )
        }
        XCTAssertTrue(
            sequencer.shouldAcceptForPlayback(
                makeMetadata(sequenceNumber: 10, ssrc: 33),
                now: 0.33
            )
        )

        XCTAssertTrue(
            sequencer.shouldAcceptForPlayback(
                makeMetadata(sequenceNumber: 10, ssrc: 1),
                now: 0.34
            )
        )
    }

    func testReceiveSequencerAcceptsLegacySequenceRestartAfterInactivity() {
        var sequencer = EchoLinkReceiveSequencer()

        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 5_000, ssrc: 0), now: 10))
        XCTAssertFalse(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 10, ssrc: 0), now: 10.5))
        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 10, ssrc: 0), now: 12.1))
    }

    func testReceiveSequencerAcceptsSequenceWrap() {
        var sequencer = EchoLinkReceiveSequencer()

        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: UInt16.max)))
        XCTAssertTrue(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: 0)))
        XCTAssertFalse(sequencer.shouldAcceptForPlayback(makeMetadata(sequenceNumber: UInt16.max)))
    }

    func testReceiveSequencerDoesNotGateBEEFRawPackets() {
        var sequencer = EchoLinkReceiveSequencer()
        let metadata = makeMetadata(sequenceNumber: 42)

        XCTAssertTrue(sequencer.shouldAcceptForPlayback(metadata))
        XCTAssertTrue(sequencer.shouldAcceptForPlayback(nil))
        XCTAssertTrue(sequencer.shouldAcceptForPlayback(nil))
    }

    // MARK: - Control Packet Codec Tests

    func testBuildSDESPacketUsesLegacyRTCPVersion3ByDefault() {
        let packet = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0CALL")
        XCTAssertGreaterThanOrEqual(packet.count, 16)
        XCTAssertEqual(packet[0], 0xC0) // V=3, RC=0
        XCTAssertEqual(packet[1], 0xC9) // RR
        XCTAssertEqual(packet[8], 0xC1) // V=3, SC=1
        XCTAssertEqual(packet[9], 0xCA) // SDES
    }

    func testBuildSDESPacketSupportsOfficialClientCompatibilityShape() {
        let packet = EchoLinkControlPacketCodec.buildSDESPacket(
            callsign: "N0CALL",
            tool: "ReverbQSO/1.0",
            phone: "6DD56173",
            includePadding: true
        )

        XCTAssertEqual(packet[0], 0xC0) // V=3, RR is never padded
        XCTAssertEqual(packet[8], 0xE1) // V=3, P=1, SC=1
        XCTAssertEqual(Array(packet.suffix(4)), [0x00, 0x00, 0x00, 0x04])

        let sdesLengthWordsMinusOne = (Int(packet[10]) << 8) | Int(packet[11])
        XCTAssertEqual((sdesLengthWordsMinusOne + 1) * 4, packet.count - 8)

        guard case .sdes(let sdes) = EchoLinkControlPacketCodec.parseEvents(from: packet).first else {
            return XCTFail("Expected padded SDES event")
        }
        XCTAssertEqual(sdes.phone, "6DD56173")
        XCTAssertEqual(sdes.tool, "ReverbQSO/1.0")
        XCTAssertEqual(sdes.privateItems, ["SPEEX", "P5198", "D0"])
    }

    func testBuildSDESPacketSupportsVersion2ForCompatibility() {
        let packet = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0CALL", rtpVersion: 2)
        XCTAssertEqual(packet[0], 0x80)
        XCTAssertEqual(packet[8], 0x81)
    }

    func testParseEventsExtractsSDESNameFromBuiltPacket() {
        let packet = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "K1ABC")
        let events = EchoLinkControlPacketCodec.parseEvents(from: packet)

        XCTAssertEqual(events.count, 1)
        guard case .sdes(let sdes) = events[0] else {
            return XCTFail("Expected SDES event")
        }

        XCTAssertEqual(sdes.name, "K1ABC          ")
        XCTAssertEqual(sdes.cname, "CALLSIGN")
        XCTAssertEqual(sdes.email, "CALLSIGN")
        XCTAssertEqual(sdes.phone, "08:30")
        XCTAssertEqual(sdes.tool, "ReverbQSO/1.0")
        XCTAssertEqual(sdes.privateItems, ["SPEEX", "P5198", "D0"])
        XCTAssertEqual(sdes.preferredDisplayName, "K1ABC")
    }

    func testParseEventsExtractsBYEFromBuiltPacket() {
        let packet = EchoLinkControlPacketCodec.buildBYEPacket()
        let events = EchoLinkControlPacketCodec.parseEvents(from: packet)
        XCTAssertEqual(events, [.bye(reason: "jan2002")])
    }

    func testParseEventsExtractsCustomBYEReason() {
        let packet = EchoLinkControlPacketCodec.buildBYEPacket(reason: "Exceeded key-down time")

        XCTAssertEqual(
            EchoLinkControlPacketCodec.parseEvents(from: packet),
            [.bye(reason: "Exceeded key-down time")]
        )
    }

    func testParseEventsDoesNotTreatRTCPPaddingAsBYEReason() {
        let paddedBYE = Data([
            0xE1, 0xCB, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x00,
            0x03, 0x41, 0x42, 0x04
        ])

        XCTAssertEqual(
            EchoLinkControlPacketCodec.parseEvents(from: paddedBYE),
            [.bye(reason: nil)]
        )
    }

    func testParseEventsSupportsCompoundSDESAndBYEInSingleDatagram() {
        var packet = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "W6XYZ")
        let bye = EchoLinkControlPacketCodec.buildBYEPacket()
        packet.append(contentsOf: bye.dropFirst(8)) // append BYE block without duplicate RR

        let events = EchoLinkControlPacketCodec.parseEvents(from: packet)
        XCTAssertEqual(events.count, 2)

        guard case .sdes(let sdes) = events[0] else {
            return XCTFail("Expected first event to be SDES")
        }
        XCTAssertEqual(sdes.preferredDisplayName, "W6XYZ")
        XCTAssertEqual(events[1], .bye(reason: "jan2002"))
    }

    func testParseEventsRejectsMalformedRTCPLength() {
        var malformed = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "A")
        malformed[2] = 0xFF
        malformed[3] = 0xFF

        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: malformed).isEmpty)
    }

    func testParseEventsRejectsTruncatedSDESItem() {
        // V=3, SC=1, PT=SDES, len=2 words -> 12 bytes total block
        var packet = Data([0xC1, 0xCA, 0x00, 0x02])
        packet.append(contentsOf: [0, 0, 0, 0]) // SSRC
        packet.append(contentsOf: [0x01, 0x05, 0x41]) // CNAME claims 5 bytes but only 1 provided
        packet.append(0x00) // pad

        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: packet).isEmpty)
    }

    func testParseEventsParsesNDATAInfoMessage() {
        let packet = EchoLinkControlPacketCodec.buildNDATAInfoPacket(message: "Status online")
        let events = EchoLinkControlPacketCodec.parseEvents(from: packet)
        XCTAssertEqual(events, [.info("Status online")])
    }

    func testParseEventsParsesFrameAlignedNDATAInfoAsControl() {
        let packet = EchoLinkControlPacketCodec.buildNDATAInfoPacket(
            message: "1234567890123456789012345"
        )

        XCTAssertEqual(packet.count, GSMCodec.encodedFrameSize)
        XCTAssertEqual(EchoLinkControlPacketCodec.parseEvents(from: packet), [.info("1234567890123456789012345")])
    }

    func testBuildNDATAInfoPacketAppendsTrailingNul() {
        let packet = EchoLinkControlPacketCodec.buildNDATAInfoPacket(message: "Status online")

        XCTAssertEqual(packet.last, 0x00)
        XCTAssertEqual(String(decoding: packet.dropLast(), as: UTF8.self), "oNDATA\rStatus online")
    }

    func testParseEventsParsesNDATAChatMessageWithGreaterThanDelimiter() {
        let packet = EchoLinkControlPacketCodec.buildNDATAChatPacket(sender: "K1ABC", message: "hello world")
        let events = EchoLinkControlPacketCodec.parseEvents(from: packet)
        XCTAssertEqual(events, [.chat(sender: "K1ABC", body: "hello world")])
    }

    func testBuildNDATAChatPacketAppendsTrailingNul() {
        let packet = EchoLinkControlPacketCodec.buildNDATAChatPacket(sender: "K1ABC", message: "hello world")

        XCTAssertEqual(packet.last, 0x00)
        XCTAssertEqual(String(decoding: packet.dropLast(), as: UTF8.self), "oNDATAK1ABC>hello world\r\n")
    }

    func testParseEventsParsesNDATAChatMessageWithColonDelimiter() {
        let packet = Data("oNDATAK1ABC: hello world\r\n".utf8)
        let events = EchoLinkControlPacketCodec.parseEvents(from: packet)
        XCTAssertEqual(events, [.chat(sender: "K1ABC", body: "hello world")])
    }

    func testParseEventsParsesNDATAChatMessageWithoutDelimiterAsRemote() {
        let packet = Data("oNDATAjust text body\r\n".utf8)
        let events = EchoLinkControlPacketCodec.parseEvents(from: packet)
        XCTAssertEqual(events, [.chat(sender: "Remote", body: "just text body")])
    }

    func testParseEventsParsesNDATAMessageWithTrailingNul() {
        let packet = Data("oNDATAN0CALL>ping\r\n\0".utf8)
        let events = EchoLinkControlPacketCodec.parseEvents(from: packet)
        XCTAssertEqual(events, [.chat(sender: "N0CALL", body: "ping")])
    }

    func testParseEventsStripsFourByteNDATATrailerFromRemoteDisconnectReason() {
        var packet = Data("oNDATAKD6DIF-R>Exceeded key-down time\r\n".utf8)
        packet.append(contentsOf: [0x7B, 0x8D, 0x23, 0x8B])

        XCTAssertEqual(
            EchoLinkControlPacketCodec.parseEvents(from: packet),
            [.chat(sender: "KD6DIF-R", body: "Exceeded key-down time")]
        )
    }

    func testParseEventsStripsFourByteNDATATrailerContainingNul() {
        var packet = Data("oNDATAKD6DIF-R>Connection declined\r\n".utf8)
        packet.append(contentsOf: [0x7B, 0x00, 0x23, 0x8B])

        XCTAssertEqual(
            EchoLinkControlPacketCodec.parseEvents(from: packet),
            [.chat(sender: "KD6DIF-R", body: "Connection declined")]
        )
    }

    func testParseEventsPreservesShortFinalLineBeforeNulTerminator() {
        let packet = Data("oNDATA\rline1\r\nX\r\n\0".utf8)

        XCTAssertEqual(
            EchoLinkControlPacketCodec.parseEvents(from: packet),
            [.info("line1\r\nX")]
        )
    }

    func testParseEventsIgnoresUnknownBinaryControlPayload() {
        let packet = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: packet).isEmpty)
    }

    func testParseEventsIgnoresEmptyNDATAPayload() {
        let packet = Data("oNDATA\r".utf8)
        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: packet).isEmpty)
    }

    func testParseEventsHandlesVersion2RTCPFromRemote() {
        let packet = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N7XYZ", rtpVersion: 2)
        let events = EchoLinkControlPacketCodec.parseEvents(from: packet)
        XCTAssertEqual(events.count, 1)
        guard case .sdes(let sdes) = events[0] else {
            return XCTFail("Expected SDES")
        }
        XCTAssertEqual(sdes.preferredDisplayName, "N7XYZ")
    }

    private func makeMetadata(
        sequenceNumber: UInt16,
        timestamp: UInt32 = 0,
        ssrc: UInt32 = 0x12345678
    ) -> EchoLinkVoicePacketMetadata {
        EchoLinkVoicePacketMetadata(
            payloadType: 3,
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            ssrc: ssrc
        )
    }
}
