// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct CallCQPreferences: Equatable {
    var languageCodes: Set<String>
    /// Empty means that any country is accepted.
    var countryCodes: Set<String>
    var nodeTypes: Set<Station.StationType>
    var avoidRecentContacts: Bool

    static let `default` = CallCQPreferences(
        languageCodes: ["en"],
        countryCodes: [],
        nodeTypes: [.user, .link, .repeater],
        avoidRecentContacts: true
    )
}

enum CallCQState: Equatable {
    case idle
    case waiting
    case matched(Station)
    case failed(String)
}
