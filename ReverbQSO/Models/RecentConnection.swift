// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A recorded past QSO session, used to populate the Recents tab.
struct RecentConnection: Identifiable, Codable {
    let id: UUID
    let station: Station
    let date: Date
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        station: Station,
        date: Date = Date(),
        duration: TimeInterval
    ) {
        self.id = id
        self.station = station
        self.date = date
        self.duration = duration
    }
}
