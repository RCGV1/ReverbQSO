// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class InboundHostSessionMachineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func peer(
        _ callsign: String,
        source: String,
        type: Station.StationType = .user,
        verifiedAt: Date? = nil
    ) throws -> VerifiedInboundHostPeer {
        let station = Station(callsign: callsign, ipAddress: source, type: type)
        return try VerifiedInboundHostPeer.verify(
            claim: .init(advertisedName: callsign, sourceIPv4Address: source, receivedAt: verifiedAt ?? now),
            stations: [station], directoryUpdatedAt: verifiedAt ?? now,
            now: verifiedAt ?? now, maxDirectoryAge: 60
        ).get()
    }

    func testVerifiedPeerCanActivateAndReleaseCapacity() throws {
        var host = InboundHostSessionMachine(policy: .init(maximumPeers: 1), isEnabled: true)
        let first = try host.admit(peer("N0CALL", source: "198.51.100.1"), controlPort: 5199, now: now).get()
        XCTAssertEqual(first.state, .pending)
        XCTAssertEqual(host.availability, .busy)
        XCTAssertTrue(host.activate(id: first.id, now: now.addingTimeInterval(1)))
        XCTAssertTrue(host.recordActivity(id: first.id, now: now.addingTimeInterval(2)))
        XCTAssertEqual(host.sessions.first?.state, .active)
        XCTAssertNotNil(host.remove(id: first.id))
        XCTAssertNil(host.remove(id: first.id))
        XCTAssertEqual(host.availability, .on)
    }

    func testFullHostRejectsSecondPeerAndDisableClearsSessions() throws {
        var host = InboundHostSessionMachine(policy: .init(maximumPeers: 1), isEnabled: true)
        _ = try host.admit(peer("N0CALL", source: "198.51.100.1"), controlPort: 5199, now: now).get()
        let second = try peer("K1ABC", source: "198.51.100.2")
        XCTAssertEqual(host.admit(second, controlPort: 5199, now: now), .failure(.atCapacity))
        XCTAssertEqual(host.setEnabled(false).count, 1)
        XCTAssertEqual(host.availability, .offline)
        XCTAssertEqual(host.admit(second, controlPort: 5199, now: now), .failure(.disabled))
    }

    func testDuplicateIdentityAndEndpointAreRejectedBeforeCapacity() throws {
        var host = InboundHostSessionMachine(policy: .init(maximumPeers: 3), isEnabled: true)
        _ = try host.admit(peer("N0CALL", source: "198.51.100.1"), controlPort: 5199, now: now).get()
        XCTAssertEqual(
            host.admit(try peer("N0CALL", source: "198.51.100.2"), controlPort: 5199, now: now),
            .failure(.duplicateCallsign)
        )
        XCTAssertEqual(
            host.admit(try peer("K1ABC", source: "198.51.100.1"), controlPort: 5199, now: now),
            .failure(.endpointInUse)
        )
        XCTAssertEqual(host.sessions.count, 1)
    }

    func testExpiredPendingReservationAllowsNewAttemptFromSameEndpoint() throws {
        var host = InboundHostSessionMachine(policy: .init(maximumPeers: 1), isEnabled: true)
        let first = try host.admit(peer("N0CALL", source: "198.51.100.1"), controlPort: 5199, now: now).get()
        XCTAssertTrue(host.expirePending(now: now.addingTimeInterval(9), timeout: 10).isEmpty)
        XCTAssertEqual(host.expirePending(now: now.addingTimeInterval(10), timeout: 10), [first])
        XCTAssertFalse(host.activate(id: first.id, now: now.addingTimeInterval(11)))
        let second = try host.admit(
            peer("N0CALL", source: "198.51.100.1", verifiedAt: now.addingTimeInterval(11)),
            controlPort: 5199, now: now.addingTimeInterval(11)
        ).get()
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(host.availability, .busy)
    }

    func testOldVerificationAndInvalidPolicyFailClosed() throws {
        let oldPeer = try peer("N0CALL", source: "198.51.100.1")
        var host = InboundHostSessionMachine(policy: .init(maximumPeers: 1), isEnabled: true)
        XCTAssertEqual(host.admit(oldPeer, controlPort: 5199, now: now.addingTimeInterval(6)), .failure(.staleVerification))
        var invalid = InboundHostSessionMachine(policy: .init(maximumPeers: 100), isEnabled: true)
        XCTAssertEqual(invalid.availability, .offline)
        XCTAssertEqual(invalid.admit(oldPeer, controlPort: 5199, now: now), .failure(.invalidPolicy))
        XCTAssertEqual(host.admit(oldPeer, controlPort: 0, now: now), .failure(.invalidControlPort))
        XCTAssertEqual(host.admit(oldPeer, controlPort: 5199, audioPort: 0, now: now), .failure(.invalidAudioPort))
    }

    func testSharedIPNeedsDistinctAudioPorts() throws {
        var host = InboundHostSessionMachine(policy: .init(maximumPeers: 3), isEnabled: true)
        _ = try host.admit(peer("N0CALL", source: "198.51.100.1"), controlPort: 5199, now: now).get()
        XCTAssertEqual(
            host.admit(try peer("K1ABC", source: "198.51.100.1"), controlPort: 5201, now: now),
            .failure(.audioEndpointInUse)
        )
        XCTAssertNoThrow(try host.admit(
            peer("K1ABC", source: "198.51.100.1"), controlPort: 5201, audioPort: 5200, now: now
        ).get())
    }

    func testCallsignPolicyAndConferenceGuard() throws {
        var host = InboundHostSessionMachine(
            policy: .init(maximumPeers: 3, deniedCallsigns: ["n0call"]), isEnabled: true
        )
        XCTAssertEqual(
            host.admit(try peer("N0CALL", source: "198.51.100.1"), controlPort: 5199, now: now),
            .failure(.deniedCallsign)
        )
        host = InboundHostSessionMachine(policy: .init(maximumPeers: 3), isEnabled: true)
        _ = try host.admit(peer("N0CALL", source: "198.51.100.1"), controlPort: 5199, now: now).get()
        XCTAssertEqual(
            host.admit(try peer("*TEST*", source: "198.51.100.2", type: .conference), controlPort: 5199, now: now),
            .failure(.multiConferenceDisabled)
        )
    }
}
