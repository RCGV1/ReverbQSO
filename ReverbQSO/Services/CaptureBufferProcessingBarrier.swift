// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Bounds DSP work independently of results awaiting delivery. Release waits
/// for both phases so the final codec flush cannot overtake captured speech.
final class CaptureBufferProcessingBarrier: @unchecked Sendable {
    struct Snapshot: Sendable {
        let pendingDSP: Int
        let pendingDelivery: Int
        let rejectedBuffers: Int
        let isSealed: Bool
    }

    private let lock = NSLock()
    private var pendingDSP = 0
    private var pendingDelivery = 0
    private var rejectedBuffers = 0
    private var isSealed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(pendingDSP: pendingDSP, pendingDelivery: pendingDelivery,
                        rejectedBuffers: rejectedBuffers, isSealed: isSealed)
    }

    func enter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSealed else { return false }
        guard LiveCaptureBacklogPolicy.canAccept(pending: pendingDSP),
              pendingDelivery < LiveCaptureBacklogPolicy.maximumPendingDeliveries else {
            rejectedBuffers += 1
            return false
        }
        pendingDSP += 1
        pendingDelivery += 1
        return true
    }

    /// Called on the DSP queue before scheduling MainActor delivery.
    func finishDSP() {
        lock.lock()
        defer { lock.unlock() }
        precondition(pendingDSP > 0)
        pendingDSP -= 1
    }

    /// Called after a completed result has been delivered or discarded.
    func leave() {
        lock.lock()
        precondition(pendingDelivery > pendingDSP)
        pendingDelivery -= 1
        guard pendingDelivery == 0, isSealed else {
            lock.unlock()
            return
        }
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func sealAndWait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            isSealed = true
            if pendingDelivery == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
