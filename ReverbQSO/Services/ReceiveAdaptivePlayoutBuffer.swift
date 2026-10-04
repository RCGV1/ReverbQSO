// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Small decoded-audio playout buffer. Network reordering happens upstream.
/// Bounds startup jitter protection to 40...100 ms and waiting age to 240 ms.
struct ReceiveAdaptivePlayoutBuffer {
    // A proxy read can deliver several intact packets together after a stall.
    // Keep six packets while native output consumes them; this is capacity,
    // not a six-packet startup delay. Expiration still bounds local waiting.
    private static let maximumPendingSamples = 3_840
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
    private(set) var capacityDiscardedPackets = 0
    private(set) var expiredDiscardedPackets = 0
    private(set) var maximumObservedWait = 0.0
    var pendingSampleCount: Int { packets.reduce(0) { $0 + $1.samples.count } }
    var nextDeadline: TimeInterval? { packets.first?.deadline }

    mutating func enqueue(_ input: [Int16], networkSampleCount: Int? = nil, playbackQueuedSamples: Int? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !input.isEmpty, now.isFinite else { return }
        let samples = Array(input.suffix(1920))
        if let lastArrival, now - lastArrival < 0.5, now >= lastArrival {
            let variation = abs((now - lastArrival) - previousDuration)
            jitter += (min(0.1, variation) - jitter) / 16
            targetDelay = min(0.100, max(0.040, 0.040 + 4 * jitter))
        } else {
            jitter = 0
            targetDelay = 0.040
            lastDeadline = nil
            hasStarted = false
        }
        // Match the codec/clock talkspurt timeout: a delayed continuous packet
        // must not pay startup buffering again merely because it arrived late.
        // Grow protection only while existing rendered lead covers the wait.
        // Waiting with depleted playback would add silence to the late packet.
        // Clock correction releases excess lead gently as target delay recovers.
        let missingLead = playbackQueuedSamples.map { max(0, targetDelay - Double($0) / 8000) } ?? targetDelay
        let availableLead = playbackQueuedSamples.map { max(0, Double($0) / 8000) } ?? 0.010
        let adjustment = min(availableLead, min(0.010, min(missingLead, max(0, targetDelay - previousTarget))))
        let nominal = hasStarted ? now + max(0, adjustment) : (lastDeadline ?? (now + targetDelay))
        let deadline = max(now, nominal)
        packets.append(Packet(samples: samples, receivedAt: now, deadline: deadline))
        while pendingSampleCount > Self.maximumPendingSamples {
            packets.removeFirst()
            discardedPackets += 1
            capacityDiscardedPackets += 1
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

    /// Leave ready speech here until the renderer has room. Draining into a
    /// full native queue merely moves loss from one buffer to another.
    mutating func drain(now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                        maximumSamples: Int = Int.max) -> [[Int16]] {
        guard now.isFinite else { return [] }
        var ready: [[Int16]] = []
        var available = max(0, maximumSamples)
        while let first = packets.first, first.deadline <= now {
            maximumObservedWait = max(maximumObservedWait, now - first.receivedAt)
            if now - first.receivedAt > 0.240 {
                packets.removeFirst()
                discardedPackets += 1
                expiredDiscardedPackets += 1
                continue
            }
            guard first.samples.count <= available else { break }
            packets.removeFirst()
            available -= first.samples.count
            ready.append(first.samples)
            hasStarted = true
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
