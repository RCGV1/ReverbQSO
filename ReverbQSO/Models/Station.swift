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

    /// Operator-written description without directory status or connection counts.
    var displayDescription: String {
        let text = descriptionWithoutStatus
        guard let match = capacityMatch(in: text) else { return text }
        return (text as NSString).replacingCharacters(in: match.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct ConnectionCount: Equatable {
        let connected: Int
        let limit: Int
        var isAtReportedLimit: Bool { connected >= limit }
        var displayText: String { "\(connected) connected" }
    }

    /// Optional station-published count. Absence means unknown, never zero.
    var reportedConnections: ConnectionCount? {
        let text = descriptionWithoutStatus
        guard let match = capacityMatch(in: text),
              let connected = Int((text as NSString).substring(with: match.range(at: 1))),
              let limit = Int((text as NSString).substring(with: match.range(at: 2))) else { return nil }
        return ConnectionCount(connected: connected, limit: limit)
    }

    /// The configured limit in a description is not necessarily enforced by the
    /// node. Require its busy status before treating that limit as a rejection.
    var isConnectionLimitReached: Bool {
        isBusy && reportedConnections?.isAtReportedLimit == true
    }

    var connectionUnavailableReason: String? {
        if isRelayOnly { return "This station cannot receive calls." }
        if isConnectionLimitReached, let count = reportedConnections {
            return "Connection limit reached (\(count.displayText); advertised limit \(count.limit))."
        }
        if isBusy { return "This station is not accepting new connections." }
        return nil
    }

    private func capacityMatch(in text: String) -> NSTextCheckingResult? {
        guard let match = Self.connectionCapacitySuffix.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        ), let limit = Int((text as NSString).substring(with: match.range(at: 2))), limit > 0 else { return nil }
        return match
    }

    private var descriptionWithoutStatus: String {
        let range = NSRange(description.startIndex..., in: description)
        return Self.directoryStatusSuffix.stringByReplacingMatches(
            in: description, range: range, withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let connectionCapacitySuffix = try! NSRegularExpression(
        pattern: #"\s*\[(\d{1,9})\s*/\s*(\d{1,9})\]\s*$"#
    )

    private static let directoryStatusSuffix = try! NSRegularExpression(
        pattern: #"\s*\[(?:ON|BUSY)(?:\s+|\s*:\s*)(?:[01]\d|2[0-3]):[0-5]\d\]\s*$"#,
        options: .caseInsensitive
    )

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
