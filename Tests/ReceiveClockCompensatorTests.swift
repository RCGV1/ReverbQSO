// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class ReceiveClockCompensatorTests: XCTestCase {
    func testStableQueueLeavesPacketAndRatioUnchanged() {
        let compensator = ReceiveClockCompensator()
        let samples = (0..<640).map { Int16($0 - 320) }

        let output = compensator.process(samples, queuedSamples: 640)

        XCTAssertEqual(output, samples)
        XCTAssertEqual(compensator.correctionRatio, 1, accuracy: 0.000_001)
    }

    func testSustainedLowQueueCompensatesForFasterPlaybackClock() {
        let compensator = ReceiveClockCompensator()
        let packet = (0..<640).map { Int16(($0 % 200) - 100) }
        var queuedSamples = 640
        var minimumQueue = queuedSamples
        var maximumRatio = 1.0

        for _ in 0..<2_000 {
            let output = compensator.process(packet, queuedSamples: queuedSamples)
            queuedSamples += output.count - 642
            minimumQueue = min(minimumQueue, queuedSamples)
            maximumRatio = max(maximumRatio, compensator.correctionRatio)
        }

        XCTAssertGreaterThan(queuedSamples, 480)
        XCTAssertGreaterThan(minimumQueue, 350)
        XCTAssertGreaterThan(maximumRatio, 1.002)
        XCTAssertLessThanOrEqual(maximumRatio, 1.005_001)
    }

    func testSustainedHighQueueCompensatesForSlowerPlaybackClock() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 500, count: 640)
        var queuedSamples = 640
        var maximumQueue = queuedSamples
        var minimumRatio = 1.0

        for _ in 0..<2_000 {
            let output = compensator.process(packet, queuedSamples: queuedSamples)
            queuedSamples += output.count - 638
            maximumQueue = max(maximumQueue, queuedSamples)
            minimumRatio = min(minimumRatio, compensator.correctionRatio)
        }

        XCTAssertLessThan(queuedSamples, 800)
        XCTAssertLessThan(maximumQueue, 930)
        XCTAssertLessThan(minimumRatio, 0.998)
        XCTAssertGreaterThanOrEqual(minimumRatio, 0.994_999)
    }

    func testSingleQueueBurstOnlyChangesRatioGently() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 1_000, count: 640)

        _ = compensator.process(packet, queuedSamples: 640)
        let output = compensator.process(packet, queuedSamples: 1_920)

        XCTAssertGreaterThan(compensator.correctionRatio, 0.999)
        XCTAssertGreaterThanOrEqual(output.count, 639)
    }

    func testInterpolationPreservesConstantWaveformWhenLengthChanges() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: -12_345, count: 640)
        var changedOutput = packet

        for _ in 0..<300 where changedOutput.count == packet.count {
            changedOutput = compensator.process(packet, queuedSamples: 1_280)
        }

        XCTAssertNotEqual(changedOutput.count, packet.count)
        XCTAssertTrue(changedOutput.allSatisfy { $0 == -12_345 })
    }

    func testEmptyQueueRetainsCorrectionUntilExplicitReset() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 7, count: 640)

        for _ in 0..<100 {
            _ = compensator.process(packet, queuedSamples: 1_280)
        }
        XCTAssertLessThan(compensator.correctionRatio, 1)

        for _ in 0..<200 { _ = compensator.process(packet, queuedSamples: 0) }
        XCTAssertGreaterThan(compensator.correctionRatio, 1.004)

    }

    func testTwentyMillisecondPacketsUseActualDesiredLead() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 1200, count: 160)
        for _ in 0..<200 {
            XCTAssertEqual(compensator.process(packet, queuedSamples: 160, targetQueuedSamples: 160), packet)
        }
        XCTAssertEqual(compensator.correctionRatio, 1, accuracy: 0.000001)
    }

    func testExplicitResetRestoresNeutralCorrection() {
        let compensator = ReceiveClockCompensator()
        let packet = [Int16](repeating: 7, count: 640)

        for _ in 0..<100 {
            _ = compensator.process(packet, queuedSamples: 1_280)
        }
        compensator.reset()

        XCTAssertEqual(compensator.correctionRatio, 1, accuracy: 0.000_001)
        XCTAssertEqual(compensator.process(packet, queuedSamples: 640), packet)
    }
}
