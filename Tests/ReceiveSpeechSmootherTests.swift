// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO
final class ReceiveSpeechSmootherTests: XCTestCase {
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
