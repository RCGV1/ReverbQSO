// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Conceals brief gaps in decoded 8 kHz mono speech.
///
/// Keep one instance per receive stream. The concealer intentionally stops
/// generating speech after two 80 ms packets so a stalled stream decays to
/// silence instead of producing an artificial sustained voice.
final class ReceivePacketLossConcealer {
    private static let nominalPacketSamples = 640
    private static let synthesisBudget = nominalPacketSamples * 2
    private static let maximumHistorySamples = nominalPacketSamples * 2
    private static let recoveryBlendSamples = 80
    private static let boundaryBlendSamples = 32
    private static let minimumPitchPeriod = 40
    private static let maximumPitchPeriod = 160

    private var history: [Int16] = []
    private var concealedSampleCount = 0
    private var lastConcealedSample: Int16?

    /// Adds decoded audio to the recent speech history and begins a new loss run.
    func record(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        appendToHistory(samples)
        concealedSampleCount = 0
        lastConcealedSample = nil
    }

    /// Produces at most two nominal packets of concealment for the current gap.
    /// Samples beyond the synthesis budget are silence.
    func conceal(sampleCount: Int) -> [Int16] {
        guard sampleCount > 0 else { return [] }
        let outputCount = min(sampleCount, Self.synthesisBudget)
        guard !history.isEmpty else {
            concealedSampleCount = min(Self.synthesisBudget, concealedSampleCount + outputCount)
            lastConcealedSample = nil
            return [Int16](repeating: 0, count: outputCount)
        }

        let remainingSynthesis = max(0, Self.synthesisBudget - concealedSampleCount)
        let generatedCount = min(outputCount, remainingSynthesis)
        let period = estimatedPitchPeriod()
        let cycle = Array(history.suffix(period))
        let historyPeak = history.suffix(Self.nominalPacketSamples).map { abs(Int($0)) }.max() ?? 0
        let isEffectivelySilent = historyPeak < 32
        var output = [Int16]()
        output.reserveCapacity(outputCount)

        for localIndex in 0..<generatedCount {
            let lossIndex = concealedSampleCount + localIndex
            let envelope = max(0, 1 - Double(lossIndex + 1) / Double(Self.synthesisBudget))
            var value = isEffectivelySilent ? 0 : Double(cycle[lossIndex % cycle.count]) * envelope

            if lossIndex < Self.boundaryBlendSamples, let previous = history.last {
                let blend = Double(lossIndex + 1) / Double(Self.boundaryBlendSamples)
                value = Double(previous) * (1 - blend) + value * blend
            }
            output.append(clampedInt16(value))
        }
        if output.count < outputCount {
            output.append(contentsOf: repeatElement(0, count: outputCount - output.count))
        }

        concealedSampleCount = min(Self.synthesisBudget, concealedSampleCount + outputCount)
        lastConcealedSample = output.last
        return output
    }

    /// Smooths the first 10 ms of returning audio after concealment and records
    /// the actual received samples as the basis for any later loss.
    func processReceived(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        guard concealedSampleCount > 0, let previous = lastConcealedSample else {
            record(samples)
            return samples
        }

        var output = samples
        let blendCount = min(Self.recoveryBlendSamples, samples.count)
        for index in 0..<blendCount {
            let receivedWeight = Double(index + 1) / Double(blendCount)
            let value = Double(previous) * (1 - receivedWeight)
                + Double(samples[index]) * receivedWeight
            output[index] = clampedInt16(value)
        }
        appendToHistory(samples)
        concealedSampleCount = 0
        lastConcealedSample = nil
        return output
    }

    func reset() {
        history.removeAll(keepingCapacity: false)
        concealedSampleCount = 0
        lastConcealedSample = nil
    }

    private func appendToHistory(_ samples: [Int16]) {
        if samples.count >= Self.maximumHistorySamples {
            history = Array(samples.suffix(Self.maximumHistorySamples))
            return
        }
        history.append(contentsOf: samples)
        if history.count > Self.maximumHistorySamples {
            history.removeFirst(history.count - Self.maximumHistorySamples)
        }
    }

    /// Finds the lag with the strongest normalized correlation in the latest
    /// 40 ms. The lag range covers roughly 50...200 Hz at 8 kHz, where voiced
    /// radio speech has the clearest repeatable structure.
    private func estimatedPitchPeriod() -> Int {
        let analysisCount = min(320, history.count)
        guard analysisCount >= Self.maximumPitchPeriod * 2 else {
            return min(80, history.count)
        }
        let samples = history.suffix(analysisCount).map(Double.init)
        var bestLag = 80
        var bestScore = -Double.infinity

        for lag in Self.minimumPitchPeriod...Self.maximumPitchPeriod {
            let comparisonCount = samples.count - lag
            var correlation = 0.0
            var currentEnergy = 0.0
            var delayedEnergy = 0.0
            for index in 0..<comparisonCount {
                let current = samples[index + lag]
                let delayed = samples[index]
                correlation += current * delayed
                currentEnergy += current * current
                delayedEnergy += delayed * delayed
            }
            let denominator = sqrt(currentEnergy * delayedEnergy)
            let score = denominator > 1 ? correlation / denominator : 0
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        return bestLag
    }

    private func clampedInt16(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(clamping: Int(value.rounded()))
    }
}
