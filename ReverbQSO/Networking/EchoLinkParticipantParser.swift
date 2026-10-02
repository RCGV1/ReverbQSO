// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Parsed participant roster update extracted from EchoLink control/info text.
struct EchoLinkParticipantUpdate: Equatable {
    enum Kind: Equatable {
        case upsert
        case remove
    }

    let callsign: String
    let isTransmitting: Bool?
    let kind: Kind
}

/// Heuristic parser for participant and TX status updates embedded in EchoLink control/info text.
///
/// EchoLink implementations vary in status phrasing across peers, so this parser focuses on:
/// - robust callsign extraction
/// - conservative TX ON/OFF keyword detection
/// - join/leave lifecycle hints
enum EchoLinkParticipantParser {
    private static let callsignExpression = try! NSRegularExpression(
        pattern: #"\b(?=[A-Z0-9-]{3,12}\b)(?=[A-Z0-9-]*[A-Z])(?=[A-Z0-9-]*[0-9])[A-Z0-9]+(?:-[A-Z0-9]{1,4})?\b"#,
        options: []
    )

    private static let joinKeywords = [
        " connected",
        " joined",
        " online",
        " linked",
        " login"
    ]

    private static let leaveKeywords = [
        " disconnected",
        " left",
        " offline",
        " unlinked",
        " logout",
        " dropped",
        " timed out"
    ]

    private static let txOnKeywords = [
        " is transmitting",
        " transmitting",
        " keyed",
        " key up",
        " talking",
        " speaking",
        " ptt on",
        " tx on"
    ]

    private static let txOffKeywords = [
        " stopped transmitting",
        " not transmitting",
        " unkey",
        " dekey",
        " tx off",
        " listening",
        " rx only",
        " idle"
    ]

    static func firstCallsign(in text: String) -> String? {
        extractCallsigns(from: text).first
    }

    static func extractCallsigns(from text: String) -> [String] {
        let uppercased = text.uppercased()
        let nsText = uppercased as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = callsignExpression.matches(in: uppercased, options: [], range: fullRange)

        var callsigns: [String] = []
        var seen = Set<String>()
        for match in matches {
            guard match.range.length > 0 else { continue }
            let raw = nsText.substring(with: match.range)
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            callsigns.append(normalized)
        }
        return callsigns
    }

    static func parseInfoMessage(_ text: String) -> [EchoLinkParticipantUpdate] {
        var updates: [EchoLinkParticipantUpdate] = []

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            let callsigns = extractCallsigns(from: line)
            guard !callsigns.isEmpty else { continue }

            let lowercased = " " + line.lowercased() + " "
            let isJoin = containsAnyKeyword(in: lowercased, keywords: joinKeywords)
            let isLeave = containsAnyKeyword(in: lowercased, keywords: leaveKeywords) && !isJoin

            let txOff = containsAnyKeyword(in: lowercased, keywords: txOffKeywords)
            // Negative phrases contain positive words ("not transmitting",
            // "stopped transmitting"). Remove those phrases before looking for
            // an independent TX-on signal, preserving truly conflicting lines.
            let positiveStatus = txOffKeywords.reduce(lowercased) { status, phrase in
                status.replacingOccurrences(of: phrase, with: " ")
            }
            let txOn = containsAnyKeyword(in: positiveStatus, keywords: txOnKeywords)
            let txState: Bool?
            if txOn != txOff {
                txState = txOn
            } else {
                txState = nil
            }

            for callsign in callsigns {
                if isLeave {
                    updates.append(
                        EchoLinkParticipantUpdate(
                            callsign: callsign,
                            isTransmitting: nil,
                            kind: .remove
                        )
                    )
                } else {
                    updates.append(
                        EchoLinkParticipantUpdate(
                            callsign: callsign,
                            isTransmitting: txState,
                            kind: .upsert
                        )
                    )
                }
            }
        }

        return updates
    }

    private static func containsAnyKeyword(in text: String, keywords: [String]) -> Bool {
        for keyword in keywords {
            if text.contains(keyword) {
                return true
            }
        }
        return false
    }
}
