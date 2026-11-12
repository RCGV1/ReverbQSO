// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO
final class ReceiveSpeechSmootherTests: XCTestCase {
    func testLossBurstReservesQueuedSpeechAndKeepsReturningPacketIntact() {
        let smoother = ReceiveSpeechSmoother()
        let queue = ReceivePlaybackQueue()
        let packet = [Int16](repeating: 1000, count: 640)
        _ = smoother.process(packet, metadata: metadata(1), now: 0)
        let returning = [Int16](repeating: 2000, count: 640)
        let budget = queue.concealmentSampleBudget(receivedSamples: returning.count,
            remainingSamples: 320, pendingSamples: 160)
        let recovered = smoother.process(returning, metadata: metadata(4), now: 0.24,
            maximumConcealmentSamples: budget)
        XCTAssertEqual(recovered.count, 800)
        XCTAssertEqual(Array(recovered.suffix(560)), Array(returning.suffix(560)))
        XCTAssertEqual(recovered.count + 320 + 160, queue.recoverySamples)
        let next = smoother.process(returning, metadata: metadata(5), now: 0.32)
        XCTAssertEqual(next, returning)
    }

    func testFullRealSpeechQueueDoesNotAcquireSyntheticDelay() {
        let smoother = ReceiveSpeechSmoother()
        let packet = [Int16](repeating: 1000, count: 640)
        _ = smoother.process(packet, metadata: metadata(1), now: 0)
        let recovered = smoother.process(packet, metadata: metadata(3), now: 0.16,
            maximumConcealmentSamples: 0)
        XCTAssertEqual(recovered.count, packet.count)
        XCTAssertEqual(Array(recovered.suffix(560)), Array(packet.suffix(560)))
    }

    func testBudgetedLossSplicesStayContinuousAcrossPhasesAndPolarities() {
        for payload: UInt8 in [0, 3] {
            for phase in [0.0, Double.pi / 2] {
                for polarity in [-1.0, 1.0] {
                    let packet: [Int16] = (0..<640).map { index in
                        Int16((polarity * 16_000 * sin(2 * .pi * 100 * Double(index) / 8_000 + phase)).rounded())
                    }
                    for returning in [packet, packet.map { -$0 }] {
                        for distance: UInt16 in [2, 3] {
                            for budget in [Int.min, -1, 0, 1, 16, 160, 640, 1_280, Int.max] {
                                let smoother = ReceiveSpeechSmoother()
                                let context = "payload=\(payload) phase=\(phase) polarity=\(polarity) distance=\(distance) budget=\(budget)"
                                let prior = smoother.process(packet, metadata: metadata(100, payload: payload), now: 0)
                                let recovered = smoother.process(returning,
                                    metadata: metadata(100 + distance, payload: payload), now: 0.01,
                                    maximumConcealmentSamples: budget)
                                let retainedCount = min(max(0, budget), Int(distance - 1) * packet.count)

                                XCTAssertEqual(prior, packet)
                                XCTAssertEqual(recovered.count, retainedCount + returning.count, context)
                                XCTAssertLessThanOrEqual(abs(Int(prior.last!) - Int(recovered[0])), 1_000, context)
                                let preceding = retainedCount > 0 ? recovered[retainedCount - 1] : prior.last!
                                XCTAssertLessThanOrEqual(abs(Int(preceding) - Int(recovered[retainedCount])), 400, context)
                                XCTAssertLessThanOrEqual(recovered.map { abs(Int($0)) }.max()!, 16_000, context)
                                XCTAssertEqual(Array(recovered.dropFirst(retainedCount + 80)),
                                    Array(returning.dropFirst(80)), context)
                                XCTAssertEqual(smoother.process(returning,
                                    metadata: metadata(101 + distance, payload: payload), now: 0.02), returning, context)
                            }
                        }
                    }
                }
            }
        }
    }

    func testFullAndOversizedBudgetsMatchDefaultRecoveryExactly() {
        let packet = (0..<640).map { Int16(8_000 * sin(Double($0) * .pi / 40)) }
        let returning = packet.map { -$0 }
        let reference = ReceiveSpeechSmoother()
        _ = reference.process(packet, metadata: metadata(100), now: 0)
        let expected = reference.process(returning, metadata: metadata(103), now: 0.01)

        for budget in [1_280, Int.max] {
            let smoother = ReceiveSpeechSmoother()
            _ = smoother.process(packet, metadata: metadata(100), now: 0)
            XCTAssertEqual(smoother.process(returning, metadata: metadata(103), now: 0.01,
                maximumConcealmentSamples: budget), expected)
        }
    }

    func testCleanPacketsRemainBitIdenticalRegardlessOfConcealmentBudget() {
        let packet = (0..<640).map { Int16(8_000 * sin(Double($0) * .pi / 40)) }
        let returning = packet.map { -$0 }
        for budget in [Int.min, -1, 0, 160, 640, 1_280, Int.max] {
            let smoother = ReceiveSpeechSmoother()
            XCTAssertEqual(smoother.process(packet, metadata: metadata(100), now: 0,
                maximumConcealmentSamples: budget), packet)
            XCTAssertEqual(smoother.process([], metadata: metadata(102), now: 0.005,
                maximumConcealmentSamples: budget), [])
            XCTAssertEqual(smoother.process(returning, metadata: metadata(101), now: 0.01,
                maximumConcealmentSamples: budget), returning)
        }
    }

    private func metadata(_ sequence: UInt16, ssrc: UInt32 = 1, payload: UInt8 = 3) -> EchoLinkVoicePacketMetadata {
        .init(payloadType: payload, sequenceNumber: sequence, timestamp: 0, ssrc: ssrc)
    }
    func testConfirmedShortLossAddsOnlyMissingDuration() {
        let smoother = ReceiveSpeechSmoother()
        let voiced = (0..<640).map { Int16(8000 * sin(Double($0) * .pi / 40)) }
        XCTAssertEqual(smoother.process(voiced, metadata: metadata(1), now: 0), voiced)
        let after = smoother.process(voiced, metadata: metadata(3), now: 0.16)
        XCTAssertEqual(after.count, 1280)
        XCTAssertTrue(after.prefix(640).contains { $0 != 0 })
    }
    func testTimestampGapHandlesVariablePacketDuration() {
        let smoother = ReceiveSpeechSmoother()
        _ = smoother.process([Int16](repeating: 1000, count: 640), metadata:
            .init(payloadType: 3, sequenceNumber: 1, timestamp: 100, ssrc: 1), now: 0)
        let output = smoother.process([Int16](repeating: 2000, count: 160), metadata:
            .init(payloadType: 3, sequenceNumber: 3, timestamp: 900, ssrc: 1), now: 0.1)
        XCTAssertEqual(output.count, 320) // 160 lost + 160 received
    }
    func testLegacyIncrementingTimestampFallsBackToPacketDuration() {
        let smoother = ReceiveSpeechSmoother()
        _ = smoother.process([Int16](repeating: 1000, count: 640), metadata:
            .init(payloadType: 3, sequenceNumber: 1, timestamp: 1, ssrc: 1), now: 0)
        let output = smoother.process([Int16](repeating: 2000, count: 640), metadata:
            .init(payloadType: 3, sequenceNumber: 3, timestamp: 3, ssrc: 1), now: 0.1)
        XCTAssertEqual(output.count, 1280)
    }
    func testLongGapOrTalkerChangeDoesNotReplayOldSpeech() {
        let smoother = ReceiveSpeechSmoother()
        let voiced = [Int16](repeating: 1000, count: 640)
        _ = smoother.process(voiced, metadata: metadata(1), now: 0)
        XCTAssertEqual(smoother.process(voiced, metadata: metadata(7), now: 0.1), voiced)
        XCTAssertEqual(smoother.process(voiced, metadata: metadata(9, ssrc: 2), now: 0.2), voiced)
        XCTAssertEqual(smoother.process(voiced, metadata: metadata(10, ssrc: 2), now: 1), voiced)
    }
    func testSequenceWrapConcealsOneMissingPacketAndResetClearsHistory() {
        let smoother = ReceiveSpeechSmoother()
        _ = smoother.process([Int16](repeating: 1000, count: 160), metadata: metadata(.max), now: 0)
        XCTAssertEqual(smoother.process([1, 2], metadata: metadata(1), now: 0.04).count, 162)
        smoother.reset()
        XCTAssertEqual(smoother.process([1, 2], metadata: metadata(3), now: 0.08), [1, 2])
    }
}
