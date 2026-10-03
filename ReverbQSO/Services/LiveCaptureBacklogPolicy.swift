// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum LiveCaptureBacklogPolicy {
    static let maximumPendingBuffers = 8
    static let maximumAge: TimeInterval = 0.24
    static func tapFrames(sampleRate: Double) -> UInt32 {
        guard sampleRate.isFinite, sampleRate > 0 else { return 160 }
        return UInt32(min(7_680, max(100, (sampleRate * 0.02).rounded())))
    }
    static func canAccept(pending: Int) -> Bool { pending < maximumPendingBuffers }
    static func isFresh(capturedAt: TimeInterval, now: TimeInterval) -> Bool {
        let age = now - capturedAt
        return age.isFinite && age >= 0 && age <= maximumAge
    }
}
