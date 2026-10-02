// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The identity advertised by an incoming RTCP SDES packet is untrusted.
struct InboundCallClaim {
    let advertisedName: String
    let sourceIPv4Address: String
    let receivedAt: Date
}

enum InboundStationRejection: Error, Equatable {
    case malformedClaim
    case malformedSourceAddress
    case staleClaim
    case staleDirectory
    case unknownCallsign
    case ambiguousDirectory
    case sourceMismatch
}

/// Checks an incoming claim against a recent directory snapshot without network I/O.
/// This IP-address compatibility check is not cryptographic authentication.
enum InboundStationVerifier {
    static func verify(
        claim: InboundCallClaim,
        stations: [Station],
        directoryUpdatedAt: Date?,
        now: Date,
        maxAge: TimeInterval
    ) -> Result<Station, InboundStationRejection> {
        guard let callsign = parseCallsign(from: claim.advertisedName) else {
            return .failure(.malformedClaim)
        }
        guard isValidIPv4(claim.sourceIPv4Address) else {
            return .failure(.malformedSourceAddress)
        }
        guard maxAge > 0,
              (0...maxAge).contains(now.timeIntervalSince(claim.receivedAt)) else {
            return .failure(.staleClaim)
        }
        guard let directoryUpdatedAt,
              (0...maxAge).contains(now.timeIntervalSince(directoryUpdatedAt)) else {
            return .failure(.staleDirectory)
        }

        let matches = stations.filter {
            $0.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == callsign
        }
        guard !matches.isEmpty else { return .failure(.unknownCallsign) }
        guard matches.count == 1 else { return .failure(.ambiguousDirectory) }
        let station = matches[0]
        guard isValidIPv4(station.ipAddress),
              station.ipAddress == claim.sourceIPv4Address else {
            return .failure(.sourceMismatch)
        }
        return .success(station)
    }

    private static func parseCallsign(from name: String) -> String? {
        guard let token = name.split(whereSeparator: \.isWhitespace).first else { return nil }
        let callsign = token.uppercased()

        if callsign.first == "*" && callsign.last == "*" {
            let middle = callsign.dropFirst().dropLast()
            guard middle.count >= 3,
                  middle.allSatisfy(isASCIIAlphanumeric) else { return nil }
            return callsign
        }

        let parts = callsign.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && (parts[1] == "L" || parts[1] == "R")) else {
            return nil
        }
        guard parts[0].count >= 3,
              parts[0].allSatisfy(isASCIIAlphanumeric) else { return nil }
        return callsign
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    private static func isValidIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty,
                  octet.count <= 3,
                  (octet.count == 1 || octet.first != "0"),
                  octet.allSatisfy({ ("0"..."9").contains($0) }),
                  let value = UInt8(octet) else { return false }
            return String(value) == octet
        }
    }
}
