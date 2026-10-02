// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A currently known participant on the connected EchoLink node/conference.
struct ActiveNodeParticipant: Identifiable, Equatable {
    /// Callsign-like identifier used as the stable identity key.
    let callsign: String
    /// Optional richer display label sourced from control metadata.
    var displayName: String?
    /// Best-effort transmit state inferred from control/audio activity.
    var isTransmitting: Bool
    /// Last time this participant was observed in control/audio signals.
    var lastActivity: Date

    var id: String { callsign }
}
