// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class LiveTransportMessageBufferTests: XCTestCase {
    func testMetricsDistinguishCapacityAndAgeDropsUsingInjectedClock() async throws {
        var clock = 10.0
        let buffer = LiveTransportMessageBuffer<Int>(voiceCapacity: 2, now: { clock })
        buffer.yield(1, kind: .voice)
        buffer.yield(99, kind: .control)
        clock = 10.1
        buffer.yield(2, kind: .voice)
        clock = 10.2
        buffer.yield(3, kind: .voice)
        let full = buffer.metricsSnapshot
        XCTAssertEqual(full.acceptedVoiceMessages, 3)
        XCTAssertEqual(full.capacityDroppedVoiceMessages, 1)
        XCTAssertEqual(full.ageDroppedVoiceMessages, 0)
        XCTAssertEqual(full.queuedVoiceMessages, 2)
        XCTAssertEqual(full.queuedMessages, 3)
        XCTAssertEqual(full.maximumQueuedVoiceMessages, 2)
        XCTAssertEqual(full.maximumQueuedMessages, 3)
        XCTAssertEqual(full.maximumObservedVoiceWaitAgeSeconds, 0.2, accuracy: 0.000_001)

        clock = 10.5
        buffer.finish()
        let control = try await buffer.next()
        XCTAssertEqual(control, 99)
        let drained = buffer.metricsSnapshot
        XCTAssertEqual(drained.capacityDroppedVoiceMessages, 1)
        XCTAssertEqual(drained.ageDroppedVoiceMessages, 2)
        XCTAssertEqual(drained.queuedVoiceMessages, 0)
        XCTAssertEqual(drained.queuedMessages, 0)
        XCTAssertEqual(drained.maximumObservedVoiceWaitAgeSeconds, 0.4, accuracy: 0.000_001)
        XCTAssertFalse(buffer.yield(4, kind: .voice))
        XCTAssertEqual(buffer.metricsSnapshot.acceptedVoiceMessages, 3,
                       "Terminal rejection is not an accepted voice message")
    }

    func testReadingMetricsDoesNotExpireQueuedVoice() async throws {
        var clock = 0.0
        let buffer = LiveTransportMessageBuffer<Int>(now: { clock })
        buffer.yield(1, kind: .voice)
        clock = 1
        let unread = buffer.metricsSnapshot
        XCTAssertEqual(unread.queuedVoiceMessages, 1)
        XCTAssertEqual(unread.ageDroppedVoiceMessages, 0)
        XCTAssertEqual(unread.maximumObservedVoiceWaitAgeSeconds, 0)
        buffer.finish()
        let end = try await buffer.next()
        XCTAssertNil(end)
        XCTAssertEqual(buffer.metricsSnapshot.ageDroppedVoiceMessages, 1)
        XCTAssertEqual(buffer.metricsSnapshot.maximumObservedVoiceWaitAgeSeconds, 1)
    }

    func testEligibleVoiceDequeueRecordsWaitWithoutDrop() async throws {
        var clock = 0.0
        let buffer = LiveTransportMessageBuffer<Int>(now: { clock })
        buffer.yield(1, kind: .voice)
        clock = 0.24
        let voice = try await buffer.next()
        XCTAssertEqual(voice, 1)
        let metrics = buffer.metricsSnapshot
        XCTAssertEqual(metrics.acceptedVoiceMessages, 1)
        XCTAssertEqual(metrics.capacityDroppedVoiceMessages, 0)
        XCTAssertEqual(metrics.ageDroppedVoiceMessages, 0)
        XCTAssertEqual(metrics.maximumObservedVoiceWaitAgeSeconds, 0.24)
        XCTAssertEqual(metrics.queuedMessages, 0)
    }

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
