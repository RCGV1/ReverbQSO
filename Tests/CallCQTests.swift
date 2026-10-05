// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class CallCQTests: XCTestCase {
    @MainActor
    private final class RecordingClient: CallCQClientProtocol, @unchecked Sendable {
        var cancelCount = 0
        var registerCount = 0
        var onRegister: (() -> Void)?
        var onFind: (() -> Void)?
        func register(_ registration: CallCQRegistration, password: String) async throws {
            registerCount += 1
            onRegister?()
        }
        func find(callsign: String, password: String) async throws -> CallCQPollResponse {
            onFind?()
            return .matched(callsign: "K1MATCH", internetAddress: "127.0.0.1")
        }
        func cancel(callsign: String, password: String) async { cancelCount += 1 }
    }

    @MainActor
    func testLiveCQAdvertisesAvailableBeforeRegisterAndRestoresAfterMatch() async throws {
        let client = RecordingClient()
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [] })
        directory.isLoggedIn = true
        client.onRegister = { XCTAssertTrue(directory.isAvailableForCalls) }
        client.onFind = { XCTAssertTrue(directory.isAvailableForCalls) }
        let backend = makeBackend(client: client, directory: directory)

        _ = try await backend.waitForMatch(preferences: .default)

        XCTAssertEqual(client.registerCount, 1)
        XCTAssertFalse(directory.isAvailableForCalls)
    }

    @MainActor
    func testLiveCQDoesNotRegisterIfDirectoryCannotBecomeAvailable() async {
        let client = RecordingClient()
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [] })
        let backend = makeBackend(client: client, directory: directory)
        do {
            _ = try await backend.waitForMatch(preferences: .default)
            XCTFail("CQ must not queue a station that cannot advertise availability")
        } catch {}
        XCTAssertEqual(client.registerCount, 0)
        XCTAssertFalse(directory.isAvailableForCalls)
    }

    @MainActor
    func testLiveCQPreservesAnAlreadyAvailableDirectory() async throws {
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [] })
        directory.isLoggedIn = true
        _ = await directory.setAvailableForCalls(true)
        _ = try await makeBackend(client: RecordingClient(), directory: directory).waitForMatch(preferences: .default)
        XCTAssertTrue(directory.isAvailableForCalls)
    }

    @MainActor
    func testCancelledBackendCannotRegisterIfItsFirstStartWasStillPending() async {
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [] })
        directory.isLoggedIn = true
        let client = RecordingClient()
        let backend = makeBackend(client: client, directory: directory)
        await backend.cancel()
        do {
            _ = try await backend.waitForMatch(preferences: .default)
            XCTFail("A replaced backend must not create a late CQ entry")
        } catch {}
        XCTAssertEqual(client.registerCount, 0)
        XCTAssertFalse(directory.isAvailableForCalls)
    }

    @MainActor
    private final class SuspendedRegistrationClient: CallCQClientProtocol, @unchecked Sendable {
        var registerStarted = false
        var cancelCount = 0
        var continuation: CheckedContinuation<Void, Never>?
        func register(_ registration: CallCQRegistration, password: String) async throws {
            registerStarted = true
            await withCheckedContinuation { continuation = $0 }
        }
        func find(callsign: String, password: String) async throws -> CallCQPollResponse {
            XCTFail("A cancelled registration must not poll")
            return .waiting
        }
        func cancel(callsign: String, password: String) async { cancelCount += 1 }
        func finishRegistration() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    func testCancelWaitsForInflightRegistrationAndSendsOnlyOneCleanupCancel() async {
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [] })
        directory.isLoggedIn = true
        let client = SuspendedRegistrationClient()
        let registration = CallCQRegistration(callsign: "N0TST", nodeType: "U", internetAddress: nil,
            countryCode: "US", isReachable: true, acceptCountryCodes: [], acceptLanguageCodes: ["en"],
            declineCallsigns: [], acceptNodeTypes: ["U"])
        let backend = LiveCallCQBackend(registration: registration, password: "test", directory: directory,
            policy: CallAccessPolicy(), client: client, pollDelay: .zero)
        let operation = Task { try await backend.waitForMatch(preferences: .default) }
        for _ in 0..<100 where !client.registerStarted { await Task.yield() }
        XCTAssertTrue(client.registerStarted)
        let cancellation = Task { await backend.cancel() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(client.cancelCount, 0, "Cleanup must follow the register already in flight")
        client.finishRegistration()
        await cancellation.value
        if case .success = await operation.result { XCTFail("Cancelled CQ must not publish a match") }
        XCTAssertEqual(client.cancelCount, 1)
        XCTAssertFalse(directory.isAvailableForCalls)
    }

    @MainActor
    func testCQCleanupDoesNotUndoANewerIncomingCallAvailabilityRequest() async {
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [] })
        directory.isLoggedIn = true
        let client = SuspendedRegistrationClient()
        let registration = CallCQRegistration(callsign: "N0TST", nodeType: "U", internetAddress: nil,
            countryCode: "US", isReachable: true, acceptCountryCodes: [], acceptLanguageCodes: ["en"],
            declineCallsigns: [], acceptNodeTypes: ["U"])
        let backend = LiveCallCQBackend(registration: registration, password: "test", directory: directory,
            policy: CallAccessPolicy(), client: client, pollDelay: .zero)
        let operation = Task { try await backend.waitForMatch(preferences: .default) }
        for _ in 0..<100 where !client.registerStarted { await Task.yield() }
        _ = await directory.setAvailableForCalls(true) // Another listener now owns ONLINE.
        let cancellation = Task { await backend.cancel() }
        for _ in 0..<20 { await Task.yield() }
        client.finishRegistration()
        await cancellation.value
        _ = await operation.result
        XCTAssertTrue(directory.isAvailableForCalls, "CQ must not make the newer inbound listener busy")
    }

    @MainActor
    private func makeBackend(client: RecordingClient, directory: EchoLinkDirectoryService) -> LiveCallCQBackend {
        LiveCallCQBackend(registration: CallCQRegistration(
            callsign: "N0TST", nodeType: "U", internetAddress: nil, countryCode: "US", isReachable: true,
            acceptCountryCodes: [], acceptLanguageCodes: ["en"], declineCallsigns: [], acceptNodeTypes: ["U"]),
            password: "test", directory: directory, policy: CallAccessPolicy(), client: client, pollDelay: .zero)
    }

    @MainActor
    private final class DelayedCancelBackend: CallCQBackend {
        var starts = 0
        var cancelStarted = false
        var cancelContinuation: CheckedContinuation<Void, Never>?
        func waitForMatch(preferences: CallCQPreferences) async throws -> Station {
            starts += 1
            if starts == 1 { try await Task.sleep(for: .seconds(30)) }
            return Station(callsign: "K1MATCH", ipAddress: "127.0.0.1")
        }
        func cancel() async {
            cancelStarted = true
            await withCheckedContinuation { cancelContinuation = $0 }
        }
        func finishCancel() { cancelContinuation?.resume(); cancelContinuation = nil }
    }

    @MainActor
    func testRestartWaitsForOldCallsignCancelToFinish() async {
        let backend = DelayedCancelBackend()
        let service = CallCQService(backend: backend)
        let first = Task { await service.start(preferences: .default) }
        for _ in 0..<100 where backend.starts == 0 { await Task.yield() }
        let cancel = Task { await service.cancel() }
        for _ in 0..<100 where !backend.cancelStarted { await Task.yield() }
        let next = Task { await service.start(preferences: .default) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(backend.starts, 1, "An old cancel could erase a replacement CQ registration")
        backend.finishCancel()
        await cancel.value
        await first.value
        await next.value
        XCTAssertEqual(backend.starts, 2)
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
        directory.isLoggedIn = true
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
