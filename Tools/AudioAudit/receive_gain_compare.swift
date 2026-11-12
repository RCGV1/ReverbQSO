// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// File-only comparison harness compiled with the selected shipping gain implementation.
@main
struct ReceiveGainComparison {
    enum Failure: Error { case arguments, inputFormat, existingOutput, nonFiniteOutput }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("receive_gain_compare: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { throw Failure.arguments }
        let tag = arguments[3]
        guard !tag.isEmpty, tag.utf8.allSatisfy({
            $0 == 45 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }) else { throw Failure.arguments }
        let input = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        guard !input.isEmpty, input.count <= 32 * 1_024 * 1_024, input.count.isMultiple(of: 2),
              !input.starts(with: Data("RIFF".utf8)) else { throw Failure.inputFormat }
        let speech = stride(from: 0, to: input.count, by: 2).map {
            Int16(bitPattern: UInt16(input[$0]) | UInt16(input[$0 + 1]) << 8)
        }
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let names = ["speech.wav", "tone.wav", "metrics.json"].map { directory.appendingPathComponent("\(tag)-\($0)") }
        guard names.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw Failure.existingOutput
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tone = diagnosticTone()
        let speechOutput = render(speech)
        let toneOutput = render(tone)
        let speechMetrics = try measure(speechOutput, input: speech)
        let toneMetrics = try measure(toneOutput, input: tone)
        try wave(speechOutput).write(to: names[0], options: .atomic)
        try wave(toneOutput).write(to: names[1], options: .atomic)
        let metrics: [String: Any] = [
            "tag": tag, "sample_rate": 8_000, "packet_samples": 640,
            "speech_source": "Open Speech Repository", "input_bytes": input.count,
            "speech": speechMetrics, "diagnostic_tone": toneMetrics
        ]
        let json = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: names[2], options: .atomic)
        print(String(decoding: json, as: UTF8.self))
    }

    private static func render(_ input: [Int16]) -> [Float] {
        var gain = ReceivePlaybackGain()
        var output: [Float] = []
        output.reserveCapacity(input.count)
        for offset in stride(from: 0, to: input.count, by: 640) {
            output += gain.process(Array(input[offset..<min(input.count, offset + 640)]))
        }
        return output
    }

    private static func measure(_ output: [Float], input: [Int16]) throws -> [String: Any] {
        guard output.count == input.count, output.allSatisfy(\.isFinite) else { throw Failure.nonFiniteOutput }
        let peak = output.map { abs(Double($0)) }.max() ?? 0
        let rms = sqrt(output.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, output.count)))
        var maximumBoundaryStep = 0.0
        var maximumGainStep = 0.0
        var measuredGainBoundaries = 0
        for index in stride(from: 640, to: output.count, by: 640) {
            maximumBoundaryStep = max(maximumBoundaryStep, abs(Double(output[index] - output[index - 1])))
            if abs(Int(input[index - 1])) >= 256 {
                let previousGain = Double(output[index - 1]) / (Double(input[index - 1]) / 32768)
                let unchangedGainSample = Double(input[index]) / 32768 * previousGain
                maximumGainStep = max(maximumGainStep, abs(Double(output[index]) - unchangedGainSample))
                measuredGainBoundaries += 1
            }
        }
        return ["samples": output.count, "peak": peak, "rms": rms,
                "clipped_samples": output.filter { abs($0) >= 1 }.count,
                "over_limit_samples": output.filter { abs($0) > 0.950_001 }.count,
                "maximum_packet_boundary_step": maximumBoundaryStep,
                "maximum_gain_induced_boundary_step": maximumGainStep,
                "measured_gain_boundaries": measuredGainBoundaries]
    }

    private static func diagnosticTone() -> [Int16] {
        (0..<(20 * 640)).map { index in
            let packet = index / 640
            let position = index % 640
            var amplitude = 9_000.0
            if packet == 4 {
                amplitude += 21_000 * min(1, max(0, Double(position - 240) / 160))
            } else if (5...7).contains(packet) { amplitude = 30_000 }
            else if packet == 8 {
                amplitude = 30_000 - 21_000 * min(1, max(0, Double(position - 160) / 160))
            }
            let fade = min(1, min(Double(index) / 80, Double(20 * 640 - 1 - index) / 80))
            return Int16((amplitude * fade * cos(2 * .pi * 100 * Double(index) / 8_000)).rounded())
        }
    }

    private static func wave(_ samples: [Float]) -> Data {
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); word(UInt32(36 + samples.count * 2))
        data.append(Data("WAVEfmt ".utf8)); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(8_000)); word(UInt32(16_000)); word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(UInt32(samples.count * 2))
        for sample in samples { word(Int16(clamping: Int((Double(sample) * 32768).rounded()))) }
        return data
    }
}
