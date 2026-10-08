// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Observations of directory listings, rather than proof that a peer accepts calls.
struct StationDirectoryObservation: Equatable {
    let firstSeenAt: Date
    let lastSeenAt: Date
    let consecutiveSnapshots: Int
}

struct StationDirectoryObservationTracker {
    private struct Identity: Hashable {
        let callsign: String
        let nodeNumber: Int

        init(_ station: Station) {
            callsign = station.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            nodeNumber = station.nodeNumber
        }
    }

    private var observations: [Identity: StationDirectoryObservation] = [:]

    func observation(for station: Station) -> StationDirectoryObservation? {
        observations[Identity(station)]
    }

    mutating func record(_ stations: [Station], at date: Date) {
        var current: [Identity: StationDirectoryObservation] = [:]
        current.reserveCapacity(stations.count)
        for station in stations {
            let identity = Identity(station)
            guard current[identity] == nil else { continue }
            let previous = observations[identity]
            current[identity] = StationDirectoryObservation(
                firstSeenAt: previous?.firstSeenAt ?? date,
                lastSeenAt: date,
                consecutiveSnapshots: (previous?.consecutiveSnapshots ?? 0) + 1
            )
        }
        observations = current
    }

    mutating func reset() { observations.removeAll() }
}
