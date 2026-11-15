// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class EchoLinkAudioReorderBufferTests: XCTestCase {
    func testReordersPacketsThatFillAGap() {
        var buffer = EchoLinkAudioReorderBuffer()

        XCTAssertEqual(buffer.insert(packet(10), metadata: metadata(10), now: 0), [packet(10)])
        XCTAssertEqual(buffer.insert(packet(12), metadata: metadata(12), now: 0.001), [])
        XCTAssertEqual(buffer.insert(packet(11), metadata: metadata(11), now: 0.002), [packet(11), packet(12)])
        XCTAssertNil(buffer.nextDeadline)
        XCTAssertEqual(buffer.missingPacketCount, 0)
        XCTAssertEqual(buffer.deliveredSequencedPacketCount, 3)
    }

    func testMissingPacketExpiresAfterFortyMilliseconds() {
        var buffer = EchoLinkAudioReorderBuffer()

        XCTAssertEqual(buffer.insert(packet(10), metadata: metadata(10), now: 1), [packet(10)])
        XCTAssertEqual(buffer.insert(packet(12), metadata: metadata(12), now: 1.01), [])
        XCTAssertEqual(try XCTUnwrap(buffer.nextDeadline), 1.05, accuracy: 0.000_001)
        XCTAssertEqual(buffer.drain(now: 1.049), [])
        XCTAssertEqual(buffer.drain(now: 1.05), [packet(12)])
        XCTAssertNil(buffer.nextDeadline)
        XCTAssertEqual(buffer.missingPacketCount, 1)
        XCTAssertEqual(buffer.deliveredSequencedPacketCount, 2)
    }

    func testDuplicateAndLatePacketsAreDiscardedAfterGapFlush() {
        var buffer = EchoLinkAudioReorderBuffer()

        XCTAssertEqual(buffer.insert(packet(10), metadata: metadata(10), now: 0), [packet(10)])
        XCTAssertEqual(buffer.insert(packet(10), metadata: metadata(10), now: 0.01), [])
        XCTAssertEqual(buffer.insert(packet(12), metadata: metadata(12), now: 0.02), [])
        XCTAssertEqual(buffer.drain(now: 0.06), [packet(12)])
        XCTAssertEqual(buffer.insert(packet(11), metadata: metadata(11), now: 0.07), [])
        XCTAssertEqual(buffer.insert(packet(12), metadata: metadata(12), now: 0.08), [])
        XCTAssertEqual(buffer.duplicateOrLatePacketCount, 3)
        XCTAssertEqual(buffer.missingPacketCount, 1)
    }

    func testNativeHeadroomRecoversPacketBeyondDefaultDeadline() throws {
        var buffer = EchoLinkAudioReorderBuffer()
        _ = buffer.insert(packet(10), metadata: metadata(10), now: 1)
        _ = buffer.insert(packet(12), metadata: metadata(12), now: 1.01, playbackLeadSamples: 960)

        XCTAssertEqual(try XCTUnwrap(buffer.nextDeadline), 1.11, accuracy: 0.000_001)
        XCTAssertEqual(buffer.drain(now: 1.06), [])
        XCTAssertEqual(buffer.insert(packet(11), metadata: metadata(11), now: 1.07), [packet(11), packet(12)])
        XCTAssertNil(buffer.nextDeadline)
        XCTAssertEqual(buffer.missingPacketCount, 0)
        XCTAssertEqual(buffer.duplicateOrLatePacketCount, 0)
    }

    func testHeadroomWaitIsClampedAndStillExpires() throws {
        for (lead, wait) in [(Int.min, 0.04), (-1, 0.04), (0, 0.04), (320, 0.04),
                             (640, 0.06), (960, 0.10), (1120, 0.12), (Int.max, 0.12)] {
            var buffer = EchoLinkAudioReorderBuffer()
            _ = buffer.insert(packet(10), metadata: metadata(10), now: 0)
            _ = buffer.insert(packet(12), metadata: metadata(12), now: 0.01, playbackLeadSamples: lead)
            let deadline = try XCTUnwrap(buffer.nextDeadline)
            XCTAssertEqual(deadline, 0.01 + wait, accuracy: 0.000_001, "lead=\(lead)")
            XCTAssertEqual(buffer.drain(now: deadline - 0.000_001), [])
            XCTAssertEqual(buffer.drain(now: deadline), [packet(12)])
            XCTAssertEqual(buffer.missingPacketCount, 1)
            XCTAssertNil(buffer.nextDeadline)
        }
    }

    func testLaterArrivalsCannotExtendOrShortenAnExistingGapWait() throws {
        var buffer = EchoLinkAudioReorderBuffer()
        _ = buffer.insert(packet(10), metadata: metadata(10), now: 1)
        _ = buffer.insert(packet(12), metadata: metadata(12), now: 1.01, playbackLeadSamples: 800)
        _ = buffer.insert(packet(13), metadata: metadata(13), now: 1.02, playbackLeadSamples: 0)
        _ = buffer.insert(packet(14), metadata: metadata(14), now: 1.03, playbackLeadSamples: Int.max)

        XCTAssertEqual(try XCTUnwrap(buffer.nextDeadline), 1.09, accuracy: 0.000_001)
        XCTAssertEqual(buffer.drain(now: 1.089), [])
        XCTAssertEqual(buffer.drain(now: 1.09), [packet(12), packet(13), packet(14)])
        XCTAssertEqual(buffer.missingPacketCount, 1)
    }

    func testExtendedDeadlineRolloverAndDuplicateStillDeliverOnce() {
        var buffer = EchoLinkAudioReorderBuffer()
        _ = buffer.insert(packet(1), metadata: metadata(.max), now: 0)
        _ = buffer.insert(packet(3), metadata: metadata(1), now: 0.01, playbackLeadSamples: 960)
        XCTAssertEqual(buffer.insert(packet(3), metadata: metadata(1), now: 0.02,
            playbackLeadSamples: Int.max), [])
        XCTAssertEqual(buffer.drain(now: 0.06), [])
        XCTAssertEqual(buffer.insert(packet(2), metadata: metadata(0), now: 0.07), [packet(2), packet(3)])
        XCTAssertEqual(buffer.deliveredSequencedPacketCount, 3)
        XCTAssertEqual(buffer.duplicateOrLatePacketCount, 1)
        XCTAssertEqual(buffer.missingPacketCount, 0)
    }

    func testHeadroomDoesNotDelayInOrderPacketsOrOtherStreams() throws {
        var buffer = EchoLinkAudioReorderBuffer()
        XCTAssertEqual(buffer.insert(packet(10), metadata: metadata(10), now: 0,
            playbackLeadSamples: Int.max), [packet(10)])
        XCTAssertEqual(buffer.insert(packet(11), metadata: metadata(11), now: 0.01,
            playbackLeadSamples: Int.max), [packet(11)])
        _ = buffer.insert(packet(13), metadata: metadata(13), now: 0.02, playbackLeadSamples: 960)
        XCTAssertEqual(buffer.insert(packet(20), metadata: metadata(20, ssrc: 8), now: 0.03), [packet(20)])
        _ = buffer.insert(packet(22), metadata: metadata(22, ssrc: 8), now: 0.04)
        XCTAssertEqual(buffer.drain(now: 0.08), [packet(22)])
        XCTAssertEqual(try XCTUnwrap(buffer.nextDeadline), 0.12, accuracy: 0.000_001)
        XCTAssertEqual(buffer.drain(now: 0.12), [packet(13)])
    }

    func testResetAndInactivityDiscardExtendedDeadline() {
        var buffer = EchoLinkAudioReorderBuffer()
        _ = buffer.insert(packet(10), metadata: metadata(10), now: 0)
        _ = buffer.insert(packet(12), metadata: metadata(12), now: 0.01, playbackLeadSamples: Int.max)
        buffer.reset()
        XCTAssertNil(buffer.nextDeadline)
        _ = buffer.insert(packet(20), metadata: metadata(20), now: 1)
        _ = buffer.insert(packet(22), metadata: metadata(22), now: 1.01, playbackLeadSamples: Int.max)
        XCTAssertEqual(buffer.insert(packet(5), metadata: metadata(5), now: 3.02), [packet(5)])
        XCTAssertNil(buffer.nextDeadline)
        XCTAssertEqual(buffer.pendingPacketCount, 0)
        XCTAssertEqual(buffer.drain(now: 4), [])
    }

    func testSequenceNumbersWrap() {
        var buffer = EchoLinkAudioReorderBuffer()

        XCTAssertEqual(buffer.insert(packet(1), metadata: metadata(.max), now: 0), [packet(1)])
        XCTAssertEqual(buffer.insert(packet(3), metadata: metadata(1), now: 0.01), [])
        XCTAssertEqual(buffer.insert(packet(2), metadata: metadata(0), now: 0.02), [packet(2), packet(3)])
        XCTAssertEqual(buffer.missingPacketCount, 0)
        XCTAssertEqual(buffer.deliveredSequencedPacketCount, 3)
    }

    func testInactiveStreamStartsANewTalkSpurt() {
        var buffer = EchoLinkAudioReorderBuffer()

        XCTAssertEqual(buffer.insert(packet(1), metadata: metadata(100), now: 0), [packet(1)])
        XCTAssertEqual(buffer.insert(packet(2), metadata: metadata(90), now: 1), [])
        XCTAssertEqual(buffer.insert(packet(3), metadata: metadata(90), now: 2), [packet(3)])
        XCTAssertEqual(buffer.missingPacketCount, 0)
    }

    func testStreamsReorderIndependently() {
        var buffer = EchoLinkAudioReorderBuffer()

        XCTAssertEqual(buffer.insert(packet(1), metadata: metadata(10, ssrc: 1), now: 0), [packet(1)])
        XCTAssertEqual(buffer.insert(packet(2), metadata: metadata(20, ssrc: 2), now: 0), [packet(2)])
        XCTAssertEqual(buffer.insert(packet(4), metadata: metadata(12, ssrc: 1), now: 0.01), [])
        XCTAssertEqual(buffer.insert(packet(5), metadata: metadata(21, ssrc: 2), now: 0.02), [packet(5)])
        XCTAssertEqual(buffer.insert(packet(3), metadata: metadata(11, ssrc: 1), now: 0.03), [packet(3), packet(4)])
    }

    func testResetDropsPendingPacketsAndSequenceHistory() {
        var buffer = EchoLinkAudioReorderBuffer()

        _ = buffer.insert(packet(1), metadata: metadata(10), now: 0)
        _ = buffer.insert(packet(2), metadata: metadata(12), now: 0.01)
        buffer.reset()
        XCTAssertEqual(buffer.missingPacketCount, 0)
        XCTAssertEqual(buffer.duplicateOrLatePacketCount, 0)
        XCTAssertEqual(buffer.deliveredSequencedPacketCount, 0)
        XCTAssertNil(buffer.nextDeadline)
        XCTAssertEqual(buffer.drain(now: 1), [])
        XCTAssertEqual(buffer.insert(packet(3), metadata: metadata(5), now: 1), [packet(3)])
    }

    func testMissingMetadataBypassesReordering() {
        var buffer = EchoLinkAudioReorderBuffer()

        XCTAssertEqual(buffer.insert(packet(1), metadata: nil, now: 0), [packet(1)])
        XCTAssertEqual(buffer.insert(packet(2), metadata: nil, now: 0), [packet(2)])
        XCTAssertNil(buffer.nextDeadline)
    }

    func testPendingQueueIsBoundedUnderSequenceFlood() {
        var buffer = EchoLinkAudioReorderBuffer()
        var emitted = buffer.insert(packet(1), metadata: metadata(1), now: 0)

        for sequence: UInt16 in 3...100 {
            emitted += buffer.insert(packet(UInt8(truncatingIfNeeded: sequence)), metadata: metadata(sequence), now: 0.001)
        }

        XCTAssertFalse(emitted.isEmpty)
        XCTAssertLessThanOrEqual(buffer.pendingPacketCount, 4)
    }

    func testTracksAtMostThirtyTwoStreams() {
        var buffer = EchoLinkAudioReorderBuffer()

        for ssrc: UInt32 in 1...40 {
            _ = buffer.insert(packet(UInt8(truncatingIfNeeded: ssrc)), metadata: metadata(1, ssrc: ssrc), now: TimeInterval(ssrc))
        }

        XCTAssertLessThanOrEqual(buffer.trackedStreamCount, 32)
    }

    private func packet(_ byte: UInt8) -> Data { Data([byte]) }

    private func metadata(_ sequence: UInt16, ssrc: UInt32 = 7) -> EchoLinkVoicePacketMetadata {
        EchoLinkVoicePacketMetadata(payloadType: 3, sequenceNumber: sequence, timestamp: 0, ssrc: ssrc)
    }
}
