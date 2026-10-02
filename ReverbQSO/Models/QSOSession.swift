// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Represents an active QSO (contact) session with a remote EchoLink station.
struct QSOSession: Identifiable {
    let id: UUID
    let station: Station
    var startTime: Date
    var state: SessionState
    var sysopInfo: String
    var isMuted: Bool
    var isPTTActive: Bool

    /// The lifecycle state of a QSO session.
    enum SessionState: Equatable {
        case connecting
        case connected
        case disconnecting
        case disconnected
    }

    init(
        id: UUID = UUID(),
        station: Station,
        startTime: Date = Date(),
        state: SessionState = .connecting,
        sysopInfo: String = "",
        isMuted: Bool = false,
        isPTTActive: Bool = false
    ) {
        self.id = id
        self.station = station
        self.startTime = startTime
        self.state = state
        self.sysopInfo = sysopInfo
        self.isMuted = isMuted
        self.isPTTActive = isPTTActive
    }
}
