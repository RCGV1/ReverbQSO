// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class GSMCodecStreamingTests: XCTestCase {

    func testEncodeRequiresFullFrameBeforeOutput() {
        let codec = GSMCodec()
        let halfFrameA = [Int16](repeating: 100, count: GSMCodec.samplesPerFrame / 2)
        let halfFrameB = [Int16](repeating: 200, count: GSMCodec.samplesPerFrame / 2)

        let first = codec.encode(halfFrameA)
        let second = codec.encode(halfFrameB)

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.count, 4 + GSMCodec.encodedFrameSize)
    }

    func testDecodeRequiresFullFrameBeforeOutput() {
        let codec = GSMCodec()
        let source = [Int16](repeating: 300, count: GSMCodec.samplesPerFrame)
        let packet = codec.encode(source)
        let payload = GSMCodec.stripHeader(packet) ?? Data()
        XCTAssertEqual(payload.count, GSMCodec.encodedFrameSize)

        let partA = Data(payload.prefix(10))
        let partB = Data(payload.dropFirst(10))

        let first = codec.decode(partA)
        let second = codec.decode(partB)

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.count, GSMCodec.samplesPerFrame)
    }

    func testDecodeAcceptsRawPayloadWithoutHeader() {
        let codec = GSMCodec()
        let source = [Int16](repeating: 400, count: GSMCodec.samplesPerFrame)
        let packet = codec.encode(source)
        let payload = GSMCodec.stripHeader(packet) ?? Data()

        let decoded = codec.decode(payload)
        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame)
    }

    func testEncodeMultipleFramesProducesSingleHeaderAndContiguousPayload() {
        let codec = GSMCodec()
        let source = [Int16](repeating: 700, count: GSMCodec.samplesPerFrame * 2)

        let packet = codec.encode(source)
        XCTAssertEqual(Array(packet.prefix(4)), GSMCodec.packetHeader)
        XCTAssertEqual(packet.count, 4 + (2 * GSMCodec.encodedFrameSize))
    }

    func testDecodeMultipleFramesFromSinglePayload() {
        let codec = GSMCodec()
        let source = [Int16](repeating: 900, count: GSMCodec.samplesPerFrame * 2)
        let packet = codec.encode(source)
        let payload = GSMCodec.stripHeader(packet) ?? Data()

        let decoded = codec.decode(payload)
        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame * 2)
    }

    func testHeaderOnlyPacketDoesNotPolluteDecodeState() {
        let codec = GSMCodec()
        let headerOnly = Data(GSMCodec.packetHeader)

        let first = codec.decode(headerOnly)
        XCTAssertTrue(first.isEmpty)

        let source = [Int16](repeating: 500, count: GSMCodec.samplesPerFrame)
        let packet = codec.encode(source)
        let decoded = codec.decode(packet)
        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame)
    }

    func testWrapAndStripHeaderRoundTrip() {
        let payload = Data(repeating: 0x42, count: GSMCodec.encodedFrameSize)
        let wrapped = GSMCodec.wrapWithHeader(payload)
        let stripped = GSMCodec.stripHeader(wrapped)

        XCTAssertEqual(stripped, payload)
    }

    func testStripHeaderAcceptsHeaderOnlyPacket() {
        let headerOnly = Data(GSMCodec.packetHeader)
        let stripped = GSMCodec.stripHeader(headerOnly)
        XCTAssertEqual(stripped, Data())
    }

    // MARK: - decodePacket (per-packet decode without remainder carry-over)

    func testDecodePacketDiscardsStaleRemainder() {
        let codec = GSMCodec()

        // Feed a partial frame via streaming decode to plant stale bytes.
        let source = [Int16](repeating: 100, count: GSMCodec.samplesPerFrame)
        let packet = codec.encode(source)
        let payload = GSMCodec.stripHeader(packet) ?? Data()
        let partialFrame = Data(payload.prefix(10))
        _ = codec.decode(partialFrame) // plants 10 stale bytes

        // Now decode a full packet via decodePacket — stale bytes must be discarded.
        let fullPacket = codec.encode([Int16](repeating: 200, count: GSMCodec.samplesPerFrame))
        let fullPayload = GSMCodec.stripHeader(fullPacket) ?? Data()
        let decoded = codec.decodePacket(fullPayload)
        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame)
    }

    func testDecodePacketCompletesFullFrameWithoutTrailingRemainder() {
        let codec = GSMCodec()
        let source = [Int16](repeating: 300, count: GSMCodec.samplesPerFrame * 2)
        let packet = codec.encode(source)
        let payload = GSMCodec.stripHeader(packet) ?? Data()

        // decodePacket should handle multi-frame payloads just like decode.
        let decoded = codec.decodePacket(payload)
        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame * 2)
    }

    func testDecodePacketWithBEEFHeaderStillWorks() {
        let codec = GSMCodec()
        let source = [Int16](repeating: 500, count: GSMCodec.samplesPerFrame)
        let packet = codec.encode(source) // includes BEEF header
        let decoded = codec.decodePacket(packet)
        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame)
    }

    // MARK: - Reset Methods

    func testResetEncodeStateClearsRemainder() {
        let codec = GSMCodec()
        let halfFrame = [Int16](repeating: 100, count: GSMCodec.samplesPerFrame / 2)
        let first = codec.encode(halfFrame)
        XCTAssertTrue(first.isEmpty) // not enough for a frame

        // Reset should discard the partial samples.
        codec.resetEncodeState()

        // Encoding another half frame should NOT produce output
        // (the previous half frame was discarded).
        let second = codec.encode(halfFrame)
        XCTAssertTrue(second.isEmpty)
    }

    func testResetDecodeStateClearsRemainder() {
        let codec = GSMCodec()
        let source = [Int16](repeating: 100, count: GSMCodec.samplesPerFrame)
        let packet = codec.encode(source)
        let payload = GSMCodec.stripHeader(packet) ?? Data()

        // Feed a partial frame.
        _ = codec.decode(Data(payload.prefix(10)))
        codec.resetDecodeState()

        // Feeding the remaining bytes should NOT produce output
        // (the initial partial was discarded).
        let result = codec.decode(Data(payload.dropFirst(10)))
        XCTAssertTrue(result.isEmpty)
    }

    func testResetAllClearsBothRemainderBuffers() {
        let codec = GSMCodec()
        // Plant encode remainder.
        _ = codec.encode([Int16](repeating: 50, count: 1))
        // Plant decode remainder.
        _ = codec.decode(Data([0x01, 0x02]))

        codec.resetAll()

        // After reset, a fresh full encode→decode cycle should work.
        let source = [Int16](repeating: 600, count: GSMCodec.samplesPerFrame)
        let packet = codec.encode(source)
        let payload = GSMCodec.stripHeader(packet) ?? Data()
        XCTAssertEqual(payload.count, GSMCodec.encodedFrameSize)

        let decoded = codec.decode(payload)
        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame)
    }
}
