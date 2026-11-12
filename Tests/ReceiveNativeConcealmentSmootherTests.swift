// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ReverbQSO

final class ReceiveNativeConcealmentSmootherTests: XCTestCase {
    private let prior = [Int16](repeating: 12_000, count: 640)
    private let speech = [Int16](repeating: -12_000, count: 640)
    private let concealed = [Int16](repeating: -12_000, count: 1280)

    private func metadata(_ sequence: UInt16, ssrc: UInt32 = 0, payload: UInt8 = 0x96) -> EchoLinkVoicePacketMetadata {
        .init(payloadType: payload, sequenceNumber: sequence, timestamp: 0, ssrc: ssrc)
    }

    func testCleanAndUntrimmedNativeAudioRemainBitIdentical() {
        for budget in [1280, Int.max] {
            let smoother = ReceiveNativeConcealmentSmoother()
            XCTAssertEqual(smoother.process(prior, concealed: [], metadata: metadata(1), now: 0), prior)
            XCTAssertEqual(smoother.process(speech, concealed: [], metadata: metadata(2), now: 0.08), speech)
            XCTAssertEqual(smoother.process(speech, concealed: concealed, metadata: metadata(5), now: 0.32,
                maximumConcealmentSamples: budget), concealed + speech)
            XCTAssertEqual(smoother.process(prior, concealed: [], metadata: metadata(6), now: 0.40), prior)
        }
    }

    func testTrimmedTailBlendsOnlyTheExposedJoins() {
        for budget in [1, 16, 31, 32, 160, 640] {
            let smoother = ReceiveNativeConcealmentSmoother()
            _ = smoother.process(prior, concealed: [], metadata: metadata(1), now: 0)
            let output = smoother.process(speech, concealed: concealed, metadata: metadata(4), now: 0.24,
                maximumConcealmentSamples: budget)

            XCTAssertEqual(output.count, budget + speech.count)
            XCTAssertEqual(output[0], 11_250)
            XCTAssertEqual(Array(output.prefix(budget).dropFirst(32)), Array(concealed.suffix(budget).dropFirst(32)))
            let modifiedSpeech = budget < 32 ? 80 : 0
            XCTAssertEqual(Array(output.dropFirst(budget + modifiedSpeech)), Array(speech.dropFirst(modifiedSpeech)))
            XCTAssertLessThanOrEqual(abs(Int(output[budget - 1]) - Int(output[budget])), 300)
            XCTAssertTrue(output.allSatisfy { abs(Int($0)) <= 12_000 })
        }
    }

    func testZeroOrNegativeBudgetRecoversFromTheActuallyPrecedingSample() {
        for budget in [Int.min, -1, 0] {
            let smoother = ReceiveNativeConcealmentSmoother()
            _ = smoother.process(prior, concealed: [], metadata: metadata(1), now: 0)
            let output = smoother.process(speech, concealed: concealed, metadata: metadata(3), now: 0.16,
                maximumConcealmentSamples: budget)

            XCTAssertEqual(output.count, speech.count)
            XCTAssertEqual(output.first, 11_700)
            XCTAssertEqual(Array(output.dropFirst(80)), Array(speech.dropFirst(80)))
            XCTAssertEqual(smoother.process(speech, concealed: [], metadata: metadata(4), now: 0.24), speech)
        }
    }

    func testTalkerCodecSequenceTimeAndResetBoundariesDoNotReuseOldSpeech() {
        let cases: [(EchoLinkVoicePacketMetadata?, TimeInterval, Bool)] = [
            (metadata(3, ssrc: 1), 0.16, false), (metadata(3, payload: 3), 0.16, false),
            (metadata(1), 0.16, false), (metadata(0), 0.16, false),
            (metadata(2), 0.16, false), (metadata(5), 0.16, false),
            (metadata(3), 0.5, false), (metadata(3), -0.01, false),
            (metadata(3), .nan, false), (metadata(3), .infinity, false),
            (nil, 0.16, false), (metadata(3), 0.16, true)
        ]
        for (next, now, reset) in cases {
            let smoother = ReceiveNativeConcealmentSmoother()
            _ = smoother.process(prior, concealed: [], metadata: metadata(1), now: 0)
            if reset { smoother.reset() }
            XCTAssertEqual(smoother.process(speech, concealed: concealed, metadata: next, now: now,
                maximumConcealmentSamples: 160), Array(concealed.suffix(160)) + speech)
        }
        let unknown = ReceiveNativeConcealmentSmoother()
        _ = unknown.process(prior, concealed: [], metadata: nil, now: 0)
        XCTAssertEqual(unknown.process(speech, concealed: concealed, metadata: metadata(3), now: 0.16,
            maximumConcealmentSamples: 160), Array(concealed.suffix(160)) + speech)
    }

    func testRolloverAndEmptyInputKeepTheRealBoundary() {
        let smoother = ReceiveNativeConcealmentSmoother()
        _ = smoother.process(prior, concealed: [], metadata: metadata(.max), now: 0)
        XCTAssertEqual(smoother.process([], concealed: concealed, metadata: metadata(0), now: 0.08), [])
        let output = smoother.process(speech, concealed: concealed, metadata: metadata(1), now: 0.16,
            maximumConcealmentSamples: 0)
        XCTAssertEqual(output.first, 11_700)
        XCTAssertEqual(output.count, 640)
    }

    func testExtremePCMAndOversizedBudgetsStayBounded() {
        for sign in [1, -1] {
            let previous = [Int16](repeating: sign > 0 ? .max : .min, count: 640)
            let next = [Int16](repeating: sign > 0 ? .min : .max, count: 640)
            for budget in [Int.min, 0, 1, 16, 32, 160, 640] {
                let smoother = ReceiveNativeConcealmentSmoother()
                _ = smoother.process(previous, concealed: [], metadata: metadata(1), now: 0)
                let output = smoother.process(next, concealed: next + next, metadata: metadata(3), now: 0.16,
                    maximumConcealmentSamples: budget)
                XCTAssertEqual(output.count, max(0, budget) + next.count)
                XCTAssertLessThanOrEqual(abs(Int(output[0]) - Int(previous.last!)), budget > 0 ? 2048 : 820)
            }
        }
        let smoother = ReceiveNativeConcealmentSmoother()
        let oversized = [Int16](repeating: 7, count: 20_000)
        XCTAssertEqual(smoother.process(speech, concealed: oversized, metadata: nil,
            maximumConcealmentSamples: Int.max).count, 1280 + speech.count)
    }

    func testPendingAndNativeSpeechStillReserveTheirSharedRecoveryBudget() {
        let budget = ReceivePlaybackQueue().concealmentSampleBudget(
            receivedSamples: 640, remainingSamples: 320, pendingSamples: 160)
        let smoother = ReceiveNativeConcealmentSmoother()
        _ = smoother.process(prior, concealed: [], metadata: metadata(1), now: 0)
        let output = smoother.process(speech, concealed: concealed, metadata: metadata(3), now: 0.16,
            maximumConcealmentSamples: budget)
        XCTAssertEqual(budget, 160)
        XCTAssertEqual(output.count + 320 + 160, 1280)
        XCTAssertEqual(Array(output.suffix(640)), speech)
    }

    func testActualSpeexTruncationJoinsImproveWithoutChangingDecoderAdvancement() throws {
        var before: [Int: Int] = [:]
        var after: [Int: Int] = [:]
        for frequency in [100.0, 125, 137, 180, 220] {
            for phase in [0.0, Double.pi / 2, Double.pi, 3 * Double.pi / 2] {
                let source = (0..<(12 * 640)).map { index in
                    Int16((16_000 * sin(2 * .pi * frequency * Double(index) / 8_000 + phase)).rounded())
                }
                let packets = try XCTUnwrap(SpeexCodec().encode(source))
                for budget in [0, 1, 16, 32, 160, 640, 1280] {
                    let decoder = SpeexReceiveStreamDecoder()
                    let reference = SpeexCodec()
                    let smoother = ReceiveNativeConcealmentSmoother()
                    var last: Int16 = 0
                    var warmup: [Int16] = []
                    for index in 0..<8 {
                        let decoded = try XCTUnwrap(decoder.decode(packets[index], metadata: metadata(UInt16(index)),
                            now: Double(index) * 0.08))
                        XCTAssertEqual(decoded.received, reference.decodePacket(packets[index]))
                        let output = smoother.process(decoded.received, concealed: decoded.concealed,
                            metadata: metadata(UInt16(index)), now: Double(index) * 0.08)
                        XCTAssertEqual(output, decoded.received)
                        last = try XCTUnwrap(output.last)
                        warmup += output
                    }
                    let recovered = try XCTUnwrap(decoder.decode(packets[10], metadata: metadata(10), now: 0.8))
                    XCTAssertEqual(recovered.concealed, reference.concealMissingSamples(1280))
                    XCTAssertEqual(recovered.received, reference.decodePacket(packets[10]))
                    let old = Array(recovered.concealed.suffix(budget)) + recovered.received
                    let output = smoother.process(recovered.received, concealed: recovered.concealed,
                        metadata: metadata(10), now: 0.8, maximumConcealmentSamples: budget)
                    before[budget] = max(before[budget] ?? 0, abs(Int(old[0]) - Int(last)))
                    after[budget] = max(after[budget] ?? 0, abs(Int(output[0]) - Int(last)))
                    XCTAssertEqual(output.count, budget + recovered.received.count)
                    if budget == 1280 { XCTAssertEqual(output, old) }
                    else { XCTAssertLessThanOrEqual(abs(Int(output[0]) - Int(last)), 600) }
                    let modifiedSpeech = budget < 32 ? 80 : 0
                    XCTAssertEqual(Array(output.dropFirst(budget + modifiedSpeech)),
                        Array(recovered.received.dropFirst(modifiedSpeech)))
                    let next = try XCTUnwrap(decoder.decode(packets[11], metadata: metadata(11), now: 0.88))
                    XCTAssertEqual(next.received, reference.decodePacket(packets[11]))
                    let nextOutput = smoother.process(next.received, concealed: next.concealed,
                        metadata: metadata(11), now: 0.88)
                    XCTAssertEqual(nextOutput, next.received)
                    if frequency == 220, phase == 0, [0, 640].contains(budget) {
                        for (label, samples) in [("before", old), ("after", output)] {
                            let attachment = XCTAttachment(data: wav(warmup + samples + nextOutput),
                                uniformTypeIdentifier: "com.microsoft.waveform-audio")
                            attachment.name = "speex-native-plc-budget-\(budget)-\(label).wav"
                            attachment.lifetime = .keepAlways
                            add(attachment)
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(before[640] ?? 0, 10_000, "Fixture must expose the original discontinuity")
        for budget in before.keys.sorted() {
            print("NATIVE_PLC_JOIN budget=\(budget) stepBefore=\(before[budget]!) stepAfter=\(after[budget]!)")
        }
    }

    private func wav(_ samples: [Int16]) -> Data {
        var output = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
        }
        output.append(Data("RIFF".utf8)); word(UInt32(36 + samples.count * 2))
        output.append(Data("WAVEfmt ".utf8)); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(8000)); word(UInt32(16000)); word(UInt16(2)); word(UInt16(16))
        output.append(Data("data".utf8)); word(UInt32(samples.count * 2))
        for sample in samples { word(sample) }
        return output
    }
}
