// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class ReceivePacketLossConcealerTests: XCTestCase {
    func testVoicedPacketRepeatsPitchWithContinuousBoundary() {
        let concealer = ReceivePacketLossConcealer()
        let packet = sine(frequency: 125, sampleCount: 640, amplitude: 12_000)
        concealer.record(packet)

        let concealed = concealer.conceal(sampleCount: 640)

        XCTAssertEqual(concealed.count, 640)
        XCTAssertGreaterThan(rms(concealed), 2_000)
        XCTAssertLessThan(abs(Int(concealed[0]) - Int(packet.last!)), 2_500)
        XCTAssertLessThan(meanAbsoluteDifference(concealed, Array(packet.prefix(640))), 3_000)
    }

    func testSuccessiveMissingPacketsFadeThenStopSynthesizing() {
        let concealer = ReceivePacketLossConcealer()
        concealer.record(sine(frequency: 160, sampleCount: 640, amplitude: 14_000))

        let first = concealer.conceal(sampleCount: 640)
        let second = concealer.conceal(sampleCount: 640)
        let third = concealer.conceal(sampleCount: 640)

        XCTAssertGreaterThan(rms(first), rms(second) * 1.35)
        XCTAssertGreaterThan(rms(second), 100)
        XCTAssertEqual(third, [Int16](repeating: 0, count: 640))
        XCTAssertLessThan(abs(Int(second.last!)), 100)
    }

    func testSilenceEmptyInputAndLargeRequestsStayBounded() {
        let concealer = ReceivePacketLossConcealer()
        XCTAssertEqual(concealer.conceal(sampleCount: 0), [])
        XCTAssertEqual(concealer.processReceived([]), [])

        concealer.record([Int16](repeating: 0, count: 640))
        let concealed = concealer.conceal(sampleCount: 20_000)

        XCTAssertEqual(concealed.count, 1_280)
        XCTAssertEqual(Set(concealed), [0])
    }

    func testConcealmentNeverClipsAtInt16Limits() {
        let concealer = ReceivePacketLossConcealer()
        let voiced = (0..<640).map { index in
            index % 80 < 40 ? Int16.max : Int16.min
        }
        concealer.record(voiced)

        let concealed = concealer.conceal(sampleCount: 1_280)

        XCTAssertEqual(concealed.count, 1_280)
        XCTAssertGreaterThanOrEqual(concealed.min()!, Int16.min)
        XCTAssertLessThanOrEqual(concealed.max()!, Int16.max)
    }

    func testRecoveryBlendReducesReturnDiscontinuityAndRecordsNewAudio() {
        let concealer = ReceivePacketLossConcealer()
        concealer.record(sine(frequency: 100, sampleCount: 640, amplitude: 10_000))
        let missing = concealer.conceal(sampleCount: 640)
        let returning = sine(frequency: 220, sampleCount: 640, amplitude: 8_000, phase: .pi / 2)

        let recovered = concealer.processReceived(returning)
        let directJump = abs(Int(returning[0]) - Int(missing.last!))
        let blendedJump = abs(Int(recovered[0]) - Int(missing.last!))

        XCTAssertEqual(recovered.count, returning.count)
        XCTAssertLessThan(blendedJump, directJump)
        XCTAssertEqual(recovered.last, returning.last)
        XCTAssertFalse(concealer.conceal(sampleCount: 80).allSatisfy { $0 == 0 })
    }

    func testResetDropsHistoryAndLossState() {
        let concealer = ReceivePacketLossConcealer()
        concealer.record(sine(frequency: 140, sampleCount: 640, amplitude: 9_000))
        _ = concealer.conceal(sampleCount: 640)

        concealer.reset()

        XCTAssertEqual(concealer.conceal(sampleCount: 640), [Int16](repeating: 0, count: 640))
        XCTAssertEqual(concealer.processReceived([100, 200, 300]), [100, 200, 300])
    }

    func testCappedConcealmentKeepsSuffixAfterReblendingItsBoundary() {
        let packet = sine(frequency: 100, sampleCount: 640, amplitude: 16_000, phase: .pi / 2)
        let reference = ReceivePacketLossConcealer()
        reference.record(packet)
        let full = reference.conceal(sampleCount: 1_280)

        for budget in [1, 16, 32, 160, 640, 1_280, Int.max] {
            let concealer = ReceivePacketLossConcealer()
            concealer.record(packet)
            let retained = concealer.conceal(sampleCount: 1_280, maximumOutputSamples: budget)
            let retainedCount = min(budget, full.count)

            XCTAssertEqual(retained.count, retainedCount, "budget=\(budget)")
            XCTAssertLessThanOrEqual(abs(Int(retained[0]) - Int(packet.last!)), 1_000)
            XCTAssertLessThanOrEqual(retained.map { abs(Int($0)) }.max()!, 16_000)
            XCTAssertEqual(Array(retained.dropFirst(32)),
                Array(full.suffix(retainedCount).dropFirst(32)))
            if budget >= full.count { XCTAssertEqual(retained, full) }
        }
    }

    func testZeroAndNegativeBudgetsRecoverFromActualPrecedingSpeech() {
        let prior = [Int16](repeating: 12_000, count: 640)
        let returning = [Int16](repeating: -12_000, count: 640)
        for budget in [0, -1, Int.min] {
            let concealer = ReceivePacketLossConcealer()
            concealer.record(prior)

            XCTAssertEqual(concealer.conceal(sampleCount: 1_280, maximumOutputSamples: budget), [])
            let recovered = concealer.processReceived(returning)

            XCTAssertEqual(recovered.count, returning.count)
            XCTAssertEqual(recovered.first, 11_700)
            XCTAssertEqual(Array(recovered.dropFirst(80)), Array(returning.dropFirst(80)))
            XCTAssertEqual(concealer.processReceived(returning), returning)
        }
    }

    func testZeroRetainedLossPreservesExactlyContinuousMuLawVoicedPCM() {
        for count in [160, 320, 640] {
            let packet = ReceivePLCJoinFixture.voicedPacket(sampleCount: count)
            XCTAssertEqual(packet.last, packet.first)
            for budget in [Int.min, -1, 0] {
                let context = "count=\(count) budget=\(budget)"
                let concealer = ReceivePacketLossConcealer()
                XCTAssertEqual(concealer.processReceived(packet), packet, context)
                XCTAssertEqual(concealer.conceal(sampleCount: count,
                    maximumOutputSamples: budget), [], context)

                let recoveredPCM = concealer.processReceived(packet)

                XCTAssertEqual(recoveredPCM.count, packet.count, context)
                XCTAssertEqual(Array(recoveredPCM.prefix(80)), Array(packet.prefix(80)), context)
                XCTAssertEqual(recoveredPCM, packet, context)
                let next = packet.map { -$0 }
                XCTAssertEqual(concealer.processReceived(next), next, context)
            }
        }
    }

    func testRetainedLossWithExactlyMatchedFirstSampleKeepsExistingRecoveryBlend() {
        for count in [160, 320, 640] {
            let packet = ReceivePLCJoinFixture.voicedPacket(sampleCount: count)
            let budgets: [Int?] = [nil, 1, 16, 32, count, 1_280, Int.max]
            for budget in budgets {
                let context = "count=\(count) budget=\(String(describing: budget))"
                let concealer = ReceivePacketLossConcealer()
                concealer.record(packet)
                let retained: [Int16]
                if let budget {
                    retained = concealer.conceal(sampleCount: count, maximumOutputSamples: budget)
                } else {
                    retained = concealer.conceal(sampleCount: count)
                }
                XCTAssertEqual(retained.count, min(count, budget ?? count), context)
                guard let preceding = retained.last else {
                    XCTFail("Expected retained concealment: \(context)")
                    continue
                }
                var returning = packet
                returning[0] = preceding
                let expected = ReceivePLCJoinFixture.heldSampleRecovery(returning, following: preceding)

                XCTAssertNotEqual(expected, returning, context)
                XCTAssertEqual(concealer.processReceived(returning), expected, context)
                XCTAssertEqual(concealer.processReceived(returning), returning, context)
            }
        }
    }

    func testZeroRetainedNonmatchingJoinStillUsesExistingRecoveryBlend() {
        for count in [160, 320, 640] {
            let packet = ReceivePLCJoinFixture.voicedPacket(sampleCount: count)
            var nearMatch = packet
            nearMatch[0] -= 1
            let extremes = (0..<count).map { $0.isMultiple(of: 2) ? Int16.min : Int16.max }
            for returning in [nearMatch, packet.map { -$0 }, extremes] {
                for budget in [Int.min, -1, 0] {
                    let context = "count=\(count) budget=\(budget) first=\(returning[0])"
                    let concealer = ReceivePacketLossConcealer()
                    concealer.record(packet)
                    XCTAssertEqual(concealer.conceal(sampleCount: count,
                        maximumOutputSamples: budget), [], context)
                    let expected = ReceivePLCJoinFixture.heldSampleRecovery(returning,
                        following: packet.last!)

                    XCTAssertNotEqual(expected, returning, context)
                    XCTAssertEqual(concealer.processReceived(returning), expected, context)
                }
            }
        }
    }

    func testZeroRetainedStateDoesNotSurviveRecordOrReset() {
        let packet = ReceivePLCJoinFixture.voicedPacket(sampleCount: 640)
        let next = packet.map { -$0 }
        for resetHistory in [false, true] {
            let concealer = ReceivePacketLossConcealer()
            concealer.record(packet)
            XCTAssertEqual(concealer.conceal(sampleCount: 640, maximumOutputSamples: 0), [])
            if resetHistory {
                concealer.reset()
            } else {
                concealer.record(packet)
            }
            XCTAssertEqual(concealer.processReceived(next), next)

            let retained = concealer.conceal(sampleCount: 640)
            var returning = packet
            returning[0] = retained.last!
            let expected = ReceivePLCJoinFixture.heldSampleRecovery(returning,
                following: retained.last!)
            XCTAssertNotEqual(expected, returning)
            XCTAssertEqual(concealer.processReceived(returning), expected)
        }
    }

    func testRetainedConcealmentAfterZeroRetainedLossStillUsesExistingRecoveryBlend() {
        let packet = ReceivePLCJoinFixture.voicedPacket(sampleCount: 640)
        let concealer = ReceivePacketLossConcealer()
        concealer.record(packet)
        XCTAssertEqual(concealer.conceal(sampleCount: 160, maximumOutputSamples: 0), [])

        let retained = concealer.conceal(sampleCount: 160)
        XCTAssertEqual(retained.count, 160)
        var returning = packet
        returning[0] = retained.last!
        let expected = ReceivePLCJoinFixture.heldSampleRecovery(returning,
            following: retained.last!)

        XCTAssertNotEqual(expected, returning)
        XCTAssertEqual(concealer.processReceived(returning), expected)
    }

    func testCappedConcealmentStillConsumesFullLossBudget() {
        for count in [1_280, 20_000] {
            for budget in [Int.min, -1, 0, 160, 640, 1_280] {
                let concealer = ReceivePacketLossConcealer()
                concealer.record(sine(frequency: 100, sampleCount: 640, amplitude: 16_000))
                _ = concealer.conceal(sampleCount: count, maximumOutputSamples: budget)

                XCTAssertEqual(concealer.conceal(sampleCount: 640),
                    [Int16](repeating: 0, count: 640), "count=\(count) budget=\(budget)")
            }
        }
    }

    func testCappedRecoveryRecordsActualReceivedAudioForNextLoss() {
        let prior = sine(frequency: 100, sampleCount: 640, amplitude: 16_000, phase: .pi / 2)
        let returning = sine(frequency: 180, sampleCount: 640, amplitude: 9_000, phase: -.pi / 2)
        for budget in [0, -1, 160, 640, 1_280] {
            let concealer = ReceivePacketLossConcealer()
            concealer.record(prior)
            _ = concealer.conceal(sampleCount: 1_280, maximumOutputSamples: budget)
            _ = concealer.processReceived(returning)
            let reference = ReceivePacketLossConcealer()
            reference.record(prior)
            reference.record(returning)

            XCTAssertEqual(concealer.conceal(sampleCount: 1_280),
                reference.conceal(sampleCount: 1_280), "budget=\(budget)")
        }
    }

    func testNonpositiveLossRequestsDoNotChangeCleanAudio() {
        let concealer = ReceivePacketLossConcealer()
        let packet = sine(frequency: 100, sampleCount: 640, amplitude: 16_000)
        concealer.record(packet)
        for count in [0, -1, Int.min] {
            XCTAssertEqual(concealer.conceal(sampleCount: count, maximumOutputSamples: 0), [])
            XCTAssertEqual(concealer.processReceived(packet), packet)
        }
        XCTAssertEqual(concealer.conceal(sampleCount: 640, maximumOutputSamples: 0), [])
        XCTAssertEqual(concealer.processReceived([]), [])
    }

    private func sine(
        frequency: Double,
        sampleCount: Int,
        amplitude: Double,
        phase: Double = 0
    ) -> [Int16] {
        (0..<sampleCount).map { index in
            Int16((amplitude * sin(2 * .pi * frequency * Double(index) / 8_000 + phase)).rounded())
        }
    }

    private func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }

    private func meanAbsoluteDifference(_ lhs: [Int16], _ rhs: [Int16]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return .infinity }
        return zip(lhs, rhs).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(lhs.count)
    }
}

enum ReceivePLCJoinFixture {
    static func voicedPacket(sampleCount: Int) -> [Int16] {
        let levels = (0...255).map { EchoLinkAudioPacketCodec.decodeMuLaw(UInt8($0)) }
        // Half-sample phase gives an exact last-to-first match over each 80-sample cycle.
        let cycle: [Int16] = (0..<80).map { index in
            let angle = 2 * Double.pi * (Double(index) + 0.5) / 80
            let target = Int((12_000 * cos(angle) + 3_000 * cos(3 * angle)).rounded())
            return levels.min { abs(Int($0) - target) < abs(Int($1) - target) }!
        }
        return (0..<sampleCount).map { cycle[$0 % cycle.count] }
    }

    static func heldSampleRecovery(_ samples: [Int16], following preceding: Int16) -> [Int16] {
        var expected = samples
        let count = min(80, samples.count)
        for index in 0..<count {
            let weight = Double(index + 1) / Double(count)
            expected[index] = Int16((Double(preceding) * (1 - weight)
                + Double(samples[index]) * weight).rounded())
        }
        return expected
    }
}
