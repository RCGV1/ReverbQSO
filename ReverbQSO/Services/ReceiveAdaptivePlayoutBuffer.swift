// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Small decoded-audio playout buffer. Network reordering happens upstream.
/// Bounds startup jitter protection to 40...100 ms and retained speech to 240 ms.
struct ReceiveAdaptivePlayoutBuffer {
    private struct Packet {
        let samples: [Int16]
        let receivedAt: TimeInterval
        var deadline: TimeInterval
    }
    private var packets: [Packet] = []
    private var lastArrival: TimeInterval?
    private var previousDuration = 0.08
    private var lastDeadline: TimeInterval?
    private var jitter = 0.0
    private var previousTarget = 0.040
    private var hasStarted = false
    private(set) var targetDelay = 0.040
    private(set) var discardedPackets = 0
    var pendingSampleCount: Int { packets.reduce(0) { $0 + $1.samples.count } }
    var nextDeadline: TimeInterval? { packets.first?.deadline }

    mutating func enqueue(_ input: [Int16], networkSampleCount: Int? = nil, playbackQueuedSamples: Int? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !input.isEmpty, now.isFinite else { return }
        let samples = Array(input.suffix(1920))
        if let lastArrival, now - lastArrival < max(0.160, previousDuration * 2), now >= lastArrival {
            let variation = abs((now - lastArrival) - previousDuration)
            jitter += (min(0.1, variation) - jitter) / 16
            targetDelay = min(0.100, max(0.040, 0.040 + 4 * jitter))
        } else {
            jitter = 0
            targetDelay = 0.040
            lastDeadline = nil
            hasStarted = false
        }
        // Add protection only while the actual playback lead is below target.
        // Clock correction releases excess lead gently as target delay recovers.
        let missingLead = playbackQueuedSamples.map { max(0, targetDelay - Double($0) / 8000) } ?? targetDelay
        let adjustment = min(0.010, min(missingLead, max(0, targetDelay - previousTarget)))
        let nominal = hasStarted ? now + max(0, adjustment) : (lastDeadline ?? (now + targetDelay))
        let deadline = max(now, nominal)
        packets.append(Packet(samples: samples, receivedAt: now, deadline: deadline))
        while pendingSampleCount > 1920 {
            packets.removeFirst()
            discardedPackets += 1
        }
        // Bursts/stalls must not leave the newest speech scheduled far in the future.
        if let last = packets.last, last.deadline - now > 0.220 {
            let shift = last.deadline - now - 0.220
            for index in packets.indices { packets[index].deadline = max(now, packets[index].deadline - shift) }
        }
        lastDeadline = packets.last?.deadline
        self.lastArrival = now
        previousDuration = Double(max(1, networkSampleCount ?? samples.count)) / 8000
        previousTarget = targetDelay
    }

    mutating func drain(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [[Int16]] {
        guard now.isFinite else { return [] }
        var ready: [[Int16]] = []
        while let first = packets.first, first.deadline <= now {
            packets.removeFirst()
            if now - first.receivedAt <= 0.240 { ready.append(first.samples); hasStarted = true }
            else { discardedPackets += 1 }
        }
        return ready
    }

    mutating func reset() {
        packets.removeAll(keepingCapacity: true)
        lastArrival = nil
        hasStarted = false
        lastDeadline = nil
        previousDuration = 0.080
        jitter = 0
        targetDelay = 0.040
        previousTarget = 0.040
    }
}
