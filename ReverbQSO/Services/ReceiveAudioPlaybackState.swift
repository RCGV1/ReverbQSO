// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ReceivePlaybackGain {
    private static let maximumGain = 2.5
    private static let peakLimit = 0.95
    private static let attackSamples = 80
    private static let releaseStep = 1 - exp(-1.0 / (8_000 * 0.3))
    private var gain = Self.maximumGain

    mutating func process(_ samples: [Int16]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let peak = Double(samples.reduce(0) { max($0, abs(Int($1))) }) / 32768
        let target = peak > 0 ? min(Self.maximumGain, Self.peakLimit / peak) : Self.maximumGain
        if target < gain {
            let initialGain = gain
            let end = samples.firstIndex {
                Double(abs(Int($0))) / 32768 * initialGain > Self.peakLimit
            } ?? 0
            let start = max(0, end - Self.attackSamples)
            gain = target
            // The packet already provides lookahead. Finish the ramp before
            // its first unsafe sample, without delaying or clipping speech.
            return samples.enumerated().map { index, sample in
                let appliedGain: Double
                if index < start { appliedGain = initialGain }
                else if index < end {
                    let progress = Double(index - start) / Double(end - start)
                    appliedGain = initialGain + (target - initialGain) * progress
                } else { appliedGain = target }
                return Float(Double(sample) / 32768 * appliedGain)
            }
        }

        // Recover over 300 ms of samples, not a step at each packet boundary.
        return samples.map { sample in
            let output = Float(Double(sample) / 32768 * gain)
            gain += (target - gain) * Self.releaseStep
            return output
        }
    }
    mutating func reset() { gain = Self.maximumGain }
}

struct ReceivePlaybackQueue {
    private(set) var queuedSamples = 0
    private(set) var generation: UInt64 = 0
    let maximumSamples = 2_576 // 322 ms (includes up to 0.5% clock correction) at 8 kHz
    // Absorb two extra packets during measured native startup or short bursts.
    // Overflow rejects incoming speech while preserving the running timeline.
    let recoverySamples = 1_280 // 160 ms concealment budget
    func concealmentSampleBudget(receivedSamples: Int, remainingSamples: Int, pendingSamples: Int = 0) -> Int {
        var budget = recoverySamples
        for count in [receivedSamples, remainingSamples, pendingSamples] {
            budget -= min(budget, max(0, count))
        }
        return budget
    }
    /// Decoder state has already advanced over the full loss. Render only the
    /// recent synthesized tail that fits, preserving capacity for received voice
    /// and the next packet instead of restarting playback to discard real speech.
    func retainedConcealment(_ samples: [Int16], receivedSamples: Int, remainingSamples: Int,
                             pendingSamples: Int = 0) -> ArraySlice<Int16> {
        let available = concealmentSampleBudget(receivedSamples: receivedSamples,
            remainingSamples: remainingSamples, pendingSamples: pendingSamples)
        return samples.suffix(available)
    }
    /// Completion callbacks can arrive after the player has rendered their audio.
    /// Use the render timeline when available so delayed callbacks cannot stop
    /// healthy playback and discard speech that is still scheduled.
    func wouldOverflow(adding count: Int, remainingSamples: Int? = nil) -> Bool {
        max(0, remainingSamples ?? queuedSamples) + count > maximumSamples
    }
    mutating func reserve(_ count: Int) -> UInt64 {
        queuedSamples += count
        return generation
    }
    mutating func complete(_ count: Int, generation token: UInt64) {
        guard token == generation else { return }
        queuedSamples = max(0, queuedSamples - count)
    }
    mutating func reset() { generation &+= 1; queuedSamples = 0 }
}

/// Retains the already processed mono audio still waiting for the player.
/// The render cursor can be negative during output preroll; that is latency,
/// not additional audio. Overflow keeps only the newest unrendered samples.
struct ReceivePlaybackHistory {
    private(set) var samples: [Float] = []
    private(set) var startSampleTime: Int64 = 0

    func remainingSamples(renderedSampleTime: Int64?) -> Int {
        guard let renderedSampleTime else { return samples.count }
        let consumed = max(0, min(Int64(samples.count), max(0, renderedSampleTime) - startSampleTime))
        return samples.count - Int(consumed)
    }

    mutating func prune(renderedSampleTime: Int64) {
        let remaining = remainingSamples(renderedSampleTime: renderedSampleTime)
        let consumed = samples.count - remaining
        guard consumed > 0 else { return }
        samples.removeFirst(consumed)
        startSampleTime += Int64(consumed)
    }

    mutating func append(_ input: [Float], startingAt sampleTime: Int64) {
        if samples.isEmpty { startSampleTime = max(0, sampleTime) }
        samples.append(contentsOf: input)
    }

    func boundedReplacement(adding input: [Float], maximumSamples: Int) -> (samples: [Float], discardedSamples: Int) {
        let capacity = max(0, maximumSamples)
        let newestInput = Array(input.suffix(capacity))
        let retained = samples.suffix(max(0, capacity - newestInput.count))
        return (Array(retained) + newestInput, samples.count + input.count - retained.count - newestInput.count)
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        startSampleTime = 0
    }
}
