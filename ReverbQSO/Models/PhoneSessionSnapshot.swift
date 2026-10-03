// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct PhoneSessionSnapshot: Sendable {
    var callsign = ""
    var connected = false
    var isTransmitting = false
    var isRemoteTransmitting = false
    var isDemo = false
    var sessionID: UUID?
    var watchAudioOutputEnabled = false

    init() {}

    init(dictionary: [String: Any]) {
        callsign = dictionary["callsign"] as? String ?? ""
        connected = dictionary["connected"] as? Bool ?? false
        isTransmitting = dictionary["isTransmitting"] as? Bool ?? false
        isRemoteTransmitting = dictionary["isRemoteTransmitting"] as? Bool ?? false
        isDemo = dictionary["demo"] as? Bool ?? false
        sessionID = (dictionary["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        watchAudioOutputEnabled = dictionary["watchAudioOutputEnabled"] as? Bool ?? false
    }

    func applyingCompanionReachability(_ reachable: Bool) -> PhoneSessionSnapshot {
        guard !reachable else { return self }
        var snapshot = self
        // Reachability only describes whether an interactive command can be
        // delivered now. Application context remains authoritative for the
        // phone QSO and remote receive state.
        snapshot.isTransmitting = false
        return snapshot
    }
}
