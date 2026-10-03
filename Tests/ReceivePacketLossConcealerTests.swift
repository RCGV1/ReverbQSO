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
