// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Parses the EchoLink directory station list.
///
/// Wire format (from SVXLink/EchoLinkDirectory.cpp):
///
///   @@@\n
///   <count>\n
///   <callsign>\n          ┐
///   <description>\n       │  repeated <count> times
///   <nodeID>\n            │
///   <ip_address>\n        ┘
///   +++
///
/// Station type is inferred from the callsign:
///   ends with "-R"  → Repeater
///   ends with "-L"  → Link (explicit)
///   starts/ends "*" → Conference
///   anything else   → User
enum StationParser {

    // MARK: - Public API

    /// Parse the raw bytes from a `"s"` command response into a `[Station]` array.
    ///
    /// Supports two formats:
    /// 1. EchoLink multi-line directory format (`@@@`, count, 4 lines per station, `+++`)
    /// 2. Legacy single-line format (`TYPE CALLSIGN IP PORT`) and tab-separated variants.
    static func parseDirectory(raw: Data) -> [Station] {
        guard let text = String(data: raw, encoding: .utf8)
                      ?? String(data: raw, encoding: .isoLatin1)
        else { return [] }

        let normalizedText = normalizeDirectoryText(text)

        // Newer directory wire format
        if normalizedText.contains("@@@") && normalizedText.contains("+++") {
            return parseCountedDirectoryText(normalizedText)
        }

        // Fallback to the older per-line station format.
        return parseAll(text: normalizedText)
    }

    static func isValidEmptyCountedDirectory(raw: Data) -> Bool {
        guard let text = String(data: raw, encoding: .utf8)
                      ?? String(data: raw, encoding: .isoLatin1)
        else { return false }

        let normalizedText = normalizeDirectoryText(text)
        guard normalizedText.contains("@@@"), normalizedText.contains("+++") else {
            return false
        }
        guard let startRange = normalizedText.range(of: "@@@\n") else { return false }

        let body = String(normalizedText[startRange.upperBound...])
        var lines = body.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while let first = lines.first, first.isEmpty {
            lines.removeFirst()
        }

        guard let countLine = lines.first, let count = Int(countLine) else {
            return false
        }

        return count == 0
    }

    /// Parse a single legacy station line.
    ///
    /// Supported:
    /// - `TYPE CALLSIGN IP PORT`
    /// - `CALLSIGN<TAB>IP<TAB>DESCRIPTION`
    static func parse(line: String) -> Station? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Tab-separated fallback format.
        if trimmed.contains("\t") {
            let fields = trimmed
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { return nil }

            let callsign = fields[0]
            let ip = fields[1]
            let description = fields.count >= 3 ? fields[2] : ""
            guard !callsign.isEmpty, !ip.isEmpty else { return nil }

            return Station(
                callsign: callsign,
                description: description,
                ipAddress: ip,
                port: Int(DirectoryClient.echoLinkAudioPort),
                type: inferType(from: callsign),
                isBusy: inferBusy(from: callsign, description: description),
                nodeNumber: 0
            )
        }

        // Space-separated canonical legacy format.
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 4 else { return nil }

        let typeCode = parts[0].uppercased()
        let callsign = parts[1]
        let ip = parts[2]
        guard let port = Int(parts[3]) else { return nil }

        let stationType = inferType(from: callsign, explicitTypeCode: typeCode)
        let isBusy = typeCode == "X" || inferBusy(from: callsign, description: "")

        return Station(
            callsign: callsign,
            description: "",
            ipAddress: ip,
            port: port,
            type: stationType,
            isBusy: isBusy,
            nodeNumber: 0
        )
    }

    /// Parse multiple legacy station lines, skipping malformed rows.
    static func parseAll(text: String) -> [Station] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { parse(line: String($0)) }
    }

    // MARK: - Private

    private static func normalizeDirectoryText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func parseCountedDirectoryText(_ normalizedText: String) -> [Station] {
        guard let startRange = normalizedText.range(of: "@@@\n") else { return [] }
        let body = String(normalizedText[startRange.upperBound...])

        var lines = body.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // First non-empty line is the count.
        while let first = lines.first, first.isEmpty {
            lines.removeFirst()
        }
        guard let countLine = lines.first, let count = Int(countLine), count >= 0 else {
            return []
        }
        lines.removeFirst()

        if count == 0 {
            return []
        }

        var stations: [Station] = []
        stations.reserveCapacity(count)

        var idx = 0
        while idx + 3 < lines.count, stations.count < count {
            let callsign    = lines[idx];     idx += 1
            let description = lines[idx];     idx += 1
            let nodeIDStr   = lines[idx];     idx += 1
            let ip          = lines[idx];     idx += 1

            // Stop if we hit the end marker
            if callsign == "+++" { break }
            guard !callsign.isEmpty, !ip.isEmpty else { continue }

            let nodeID = Int(nodeIDStr) ?? 0
            let type   = inferType(from: callsign)
            let isBusy = inferBusy(from: callsign, description: description)

            stations.append(Station(
                callsign:    callsign,
                description: description,
                ipAddress:   ip,
                port:        Int(DirectoryClient.echoLinkAudioPort),
                type:        type,
                isBusy:      isBusy,
                nodeNumber:  nodeID
            ))
        }

        return stations
    }

    private static func inferType(
        from callsign: String,
        explicitTypeCode: String? = nil
    ) -> Station.StationType {
        if let explicitTypeCode {
            switch explicitTypeCode {
            case "U": return .user
            case "R": return .repeater
            case "C": return .conference
            case "L": return .link
            default: break
            }
        }

        let up = callsign.uppercased()
        if up.hasSuffix("-R")           { return .repeater }
        if up.hasPrefix("*")            { return .conference }
        if up.hasSuffix("-L")           { return .link }
        return .user
    }

    private static func inferBusy(from callsign: String, description: String) -> Bool {
        let c = callsign.uppercased()
        let d = description.uppercased()
        return c.hasPrefix("X-")
            || c.hasSuffix("-X")
            || d.contains(" BUSY")
            || d.hasPrefix("BUSY")
            || d.contains("[BUSY]")
    }
}
