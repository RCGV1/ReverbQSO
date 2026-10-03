// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class VoiceTransmitQueueTests: XCTestCase {
    func testBlockedConsumerKeepsOnlyThreeNewestPacketsInMediaOrder() {
        var now = 0.0
        var queue = VoiceTransmitQueue<Int>(now: { now })

        for packet in 1...6 {
            queue.enqueue(packet)
            now += 0.01
        }

        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.discardedCount, 3)
        XCTAssertEqual(queue.dequeue(), 4)
        XCTAssertEqual(queue.dequeue(), 5)
        XCTAssertEqual(queue.dequeue(), 6)
        XCTAssertTrue(queue.isEmpty)
    }

    func testDequeueSkipsExpiredPacketsBeforeReturningFreshPacket() {
        var now = 1.0
        var queue = VoiceTransmitQueue<String>(now: { now })
        queue.enqueue("expired", insertedAt: 0.70)
        queue.enqueue("fresh", insertedAt: 0.90)

        XCTAssertEqual(queue.dequeue(), "fresh")
        XCTAssertEqual(queue.discardedCount, 1)
    }

    func testPacketAtExactMaximumAgeRemainsEligible() {
        var queue = VoiceTransmitQueue<Int>(now: { 0.24 })
        queue.enqueue(7, insertedAt: 0)

        XCTAssertEqual(queue.dequeue(), 7)
        XCTAssertEqual(queue.discardedCount, 0)
    }

    func testRemoveAllClearsPriorSessionWithoutChangingDiscardAccounting() {
        var queue = VoiceTransmitQueue<Data>()
        queue.enqueue(Data([1]))
        queue.enqueue(Data([2]))
        queue.removeAll(keepingCapacity: true)

        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.dequeue())

        queue.enqueue(Data([3]))
        XCTAssertEqual(queue.dequeue(), Data([3]))
        XCTAssertEqual(queue.discardedCount, 0)
    }

    func testRepeatedEnqueueNeverGrowsBeyondCapacity() {
        var queue = VoiceTransmitQueue<Int>(now: { 0 })
        for packet in 0..<10_000 {
            queue.enqueue(packet)
            XCTAssertLessThanOrEqual(queue.count, 3)
        }

        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.discardedCount, 9_997)
        XCTAssertEqual(queue.dequeue(), 9_997)
        XCTAssertEqual(queue.dequeue(), 9_998)
        XCTAssertEqual(queue.dequeue(), 9_999)
    }
}
