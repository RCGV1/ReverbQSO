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
    let maximumSamples = 1_920 // 240 ms at 8 kHz
    func needsReset(adding count: Int) -> Bool { queuedSamples + count > maximumSamples }
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
