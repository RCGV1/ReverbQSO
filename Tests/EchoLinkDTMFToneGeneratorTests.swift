// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class EchoLinkDTMFToneGeneratorTests: XCTestCase {
    func testFrequencyTableMatchesStandardDTMFKeypad() throws {
        let expected: [Character: DTMFFrequencies] = [
            "1": .init(low: 697, high: 1209), "2": .init(low: 697, high: 1336),
            "3": .init(low: 697, high: 1477), "A": .init(low: 697, high: 1633),
            "4": .init(low: 770, high: 1209), "5": .init(low: 770, high: 1336),
            "6": .init(low: 770, high: 1477), "B": .init(low: 770, high: 1633),
            "7": .init(low: 852, high: 1209), "8": .init(low: 852, high: 1336),
            "9": .init(low: 852, high: 1477), "C": .init(low: 852, high: 1633),
            "*": .init(low: 941, high: 1209), "0": .init(low: 941, high: 1336),
            "#": .init(low: 941, high: 1477), "D": .init(low: 941, high: 1633),
        ]

        for (digit, frequencies) in expected {
            XCTAssertEqual(try EchoLinkDTMFToneGenerator.frequencies(for: digit), frequencies)
        }
    }

    func testGenerationUsesPacketAlignedToneAndSilence() throws {
        let samples = try EchoLinkDTMFToneGenerator.generate("12")
        let segmentSamples = EchoLinkDTMFToneGenerator.toneSampleCount
            + EchoLinkDTMFToneGenerator.silenceSampleCount

        XCTAssertEqual(samples.count, segmentSamples * 2)
        XCTAssertEqual(EchoLinkDTMFToneGenerator.toneSampleCount, 640)
        XCTAssertEqual(EchoLinkDTMFToneGenerator.silenceSampleCount, 640)
        XCTAssertEqual(EchoLinkDTMFToneGenerator.toneSampleCount % 160, 0)
        XCTAssertEqual(EchoLinkDTMFToneGenerator.silenceSampleCount % 160, 0)
        XCTAssertTrue(samples[0..<EchoLinkDTMFToneGenerator.toneSampleCount].contains { $0 != 0 })
        XCTAssertTrue(samples[EchoLinkDTMFToneGenerator.toneSampleCount..<segmentSamples].allSatisfy { $0 == 0 })
        XCTAssertTrue(samples[(segmentSamples + EchoLinkDTMFToneGenerator.toneSampleCount)..<(segmentSamples * 2)].allSatisfy { $0 == 0 })
    }

    func testGenerationIsDeterministicAndBounded() throws {
        let first = try EchoLinkDTMFToneGenerator.generate("5#")
        let second = try EchoLinkDTMFToneGenerator.generate("5#")

        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(first.map { abs(Int($0)) }.max() ?? 0, 16_000)
    }

    func testLowercaseABCDIsRejected() {
        XCTAssertThrowsError(try EchoLinkDTMFToneGenerator.generate("a")) { error in
            XCTAssertEqual(error as? EchoLinkDTMFToneGenerator.Error, .invalidDigit("a"))
        }
    }

    func testUnsupportedCharactersAreRejected() {
        XCTAssertThrowsError(try EchoLinkDTMFToneGenerator.generate("12 3")) { error in
            XCTAssertEqual(error as? EchoLinkDTMFToneGenerator.Error, .invalidDigit(" "))
        }
    }

    func testOverlongSequenceIsRejected() {
        let digits = String(repeating: "1", count: EchoLinkDTMFToneGenerator.maximumDigitCount + 1)

        XCTAssertThrowsError(try EchoLinkDTMFToneGenerator.generate(digits)) { error in
            XCTAssertEqual(
                error as? EchoLinkDTMFToneGenerator.Error,
                .sequenceTooLong(maximum: EchoLinkDTMFToneGenerator.maximumDigitCount)
            )
        }
    }

    func testEmptySequenceProducesNoSamples() throws {
        XCTAssertEqual(try EchoLinkDTMFToneGenerator.generate(""), [])
    }
}
