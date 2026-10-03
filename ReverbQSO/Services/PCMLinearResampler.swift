// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Streaming state for linear PCM resampling.
struct PCMLinearResamplerState {
    fileprivate var sourceSampleRate: Double = 0
    fileprivate var targetSampleRate: Double = 0
    fileprivate var carryInputPosition: Double = 0
    fileprivate var lastSourceSample: Int16?
    fileprivate var lowPassCoefficients: [Double] = []
    fileprivate var lowPassHistory: [Double] = []

    mutating func reset() {
        sourceSampleRate = 0
        targetSampleRate = 0
        carryInputPosition = 0
        lastSourceSample = nil
        lowPassCoefficients.removeAll(keepingCapacity: false)
        lowPassHistory.removeAll(keepingCapacity: false)
    }
}

/// Stateful linear resampler used to adapt device capture rates to codec rates.
enum PCMLinearResampler {
    static func resample(
        _ samples: [Int16],
        sourceSampleRate: Double,
        targetSampleRate: Double,
        state: inout PCMLinearResamplerState
    ) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        guard sourceSampleRate.isFinite,
              targetSampleRate.isFinite,
              sourceSampleRate > 0,
              targetSampleRate > 0 else {
            return samples
        }

        if abs(sourceSampleRate - targetSampleRate) < 0.5 {
            if abs(state.sourceSampleRate - sourceSampleRate) > 0.5
                || abs(state.targetSampleRate - targetSampleRate) > 0.5 {
                state.reset()
            }
            state.sourceSampleRate = sourceSampleRate
            state.targetSampleRate = targetSampleRate
            state.carryInputPosition = 0
            state.lastSourceSample = samples.last
            return samples
        }

        if state.sourceSampleRate == 0
            || abs(state.sourceSampleRate - sourceSampleRate) > 0.5
            || abs(state.targetSampleRate - targetSampleRate) > 0.5 {
            state.reset()
            state.sourceSampleRate = sourceSampleRate
            state.targetSampleRate = targetSampleRate
        }

        let resamplingInput: [Int16]
        if sourceSampleRate > targetSampleRate {
            resamplingInput = lowPass(
                samples,
                sourceSampleRate: sourceSampleRate,
                targetSampleRate: targetSampleRate,
                state: &state
            )
        } else {
            resamplingInput = samples
        }

        let step = sourceSampleRate / targetSampleRate
        guard step.isFinite, step > 0 else { return samples }

        var output: [Int16] = []
        output.reserveCapacity(max(1, Int(Double(samples.count) / step)))

        var position = state.carryInputPosition
        // Allow a tiny epsilon at the chunk boundary so ratios like 44_100→8_000
        // do not emit an extra trailing sample due to floating-point drift.
        let inputLimit = Double(samples.count) - 1e-6
        while position < inputLimit {
            output.append(
                interpolate(
                    at: position,
                    in: resamplingInput,
                    previousSample: state.lastSourceSample
                )
            )
            position += step
        }

        state.carryInputPosition = position - Double(samples.count)
        if !state.carryInputPosition.isFinite || state.carryInputPosition < 0 {
            state.carryInputPosition = 0
        } else if state.carryInputPosition >= step {
            state.carryInputPosition.formTruncatingRemainder(dividingBy: step)
        }
        state.lastSourceSample = resamplingInput.last

        return output
    }

    /// A causal, windowed-sinc low-pass prevents content above the destination
    /// Nyquist limit from folding into the speech band during decimation. The
    /// kernel scales with the source rate to keep about 1 ms of group delay and
    /// a consistent transition band across hardware capture rates.
    private static func lowPass(
        _ samples: [Int16],
        sourceSampleRate: Double,
        targetSampleRate: Double,
        state: inout PCMLinearResamplerState
    ) -> [Int16] {
        let halfLength = max(1, min(384, Int((sourceSampleRate / 1_000).rounded())))
        let tapCount = halfLength * 2 + 1
        if state.lowPassCoefficients.isEmpty {
            state.lowPassCoefficients = makeLowPassCoefficients(
                tapCount: tapCount,
                cutoff: targetSampleRate * 0.45,
                sampleRate: sourceSampleRate
            )
        }

        let historyCount = tapCount - 1
        if state.lowPassHistory.isEmpty {
            // Extending the first value backwards avoids a DC startup transient.
            state.lowPassHistory = [Double](repeating: Double(samples[0]), count: historyCount)
        }
        let input = state.lowPassHistory + samples.map(Double.init)
        let coefficients = state.lowPassCoefficients
        var output = [Int16]()
        output.reserveCapacity(samples.count)
        for sampleIndex in 0..<samples.count {
            let newest = historyCount + sampleIndex
            var value = 0.0
            for tap in 0..<tapCount {
                value += coefficients[tap] * input[newest - tap]
            }
            output.append(Int16(clamping: Int(value.rounded())))
        }
        state.lowPassHistory = Array(input.suffix(historyCount))
        return output
    }

    private static func makeLowPassCoefficients(
        tapCount: Int,
        cutoff: Double,
        sampleRate: Double
    ) -> [Double] {
        let center = Double(tapCount - 1) / 2
        let normalizedCutoff = cutoff / sampleRate
        var coefficients = (0..<tapCount).map { index -> Double in
            let offset = Double(index) - center
            let sinc = offset == 0
                ? 2 * normalizedCutoff
                : sin(2 * .pi * normalizedCutoff * offset) / (.pi * offset)
            let window = 0.54 - 0.46 * cos(2 * .pi * Double(index) / Double(tapCount - 1))
            return sinc * window
        }
        let sum = coefficients.reduce(0, +)
        if sum != 0 {
            for index in coefficients.indices { coefficients[index] /= sum }
        }
        return coefficients
    }

    private static func interpolate(
        at sourcePosition: Double,
        in samples: [Int16],
        previousSample: Int16?
    ) -> Int16 {
        let lowerIndex = Int(floor(sourcePosition))
        let upperIndex = lowerIndex + 1
        let fraction = sourcePosition - Double(lowerIndex)

        let lowerSample: Int16
        if lowerIndex >= 0 {
            lowerSample = samples[min(lowerIndex, samples.count - 1)]
        } else {
            lowerSample = previousSample ?? samples[0]
        }

        let upperSample: Int16
        if upperIndex >= 0, upperIndex < samples.count {
            upperSample = samples[upperIndex]
        } else if lowerIndex == samples.count - 1, samples.count > 1 {
            // The following chunk is not available yet. Extending the local
            // slope avoids flattening the final fractional interval, which
            // otherwise creates a click-like error at arbitrary tap boundaries.
            let last = Int(samples[samples.count - 1])
            let prior = Int(samples[samples.count - 2])
            upperSample = Int16(clamping: last + (last - prior))
        } else {
            upperSample = samples[samples.count - 1]
        }

        let value = Double(lowerSample) + (Double(upperSample) - Double(lowerSample)) * fraction
        return Int16(clamping: Int(value.rounded()))
    }
}
