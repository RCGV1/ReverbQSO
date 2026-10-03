// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class LiveTransportMessageBufferTests: XCTestCase {
    func testAudioPortClassifierPreservesRTCPAndNDATABeforeVoiceParsing() {
        let bye = EchoLinkControlPacketCodec.buildBYEPacket()
        let ndata = EchoLinkControlPacketCodec.buildNDATAInfoPacket(message: "Online")
        XCTAssertEqual(LiveTransportAudioPortPayloadKind.classify(bye), .control)
        XCTAssertEqual(LiveTransportAudioPortPayloadKind.classify(ndata), .control)
    }

    func testBlockedConsumerKeepsFourNewestVoiceMessages() async throws {
        let buffer = LiveTransportMessageBuffer<Int>()
        for value in 1...1_000 {
            XCTAssertTrue(buffer.yield(value, kind: .voice))
        }
        buffer.finish()

        var received: [Int] = []
        while let value = try await buffer.next() { received.append(value) }
        XCTAssertEqual(received, [997, 998, 999, 1_000])
    }

    func testControlAndByeSurviveVoiceFloodInRetainedOrder() async throws {
        let buffer = LiveTransportMessageBuffer<String>()
        XCTAssertTrue(buffer.yield("SDES", kind: .control))
        for value in 1...20 { XCTAssertTrue(buffer.yield("voice-\(value)", kind: .voice)) }
        XCTAssertTrue(buffer.yield("BYE", kind: .control))
        buffer.finish()

        var received: [String] = []
        while let value = try await buffer.next() { received.append(value) }
        XCTAssertEqual(received, ["SDES", "voice-17", "voice-18", "voice-19", "voice-20", "BYE"])
    }

    func testNormalTrafficRemainsFIFO() async throws {
        let buffer = LiveTransportMessageBuffer<String>()
        XCTAssertTrue(buffer.yield("control-1", kind: .control))
        XCTAssertTrue(buffer.yield("voice-1", kind: .voice))
        XCTAssertTrue(buffer.yield("control-2", kind: .control))
        XCTAssertTrue(buffer.yield("voice-2", kind: .voice))
        buffer.finish()

        var received: [String] = []
        while let value = try await buffer.next() { received.append(value) }
        XCTAssertEqual(received, ["control-1", "voice-1", "control-2", "voice-2"])
    }

    func testStaleVoiceExpiresButControlSurvivesConsumerStall() async throws {
        var now = 0.0
        let buffer = LiveTransportMessageBuffer<String>(now: { now })
        XCTAssertTrue(buffer.yield("voice-old", kind: .voice))
        XCTAssertTrue(buffer.yield("BYE", kind: .control))
        now = 0.241
        XCTAssertTrue(buffer.yield("voice-new", kind: .voice))
        buffer.finish()

        let first = try await buffer.next()
        let second = try await buffer.next()
        let end = try await buffer.next()
        XCTAssertEqual(first, "BYE")
        XCTAssertEqual(second, "voice-new")
        XCTAssertNil(end)
    }

    func testVoiceAtExactMaximumAgeRemainsEligible() async throws {
        var now = 0.0
        let buffer = LiveTransportMessageBuffer<Int>(now: { now })
        buffer.yield(1, kind: .voice)
        now = 0.24
        buffer.finish()
        let value = try await buffer.next()
        XCTAssertEqual(value, 1)
    }

    func testReplacingSubscriberRetiresOnlyOldBuffer() async throws {
        var active: LiveTransportMessageBuffer<Int>? = LiveTransportMessageBuffer()
        let old = active!
        old.yield(1, kind: .voice)
        active?.finish(throwing: CancellationError())
        let replacement = LiveTransportMessageBuffer<Int>()
        active = replacement
        replacement.yield(2, kind: .voice)

        let oldValue = try await old.next()
        XCTAssertEqual(oldValue, 1)
        do {
            _ = try await old.next()
            XCTFail("Expected replaced subscriber cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let replacementValue = try await active?.next()
        XCTAssertEqual(replacementValue, 2)
    }

    func testControlFloodFinishesWithErrorAfterBufferedMessages() async throws {
        let buffer = LiveTransportMessageBuffer<Int>(controlCapacity: 3)
        XCTAssertTrue(buffer.yield(1, kind: .control))
        XCTAssertTrue(buffer.yield(2, kind: .control))
        XCTAssertTrue(buffer.yield(3, kind: .control))
        XCTAssertFalse(buffer.yield(4, kind: .control))

        let first = try await buffer.next()
        let second = try await buffer.next()
        let third = try await buffer.next()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 3)
        do {
            _ = try await buffer.next()
            XCTFail("Expected control overflow")
        } catch {
            XCTAssertEqual(error as? LiveTransportMessageBufferError, .controlOverflow)
        }
    }

    func testCancellationResumesBlockedConsumerAndFinishPreservesError() async {
        let cancellationObserved = expectation(description: "consumer cancellation callback")
        let cancelled = LiveTransportMessageBuffer<Int>(
            onConsumerCancellation: { cancellationObserved.fulfill() }
        )
        let task = Task { try await cancelled.next() }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [cancellationObserved], timeout: 1)

        enum TestError: Error { case failed }
        let failed = LiveTransportMessageBuffer<Int>()
        failed.finish(throwing: TestError.failed)
        do {
            _ = try await failed.next()
            XCTFail("Expected finish error")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }
}
