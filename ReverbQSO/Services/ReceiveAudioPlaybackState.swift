// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ReceivePlaybackGain {
    private var gain: Float = 2.5
    mutating func process(_ samples: [Int16]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let peak = Float(samples.reduce(0) { max($0, abs(Int($1))) }) / 32768
        let target = peak > 0 ? min(2.5, 0.95 / peak) : 2.5
        // Reduce gain before a loud buffer, then recover over 300 ms. Apply
        // one gain to the waveform instead of flattening individual peaks.
        if target < gain { gain = target }
        else { gain += (target - gain) * Float(1 - exp(-Double(samples.count) / 8_000 / 0.3)) }
        return samples.map { Float($0) / 32768 * gain }
    }
    mutating func reset() { gain = 2.5 }
}

struct ReceivePlaybackQueue {
    private(set) var queuedSamples = 0
    private(set) var generation: UInt64 = 0
    let maximumSamples = 1_936 // 242 ms (includes up to 0.5% clock correction) at 8 kHz
    // A stopped player needs preroll before it can consume the replacement.
    // Leave a full 80 ms packet of headroom so that packet cannot immediately
    // stop the player again while its render cursor is still zero/negative.
    let recoverySamples = 1_280 // 160 ms recovery low water
    /// Decoder state has already advanced over the full loss. Render only the
    /// recent synthesized tail that fits, preserving capacity for received voice
    /// and the next packet instead of restarting playback to discard real speech.
    func retainedConcealment(_ samples: [Int16], receivedSamples: Int, remainingSamples: Int) -> ArraySlice<Int16> {
        let available = max(0, recoverySamples - max(0, receivedSamples) - max(0, remainingSamples))
        return samples.suffix(available)
    }
    /// Completion callbacks can arrive after the player has rendered their audio.
    /// Use the render timeline when available so delayed callbacks cannot stop
    /// healthy playback and discard speech that is still scheduled.
    func needsReset(adding count: Int, remainingSamples: Int? = nil) -> Bool {
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
