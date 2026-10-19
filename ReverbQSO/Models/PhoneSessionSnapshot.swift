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

enum WatchCredentialSyncDisposition: Equatable {
    case ignore
    case deferUntilIdle
    case request
}

enum WatchCredentialSyncPolicy {
    static func disposition(
        phoneAccount: String?,
        linkedPhoneCallsign: String?,
        isWatchLoggedIn: Bool,
        hasSession: Bool,
        isReconnecting: Bool
    ) -> WatchCredentialSyncDisposition {
        guard let phoneAccount,
              !phoneAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ignore
        }
        let accountMatches = linkedPhoneCallsign?.caseInsensitiveCompare(phoneAccount) == .orderedSame
        guard !accountMatches || !isWatchLoggedIn else { return .ignore }
        return hasSession || isReconnecting ? .deferUntilIdle : .request
    }
}

/// Compact station data shared between the iPhone and Watch companions.
struct WatchStationSnapshot: Sendable {
    private static let maxDescriptionLength = 120

    let callsign: String
    let nodeNumber: Int
    let type: String
    let isBusy: Bool
    let isRelayOnly: Bool
    let reportedConnected: Int?
    let reportedLimit: Int?
    let description: String

    init(station: Station) {
        callsign = station.callsign
        nodeNumber = station.nodeNumber
        type = station.type.rawValue
        isBusy = station.isBusy
        isRelayOnly = station.isRelayOnly
        reportedConnected = station.reportedConnections?.connected
        reportedLimit = station.reportedConnections?.limit
        description = String(station.displayDescription.prefix(Self.maxDescriptionLength))
    }

    static func resolving(_ savedStation: Station, from currentDirectory: [Station]) -> WatchStationSnapshot {
        let currentStation = StationEndpointResolver.resolveStored(savedStation, from: currentDirectory)
            ?? savedStation
        return WatchStationSnapshot(station: currentStation)
    }

    init?(dictionary: [String: Any]) {
        guard let callsign = dictionary["callsign"] as? String,
              !callsign.isEmpty,
              let nodeNumber = dictionary["nodeNumber"] as? Int,
              let type = dictionary["type"] as? String,
              Station.StationType(rawValue: type) != nil else { return nil }
        self.callsign = callsign
        self.nodeNumber = nodeNumber
        self.type = type
        // Older iPhone snapshots did not carry availability; retain their
        // previous behavior while preserving the current value when present.
        isBusy = dictionary["isBusy"] as? Bool ?? false
        isRelayOnly = dictionary["isRelayOnly"] as? Bool ?? false
        reportedConnected = dictionary["reportedConnected"] as? Int
        reportedLimit = dictionary["reportedLimit"] as? Int
        description = dictionary["description"] as? String ?? ""
    }

    var dictionary: [String: Any] {
        var value: [String: Any] = [
            "callsign": callsign,
            "nodeNumber": nodeNumber,
            "type": type,
            "isBusy": isBusy,
            "isRelayOnly": isRelayOnly,
            "description": description
        ]
        if let reportedConnected { value["reportedConnected"] = reportedConnected }
        if let reportedLimit { value["reportedLimit"] = reportedLimit }
        return value
    }

    var station: Station {
        var rawDescription = description
        if isRelayOnly,
           rawDescription.range(of: "[r]", options: .caseInsensitive) == nil {
            rawDescription += " [r]"
        }
        if let reportedConnected, let reportedLimit,
           rawDescription.range(of: #"\[\s*\d+\s*/\s*\d+\s*\]\s*$"#, options: .regularExpression) == nil {
            rawDescription += " [\(reportedConnected)/\(reportedLimit)]"
        }
        return Station(
            callsign: callsign,
            description: rawDescription,
            ipAddress: "",
            type: Station.StationType(rawValue: type) ?? .user,
            isBusy: isBusy,
            nodeNumber: nodeNumber
        )
    }

    static func list(from value: Any?) -> [WatchStationSnapshot]? {
        guard let rows = value as? [[String: Any]] else { return nil }
        return rows.compactMap(WatchStationSnapshot.init(dictionary:))
    }
}
