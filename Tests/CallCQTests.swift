// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class CallCQTests: XCTestCase {
    @MainActor
    private final class RecordingClient: CallCQClientProtocol, @unchecked Sendable {
        var cancelCount = 0
        func register(_ registration: CallCQRegistration, password: String) async throws {}
        func find(callsign: String, password: String) async throws -> CallCQPollResponse {
            .matched(callsign: "K1MATCH", internetAddress: "127.0.0.1")
        }
        func cancel(callsign: String, password: String) async { cancelCount += 1 }
    }

    func testDefaultPreferencesAcceptEnglishAnyCountryAndAllSupportedNodeTypes() {
        let preferences = CallCQPreferences.default

        XCTAssertEqual(preferences.languageCodes, ["en"])
        XCTAssertTrue(preferences.countryCodes.isEmpty)
        XCTAssertEqual(preferences.nodeTypes, Set([.user, .link, .repeater]))
        XCTAssertFalse(preferences.nodeTypes.contains(.conference))
        XCTAssertTrue(preferences.avoidRecentContacts)
    }

    @MainActor
    func testDemoCallTransitionsFromWaitingToMatchedStation() async throws {
        let expected = Station(callsign: "W1AW", ipAddress: "127.0.0.1", nodeNumber: 123)
        let backend = DemoCallCQBackend(stations: [expected], delay: .zero)
        let service = CallCQService(backend: backend)

        await service.start(preferences: .default)

        guard case .matched(let station) = service.state else {
            return XCTFail("Expected a matched station, got \(service.state)")
        }
        XCTAssertEqual(station.callsign, expected.callsign)
    }

    @MainActor
    func testCancelReturnsWaitingCallToIdle() async {
        let backend = DemoCallCQBackend(stations: [], delay: .seconds(30))
        let service = CallCQService(backend: backend)
        let start = Task { await service.start(preferences: .default) }

        await Task.yield()
        XCTAssertEqual(service.state, .waiting)
        await service.cancel()
        XCTAssertEqual(service.state, .idle)
        start.cancel()
    }

    @MainActor
    func testDemoStrictAllowListPreventsQueueing() async {
        var policy = CallAccessPolicy()
        policy.useAllowList = true
        policy.allowedCallsigns = ["W1AW"]
        let station = Station(callsign: "W1AW", ipAddress: "127.0.0.1")
        let service = CallCQService(
            backend: DemoCallCQBackend(stations: [station], delay: .zero, policy: policy)
        )

        await service.start(preferences: .default)

        guard case .failed(let message) = service.state else {
            return XCTFail("Expected strict allow-list failure")
        }
        XCTAssertTrue(message.contains("Only Allow Listed Callsigns"))
    }

    @MainActor
    func testDemoIgnoresDisabledOutgoingPolicy() async {
        var policy = CallAccessPolicy()
        policy.applyToOutgoing = false
        policy.useAllowList = true
        policy.allowedTypes = [.user]
        policy.blockedCallsigns = ["W1AW-R"]
        let station = Station(callsign: "W1AW-R", ipAddress: "127.0.0.1", type: .repeater)
        let service = CallCQService(
            backend: DemoCallCQBackend(stations: [station], delay: .zero, policy: policy)
        )

        await service.start(preferences: .default)

        guard case .matched(let match) = service.state else {
            return XCTFail("Expected disabled outgoing restrictions to permit CQ")
        }
        XCTAssertEqual(match.callsign, station.callsign)
    }

    @MainActor
    func testConsumedLiveMatchRemovesCQQueueEntry() async throws {
        let client = RecordingClient()
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [] })
        let registration = CallCQRegistration(
            callsign: "N0TST", nodeType: "U", internetAddress: nil,
            countryCode: "US", isReachable: true, acceptCountryCodes: [],
            acceptLanguageCodes: ["en"], declineCallsigns: [], acceptNodeTypes: ["U"]
        )
        let backend = LiveCallCQBackend(
            registration: registration, password: "test", directory: directory,
            policy: CallAccessPolicy(), client: client, pollDelay: .zero
        )

        let station = try await backend.waitForMatch(preferences: .default)

        XCTAssertEqual(station.callsign, "K1MATCH")
        XCTAssertEqual(client.cancelCount, 1)
    }

    func testDirectSocketPairTransfersOwnershipOnlyOnce() throws {
        let pair = try DirectCQSocketPair(audioPort: 0, controlPort: 0)
        let sockets = try XCTUnwrap(pair.takeSockets())

        XCTAssertNotEqual(sockets.audio.actualLocalPort, 0)
        XCTAssertNotEqual(sockets.control.actualLocalPort, 0)
        XCTAssertNil(pair.takeSockets())
        sockets.audio.close()
        sockets.control.close()
    }

    func testClosingDirectSocketPairReleasesReservedPorts() throws {
        let pair = try DirectCQSocketPair(audioPort: 0, controlPort: 0)
        let audioPort = try XCTUnwrap(pair.audioPort)

        pair.close()

        XCTAssertNil(pair.takeSockets())
        let rebound = try BoundUDPSocket(localPort: audioPort)
        rebound.close()
    }

    func testDirectSocketPairPreservesQueuedDatagramAcrossHandoff() async throws {
        let pair = try DirectCQSocketPair(audioPort: 0, controlPort: 0)
        let sender = try BoundUDPSocket(localPort: 0)
        let payload = Data("queued-before-match".utf8)
        let audioPort = try XCTUnwrap(pair.audioPort)
        defer { sender.close() }

        try await sender.send(payload, to: "127.0.0.1", port: audioPort)
        let sockets = try XCTUnwrap(pair.takeSockets())
        defer { sockets.audio.close(); sockets.control.close() }
        let datagram = try await sockets.audio.receive(maximumBytes: 128)

        XCTAssertEqual(datagram.data, payload)
    }

}
