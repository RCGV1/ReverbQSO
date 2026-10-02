// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

struct QSOActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var isTransmitting: Bool
    }

    var callsign: String
    var startedAt: Date
}
#endif
