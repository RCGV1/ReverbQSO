// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class InboundStationVerifierTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func station(_ callsign: String, _ ip: String) -> Station {
        Station(callsign: callsign, ipAddress: ip)
    }

    private func verify(
        name: String,
        source: String = "198.51.100.10",
        stations: [Station],
        updatedAt: Date? = Date(timeIntervalSince1970: 990),
        receivedAt: Date? = nil
    ) -> Result<Station, InboundStationRejection> {
        InboundStationVerifier.verify(
            claim: InboundCallClaim(
                advertisedName: name,
                sourceIPv4Address: source,
                receivedAt: receivedAt ?? now
            ),
            stations: stations,
            directoryUpdatedAt: updatedAt,
            now: now,
            maxAge: 60
        )
    }

    func testValidMatchNormalizesOnlyFirstCallsignToken() {
        let expected = station("N0CALL-L", "198.51.100.10")
        let result = verify(name: "  n0call-l   Operator Name  ", stations: [expected])
        XCTAssertEqual(try? result.get(), expected)
    }

    func testMalformedAndEmptyNamesAreRejected() {
        let stations = [station("N0CALL-L", "198.51.100.10")]
        for name in ["", "   ", "N0CALL/L", "N0CALL--L", "N0CALL-L;", "X", "*BAD", "N0CALL-L\u{0000}X"] {
            XCTAssertEqual(verify(name: name, stations: stations), .failure(.malformedClaim), name)
        }
    }

    func testClaimedCallsignCannotBeFoundAsSubstring() {
        let stations = [station("N0CALL-L", "198.51.100.10")]
        XCTAssertEqual(verify(name: "OTHER N0CALL-L", stations: stations), .failure(.unknownCallsign))
    }

    func testClaimedCallsignAtDifferentAddressIsRejected() {
        let stations = [station("N0CALL-L", "198.51.100.11")]
        XCTAssertEqual(verify(name: "N0CALL-L", stations: stations), .failure(.sourceMismatch))
    }

    func testSameAddressDoesNotAuthorizeDifferentCallsign() {
        let stations = [station("N0CALL-L", "198.51.100.10")]
        XCTAssertEqual(verify(name: "W6OTHER-R", stations: stations), .failure(.unknownCallsign))
    }

    func testStaleOrMissingDirectorySnapshotFailsClosed() {
        let stations = [station("N0CALL-L", "198.51.100.10")]
        XCTAssertEqual(verify(name: "N0CALL-L", stations: stations, updatedAt: now.addingTimeInterval(-61)), .failure(.staleDirectory))
        XCTAssertEqual(verify(name: "N0CALL-L", stations: stations, updatedAt: nil), .failure(.staleDirectory))
        XCTAssertEqual(verify(name: "N0CALL-L", stations: stations, updatedAt: now.addingTimeInterval(1)), .failure(.staleDirectory))
    }

    func testDuplicateDirectoryCallsignFailsClosedEvenIfOneAddressMatches() {
        let stations = [
            station("N0CALL-L", "198.51.100.10"),
            station("n0call-l", "198.51.100.11")
        ]
        XCTAssertEqual(verify(name: "N0CALL-L", stations: stations), .failure(.ambiguousDirectory))
    }

    func testMalformedSourceAddressIsRejected() {
        let stations = [station("N0CALL-L", "198.51.100.10")]
        XCTAssertEqual(verify(name: "N0CALL-L", source: "198.51.100.999", stations: stations), .failure(.malformedSourceAddress))
    }

    func testAgedClaimIsRejectedEvenWhenDirectoryIsFresh() {
        let stations = [station("N0CALL-L", "198.51.100.10")]
        XCTAssertEqual(verify(name: "N0CALL-L", stations: stations, receivedAt: now.addingTimeInterval(-61)), .failure(.staleClaim))
    }
}
