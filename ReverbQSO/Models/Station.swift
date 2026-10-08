// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Represents a station listed in the EchoLink directory.
struct Station: Identifiable, Codable, Hashable {
    let id: UUID
    var callsign: String
    var description: String
    var ipAddress: String
    var port: Int
    var type: StationType
    var isBusy: Bool
    /// EchoLink node number (from the directory listing).
    var nodeNumber: Int

    /// The directory's [r] marker denotes a station that can make calls but cannot receive them.
    var isRelayOnly: Bool {
        description.range(of: "[r]", options: .caseInsensitive) != nil
    }

    enum StationType: String, Codable, CaseIterable {
        case user       = "U"
        case link       = "L"
        case repeater   = "R"
        case conference = "C"

        var displayName: String {
            switch self {
            case .user:       return "Operator"
            case .link:       return "Link"
            case .repeater:   return "Repeater"
            case .conference: return "Conference"
            }
        }
    }

    init(
        id: UUID = UUID(),
        callsign: String,
        description: String = "",
        ipAddress: String,
        port: Int = 5198,
        type: StationType = .user,
        isBusy: Bool = false,
        nodeNumber: Int = 0
    ) {
        self.id          = id
        self.callsign    = callsign
        self.description = description
        self.ipAddress   = ipAddress
        self.port        = port
        self.type        = type
        self.isBusy      = isBusy
        self.nodeNumber  = nodeNumber
    }
}

enum StationEndpointResolver {
    /// A stored favorite or recent entry must resolve to a station that is online now.
    /// Its saved address is historical data and must never be used for a new QSO.
    static func resolveStored(_ selected: Station, from currentDirectory: [Station]) -> Station? {
        let callsign = selected.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        return currentDirectory.first {
            $0.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(callsign) == .orderedSame
                && (selected.nodeNumber == 0 || $0.nodeNumber == selected.nodeNumber)
        }
    }

    static func resolve(_ selected: Station, from currentDirectory: [Station]) -> Station {
        let callsign = selected.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        if selected.nodeNumber > 0,
           let current = currentDirectory.first(where: {
               $0.nodeNumber == selected.nodeNumber
                   && $0.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
                       .caseInsensitiveCompare(callsign) == .orderedSame
           }) {
            return current
        }

        return currentDirectory.first {
            $0.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(callsign) == .orderedSame
        } ?? selected
    }
}
