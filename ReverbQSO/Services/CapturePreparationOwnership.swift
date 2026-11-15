// SPDX-License-Identifier: GPL-3.0-or-later

/// Ownership transitions shared by direct prewarm and engine-scheduled preparation.
/// AudioEngine serializes access on the main actor and publishes the preparing state.
struct CapturePreparationOwnership {
    private var generation: UInt64 = 0
    private(set) var isPreparing = false

    mutating func begin() -> UInt64? {
        guard !isPreparing else { return nil }
        isPreparing = true
        return generation
    }

    @discardableResult
    mutating func finish(generation owner: UInt64) -> Bool {
        guard isCurrent(owner) else { return false }
        isPreparing = false
        return true
    }

    mutating func schedule(hasPendingTask: Bool) -> UInt64? {
        // A direct preparation owns its generation even without an engine task.
        guard !hasPendingTask, !isPreparing else { return nil }
        generation &+= 1
        return generation
    }

    func isCurrent(_ owner: UInt64) -> Bool {
        generation == owner
    }

    mutating func reset() {
        generation &+= 1
        isPreparing = false
    }
}
