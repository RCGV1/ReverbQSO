// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Streaming state for linear PCM resampling.
struct PCMLinearResamplerState {
    fileprivate var sourceSampleRate: Double = 0
    fileprivate var carryInputPosition: Double = 0
    fileprivate var lastSourceSample: Int16?

    mutating func reset() {
        sourceSampleRate = 0
        carryInputPosition = 0
        lastSourceSample = nil
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
            state.sourceSampleRate = sourceSampleRate
            state.carryInputPosition = 0
            state.lastSourceSample = samples.last
            return samples
        }

        if state.sourceSampleRate == 0 || abs(state.sourceSampleRate - sourceSampleRate) > 0.5 {
            state.reset()
            state.sourceSampleRate = sourceSampleRate
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
                    in: samples,
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
        state.lastSourceSample = samples.last

        return output
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
        } else {
            upperSample = samples[samples.count - 1]
        }

        let value = Double(lowerSample) + (Double(upperSample) - Double(lowerSample)) * fraction
        return Int16(clamping: Int(value.rounded()))
    }
}
