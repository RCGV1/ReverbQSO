// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum SvxLinkControlError: Error, Equatable {
    case invalidCallsign
    case invalidLogicName
    case invalidDTMF
}

/// Encodes documented SvxLink PTY commands. The caller chooses the appropriate PTY.
enum SvxLinkCommandEncoder {
    static func killTalker() -> Data {
        Data("KILL\n".utf8)
    }

    static func disconnect(callsign: String) throws -> Data {
        guard isValidCallsign(callsign) else { throw SvxLinkControlError.invalidCallsign }
        return Data("DISC \(callsign.uppercased())\n".utf8)
    }

    static func setOnline(logicName: String, online: Bool) throws -> Data {
        let bytes = Array(logicName.utf8)
        guard !bytes.isEmpty, bytes.count <= 64,
              isASCIILetter(bytes[0]),
              bytes.allSatisfy({ isASCIIAlphanumeric($0) || $0 == 95 }) else {
            throw SvxLinkControlError.invalidLogicName
        }
        return Data("CFG \(logicName) ONLINE \(online ? 1 : 0)\n".utf8)
    }

    /// DTMF input goes only to `DTMF_CTRL_PTY`, never to a command PTY.
    static func dtmf(_ digits: String) throws -> Data {
        let bytes = Array(digits.utf8)
        guard bytes.count >= 2, bytes.count <= 32,
              bytes.last == 35,
              bytes.dropLast().allSatisfy({ isASCIIDigit($0) || $0 == 42 || (65...68).contains($0) }) else {
            throw SvxLinkControlError.invalidDTMF
        }
        return Data("\(digits)\n".utf8)
    }

    private static func isValidCallsign(_ callsign: String) -> Bool {
        let bytes = Array(callsign.utf8)
        guard (3...15).contains(bytes.count) else { return false }
        let upper = callsign.uppercased()
        let normalized = Array(upper.utf8)
        guard normalized.count == bytes.count else { return false }

        if normalized.first == 42 && normalized.last == 42 {
            return normalized.count >= 5 && normalized.dropFirst().dropLast().allSatisfy(isASCIIAlphanumeric)
        }

        let parts = upper.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && (parts[1] == "L" || parts[1] == "R")) else { return false }
        let base = Array(parts[0].utf8)
        return base.count >= 3 && base.allSatisfy(isASCIIAlphanumeric)
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || isASCIIDigit(byte)
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}

struct SvxLinkTransmitterState: Equatable, Sendable {
    let id: String
    let name: String
    let isTransmitting: Bool
}

struct SvxLinkReceiverState: Equatable, Sendable {
    let name: String
    let id: String
    let isEnabled: Bool
    let isSquelchOpen: Bool?
    let isActive: Bool?
    let signalLevel: Int?
}

enum SvxLinkStateEvent: Equatable, Sendable {
    case transmitter(SvxLinkTransmitterState)
    case receivers([SvxLinkReceiverState])
    case unknown(context: String, name: String, data: String)
}

struct SvxLinkStateLine: Equatable, Sendable {
    let timestamp: Date
    let event: SvxLinkStateEvent
}

/// Parses one complete, newline-terminated `STATE_PTY` line.
enum SvxLinkStateParser {
    static let maxLineBytes = 4096

    static func parse(_ line: String) -> SvxLinkStateLine? {
        guard line.utf8.count <= maxLineBytes, line.hasSuffix("\n") else { return nil }
        var body = String(line.dropLast())
        if body.hasSuffix("\r") { body.removeLast() }
        guard !body.isEmpty,
              body.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else { return nil }

        let fields = body.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3,
              let timestamp = parseTimestamp(fields[0]) else { return nil }
        let eventName = fields[1].split(separator: ":", omittingEmptySubsequences: false)
        guard eventName.count == 2,
              isValidEventPart(eventName[0]),
              isValidEventPart(eventName[1]) else { return nil }
        let context = String(eventName[0])
        let name = String(eventName[1])
        let data = String(fields[2])

        if context == "Tx" && name == "state" {
            guard let payload = try? JSONDecoder().decode(TransmitterPayload.self, from: Data(data.utf8)),
                  isValidIdentifier(payload.id),
                  isValidIdentifier(payload.name) else { return nil }
            return SvxLinkStateLine(
                timestamp: timestamp,
                event: .transmitter(.init(id: payload.id, name: payload.name, isTransmitting: payload.transmit))
            )
        }
        if context == "Voter" && name == "sql_state" {
            guard let payloads = try? JSONDecoder().decode([ReceiverPayload].self, from: Data(data.utf8)),
                  payloads.count <= 32,
                  payloads.allSatisfy({ isValidIdentifier($0.id) && isValidIdentifier($0.name) }) else { return nil }
            return SvxLinkStateLine(
                timestamp: timestamp,
                event: .receivers(payloads.map {
                    .init(name: $0.name, id: $0.id, isEnabled: $0.enabled,
                          isSquelchOpen: $0.sqlOpen, isActive: $0.active, signalLevel: $0.siglev)
                })
            )
        }
        return SvxLinkStateLine(timestamp: timestamp, event: .unknown(context: context, name: name, data: data))
    }

    private static func parseTimestamp(_ field: Substring) -> Date? {
        let pieces = field.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty,
              (1...3).contains(pieces[1].count),
              pieces.allSatisfy({ $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
              let seconds = Double(field), seconds.isFinite, seconds >= 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isValidEventPart(_ value: Substring) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 64 && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 95
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 64 && bytes.allSatisfy { $0 >= 33 && $0 <= 126 }
    }

    private struct TransmitterPayload: Decodable {
        let id: String
        let name: String
        let transmit: Bool
    }

    private struct ReceiverPayload: Decodable {
        let name: String
        let id: String
        let enabled: Bool
        let sqlOpen: Bool?
        let active: Bool?
        let siglev: Int?

        enum CodingKeys: String, CodingKey {
            case name, id, enabled, active, siglev
            case sqlOpen = "sql_open"
        }
    }
}
