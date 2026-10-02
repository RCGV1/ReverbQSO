// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Gives one participant the conference floor until their voice stream pauses.
/// The host rebuilds its own RTP sequence, so a handoff does not expose the
/// incoming station's unrelated sequence numbers to listeners.
struct ConferenceFloorRouter {
    let holdInterval: TimeInterval
    private(set) var talkerID: UUID?
    private var lastVoiceAt: Date?

    init(holdInterval: TimeInterval = 0.6) {
        self.holdInterval = holdInterval
    }

    /// Returns the listeners for a voice packet, or an empty list when another
    /// station still owns the floor. The source never hears its own packet.
    mutating func listeners(for sourceID: UUID, activeIDs: [UUID], at now: Date) -> [UUID] {
        guard activeIDs.contains(sourceID) else { return [] }
        expire(at: now)
        guard talkerID == nil || talkerID == sourceID else { return [] }
        talkerID = sourceID
        lastVoiceAt = now
        return activeIDs.filter { $0 != sourceID }
    }

    @discardableResult
    mutating func expire(at now: Date) -> UUID? {
        guard let talkerID, let lastVoiceAt,
              now.timeIntervalSince(lastVoiceAt) >= holdInterval else { return nil }
        self.talkerID = nil
        self.lastVoiceAt = nil
        return talkerID
    }

    mutating func remove(_ id: UUID) {
        guard talkerID == id else { return }
        talkerID = nil
        lastVoiceAt = nil
    }

    mutating func reset() {
        talkerID = nil
        lastVoiceAt = nil
    }
}
