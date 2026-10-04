// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Session totals, sampled on demand without publishing from the voice path.
struct QSOAudioDiagnosticsSnapshot {
    var sessionID: UUID?
    var sampledAt = 0.0
    var transport = "—"
    var txCodec = "GSM"
    var rxCodec: String?
    var txPackets = 0
    var rxPackets = 0
    var txPayloadBytes = 0
    var rxPayloadBytes = 0
    var sequencedRXPackets = 0
    var missingRXPackets = 0
    var duplicateOrLateRXPackets = 0
    var invalidRXPackets = 0
    var txQueueDrops = 0
    var transportRXDrops = 0
    var playbackRXDrops = 0
    var playbackRefills = 0
    var txQueuedPackets = 0
    var rxQueuedPackets = 0
    var playbackBufferedMilliseconds = 0.0
    var startupBufferMilliseconds = 0.0

    var estimatedRXLossPercent: Double? {
        let expected = sequencedRXPackets + missingRXPackets
        guard expected > 0 else { return nil }
        return Double(missingRXPackets) / Double(expected) * 100
    }
}

struct QSOAudioBitrates {
    var txKilobitsPerSecond: Double?
    var rxKilobitsPerSecond: Double?
}

/// Payload rates over the last sampling interval, including idle time.
struct QSOAudioBitrateSampler {
    private var previous: (snapshot: QSOAudioDiagnosticsSnapshot, time: TimeInterval)?

    mutating func sample(_ snapshot: QSOAudioDiagnosticsSnapshot, now: TimeInterval) -> QSOAudioBitrates {
        guard now.isFinite else { return QSOAudioBitrates() }
        defer { previous = (snapshot, now) }
        guard let previous, snapshot.sessionID != nil,
              previous.snapshot.sessionID == snapshot.sessionID,
              now > previous.time,
              snapshot.txPayloadBytes >= previous.snapshot.txPayloadBytes,
              snapshot.rxPayloadBytes >= previous.snapshot.rxPayloadBytes else {
            return QSOAudioBitrates()
        }
        let scale = 8 / (now - previous.time) / 1000
        return QSOAudioBitrates(
            txKilobitsPerSecond: Double(snapshot.txPayloadBytes - previous.snapshot.txPayloadBytes) * scale,
            rxKilobitsPerSecond: Double(snapshot.rxPayloadBytes - previous.snapshot.rxPayloadBytes) * scale
        )
    }
}
