// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class ReceiveAdaptivePlayoutBufferTests: XCTestCase {
    func testReadySpeechWaitsForPlaybackRoomInsteadOfBeingDiscarded() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        let first = [Int16](repeating: 10, count: 640)
        let second = [Int16](repeating: 20, count: 640)
        buffer.enqueue(first, now: 0)
        buffer.enqueue(second, now: 0.01)
        XCTAssertEqual(buffer.drain(now: 0.05, maximumSamples: 639), [])
        XCTAssertEqual(buffer.pendingSampleCount, 1280)
        XCTAssertEqual(buffer.drain(now: 0.06, maximumSamples: 640), [first])
        XCTAssertEqual(buffer.drain(now: 0.08, maximumSamples: 640), [second])
        XCTAssertEqual(buffer.discardedPackets, 0)
    }

    func testOutputStallStillExpiresSpeechEvenWithNoAvailableCapacity() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        buffer.enqueue([Int16](repeating: 10, count: 640), now: 0)
        XCTAssertEqual(buffer.drain(now: 0.25, maximumSamples: 0), [])
        XCTAssertEqual(buffer.pendingSampleCount, 0)
        XCTAssertEqual(buffer.discardedPackets, 1)
    }

    func testStartupBuffersFortyMillisecondsThenPreservesPacket() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        let samples = [Int16](repeating: 123, count: 640)
        buffer.enqueue(samples, now: 0)
        XCTAssertEqual(buffer.drain(now: 0.039), [])
        XCTAssertEqual(buffer.drain(now: 0.040), [samples])
    }

    func testUnevenArrivalsIncreaseTargetAndStableTimingRecovers() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        let packet = [Int16](repeating: 100, count: 640)
        var now = 0.0
        for index in 0..<40 {
            buffer.enqueue(packet, now: now)
            _ = buffer.drain(now: now + 0.12)
            now += index.isMultiple(of: 2) ? 0.04 : 0.12
        }
        let disturbed = buffer.targetDelay
        XCTAssertGreaterThan(disturbed, 0.05)
        for _ in 0..<300 {
            buffer.enqueue(packet, now: now)
            _ = buffer.drain(now: now + 0.12)
            now += 0.08
        }
        XCTAssertLessThan(buffer.targetDelay, disturbed)
        XCTAssertLessThan(buffer.targetDelay, 0.045)
    }

    func testFloodKeepsNewestSpeechAndBoundsLatency() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        for index in 0..<1000 {
            buffer.enqueue([Int16](repeating: Int16(index), count: 640), now: 0)
        }
        XCTAssertLessThanOrEqual(buffer.pendingSampleCount, 3840)
        XCTAssertGreaterThan(buffer.discardedPackets, 0)
        XCTAssertEqual(buffer.drain(now: 0.239).last?.first, 999)
    }

    func testStalledPlaybackDiscardsExpiredSpeech() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        buffer.enqueue([Int16](repeating: 900, count: 640), now: 0)
        XCTAssertEqual(buffer.drain(now: 0.5), [])
        XCTAssertNil(buffer.nextDeadline)
    }

    func testStartupBurstWaitsFortyMillisecondsWithoutDiscardingIntactPackets() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        let packets = (0..<6).map { [Int16](repeating: Int16($0), count: 640) }
        for packet in packets { buffer.enqueue(packet, now: 0) }
        XCTAssertTrue(buffer.drain(now: 0.039, maximumSamples: 2560).isEmpty)
        XCTAssertEqual(buffer.drain(now: 0.040, maximumSamples: 2560), Array(packets.prefix(4)))
        XCTAssertEqual(buffer.drain(now: 0.120, maximumSamples: 640), [packets[4]])
        XCTAssertEqual(buffer.drain(now: 0.200, maximumSamples: 640), [packets[5]])
        XCTAssertEqual(buffer.discardedPackets, 0)
    }

    func testTalkSpurtPauseStartsWithFreshJitterProtection() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        let packet = [Int16](repeating: 99, count: 640)
        buffer.enqueue(packet, now: 0)
        _ = buffer.drain(now: 0.04)
        buffer.enqueue(packet, now: 0.6)
        XCTAssertTrue(buffer.drain(now: 0.639).isEmpty)
        XCTAssertEqual(buffer.drain(now: 0.641), [packet])
    }
    func testConcealmentDoesNotChangeNetworkPacketDuration() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        let packet = [Int16](repeating: 100, count: 640)
        buffer.enqueue(packet, now: 0)
        _ = buffer.drain(now: 0.04)
        buffer.enqueue(packet + packet, networkSampleCount: 640, now: 0.08)
        _ = buffer.drain(now: 0.12)
        buffer.enqueue(packet, now: 0.16)
        XCTAssertEqual(buffer.targetDelay, 0.04, accuracy: 0.000001)
    }
    func testJitterTraceHasFewerRenderedGapsThanImmediatePlayback() {
        let packet = [Int16](repeating: 100, count: 640)
        let arrivals = (0..<100).map { Double($0) * 0.08 + ($0.isMultiple(of: 2) ? 0 : 0.04) }
        var baselineEnd = 0.0
        var baselineGaps = 0.0
        for arrival in arrivals {
            baselineGaps += max(0, arrival - baselineEnd)
            baselineEnd = max(arrival, baselineEnd) + 0.08
        }
        var buffer = ReceiveAdaptivePlayoutBuffer()
        var renderEnd = 0.0
        var gaps = 0.0
        var received = 0
        var played = 0
        var maximumDelay = 0.0
        var receivedTimes: [Double] = []
        for tick in 0...8300 {
            let now = Double(tick) / 1000
            while received < arrivals.count && arrivals[received] <= now + 0.0000001 {
                buffer.enqueue(packet, now: now)
                receivedTimes.append(now)
                received += 1
            }
            for samples in buffer.drain(now: now) {
                if played > 0 { gaps += max(0, now - renderEnd) }
                let start = max(now, renderEnd)
                maximumDelay = max(maximumDelay, start - receivedTimes[played])
                renderEnd = start + Double(samples.count) / 8000
                played += 1
            }
        }
        XCTAssertEqual(played, 100)
        XCTAssertLessThan(gaps, baselineGaps * 0.3)
        XCTAssertLessThanOrEqual(maximumDelay, 0.141)
    }

    func testTalkSpurtResetsTimingAndResetDropsPendingAudio() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        buffer.enqueue([1, 2, 3], now: 0)
        buffer.reset()
        XCTAssertEqual(buffer.drain(now: 1), [])
        buffer.enqueue([4, 5, 6], now: 1)
        XCTAssertEqual(buffer.drain(now: 1.041), [[4, 5, 6]])
    }
    func testContinuousPacketAfter160MillisecondsDoesNotRestartStartupDelay() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        let packet = [Int16](repeating: 100, count: 640)
        buffer.enqueue(packet, now: 0)
        XCTAssertEqual(buffer.drain(now: 0.04), [packet])
        buffer.enqueue(packet, now: 0.161)
        XCTAssertEqual(buffer.drain(now: 0.161), [packet])
        XCTAssertGreaterThan(buffer.targetDelay, 0.04)
    }

    func testJitterGrowthDoesNotDelaySpeechWhenPlaybackIsDepleted() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        let packet = [Int16](repeating: 100, count: 640)
        buffer.enqueue(packet, now: 0)
        _ = buffer.drain(now: 0.04)
        buffer.enqueue(packet, now: 0.145)
        XCTAssertGreaterThan(buffer.targetDelay, 0.04)
        XCTAssertEqual(buffer.drain(now: 0.145), [packet])
    }

    func testContinuousSpeechSchedulesImmediatelyEvenAsJitterGrows() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        let packet = [Int16](repeating: 100, count: 640)
        buffer.enqueue(packet, now: 0)
        XCTAssertEqual(buffer.drain(now: 0.039), [])
        XCTAssertEqual(buffer.drain(now: 0.040), [packet])
        // Continuing speech must not be deferred onto a timer just because
        // its arrival interval increased the jitter estimate.
        buffer.enqueue(packet, now: 0.145)
        XCTAssertGreaterThan(buffer.targetDelay, 0.04)
        XCTAssertEqual(buffer.drain(now: 0.145), [packet])
    }

    func testJitterGrowthWaitDoesNotExceedExistingPlaybackCoverage() {
        var buffer = ReceiveAdaptivePlayoutBuffer()
        let packet = [Int16](repeating: 100, count: 640)
        buffer.enqueue(packet, now: 0)
        _ = buffer.drain(now: 0.04)
        buffer.enqueue(packet, now: 0.145)
        XCTAssertLessThanOrEqual(buffer.nextDeadline ?? .infinity, 0.147)
    }

}
