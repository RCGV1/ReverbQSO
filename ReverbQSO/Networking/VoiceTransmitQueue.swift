// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A small, age-bounded FIFO for live voice packets.
///
/// When a transport falls behind, retaining recent speech is preferable to
/// sending an ever-growing backlog of audio that is no longer timely.
struct VoiceTransmitQueue<Payload> {
    private struct Entry {
        let payload: Payload
        let insertedAt: TimeInterval
    }

    private let maximumCount: Int
    private let maximumAge: TimeInterval
    private let now: () -> TimeInterval
    private var entries: [Entry] = []

    private(set) var discardedCount = 0

    init(
        maximumCount: Int = 3,
        maximumAge: TimeInterval = 0.24,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        precondition(maximumCount > 0)
        precondition(maximumAge >= 0 && maximumAge.isFinite)
        self.maximumCount = maximumCount
        self.maximumAge = maximumAge
        self.now = now
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    mutating func enqueue(_ payload: Payload, insertedAt: TimeInterval? = nil) {
        entries.append(Entry(payload: payload, insertedAt: insertedAt ?? now()))
        if entries.count > maximumCount {
            let overflow = entries.count - maximumCount
            entries.removeFirst(overflow)
            discardedCount += overflow
        }
    }

    mutating func dequeue() -> Payload? {
        let currentTime = now()
        while let first = entries.first,
              currentTime - first.insertedAt > maximumAge {
            entries.removeFirst()
            discardedCount += 1
        }
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst().payload
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        entries.removeAll(keepingCapacity: keepingCapacity)
    }
}
