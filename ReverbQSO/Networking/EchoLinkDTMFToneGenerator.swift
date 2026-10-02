// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct DTMFFrequencies: Equatable {
    let low: Double
    let high: Double
}

enum EchoLinkDTMFToneGenerator {
    enum Error: Swift.Error, Equatable {
        case invalidDigit(Character)
        case sequenceTooLong(maximum: Int)
    }

    static let sampleRate = 8_000
    static let toneSampleCount = 640
    static let silenceSampleCount = 640
    static let maximumDigitCount = 32

    private static let componentAmplitude = 8_000.0
    private static let frequencyTable: [Character: DTMFFrequencies] = [
        "1": .init(low: 697, high: 1209), "2": .init(low: 697, high: 1336),
        "3": .init(low: 697, high: 1477), "A": .init(low: 697, high: 1633),
        "4": .init(low: 770, high: 1209), "5": .init(low: 770, high: 1336),
        "6": .init(low: 770, high: 1477), "B": .init(low: 770, high: 1633),
        "7": .init(low: 852, high: 1209), "8": .init(low: 852, high: 1336),
        "9": .init(low: 852, high: 1477), "C": .init(low: 852, high: 1633),
        "*": .init(low: 941, high: 1209), "0": .init(low: 941, high: 1336),
        "#": .init(low: 941, high: 1477), "D": .init(low: 941, high: 1633),
    ]

    static func frequencies(for digit: Character) throws -> DTMFFrequencies {
        guard let frequencies = frequencyTable[digit] else {
            throw Error.invalidDigit(digit)
        }
        return frequencies
    }

    static func generate(_ digits: String) throws -> [Int16] {
        guard digits.count <= maximumDigitCount else {
            throw Error.sequenceTooLong(maximum: maximumDigitCount)
        }

        let samplesPerDigit = toneSampleCount + silenceSampleCount
        var samples: [Int16] = []
        samples.reserveCapacity(digits.count * samplesPerDigit)

        for digit in digits {
            let pair = try frequencies(for: digit)
            for sampleIndex in 0..<toneSampleCount {
                let time = Double(sampleIndex) / Double(sampleRate)
                let sample = componentAmplitude * sin(2 * .pi * pair.low * time)
                    + componentAmplitude * sin(2 * .pi * pair.high * time)
                samples.append(Int16(clamping: Int(sample.rounded())))
            }
            samples.append(contentsOf: repeatElement(0, count: silenceSampleCount))
        }

        return samples
    }
}
