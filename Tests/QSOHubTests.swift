// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import XCTest
@testable import ReverbQSO

@MainActor
final class QSOHubTests: XCTestCase {
    func testDisconnectAllPreservesSecondaryCallsCreatedWhileSuspended() async throws {
        let primary = EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false))
        let teardownGate = QSOHubOperationGate("captured primary teardown suspended")
        var disconnectedSessionIDs: [UUID] = []
        let hub = makeTeardownHub(primary: primary, disconnectOperation: { service in
            let sessionID = service.session?.id
            if let sessionID { disconnectedSessionIDs.append(sessionID) }
            await teardownGate.wait()
            if service.session?.id == sessionID { service.session = nil }
        })
        defer {
            teardownGate.release()
            primary.session = nil
        }
        _ = await hub.connect(to: Station(callsign: "OLD-A", ipAddress: "127.0.0.1"), as: "N0OLD")
        let oldSessionID = try XCTUnwrap(primary.session?.id)

        let teardown = Task { await hub.disconnectAll() }
        await fulfillment(of: [teardownGate.entered], timeout: 2)
        let background = await hub.connect(to: Station(callsign: "NEW-B", ipAddress: "127.0.0.2"), as: "N0NEW-B")
        let selected = await hub.connect(to: Station(callsign: "NEW-C", ipAddress: "127.0.0.3"), as: "N0NEW-C")
        defer {
            background.session = nil
            selected.session = nil
        }
        let replacementIDs = hub.entries.filter { $0.service !== primary }.map(\.id)
        let selectedID = try XCTUnwrap(hub.entries.first { $0.service === selected }?.id)
        let backgroundSessionID = background.session?.id
        let selectedSessionID = selected.session?.id
        XCTAssertFalse(background === primary)
        XCTAssertFalse(selected === primary)
        XCTAssertEqual(replacementIDs.count, 2)

        teardownGate.release()
        await teardown.value

        XCTAssertEqual(disconnectedSessionIDs, [oldSessionID])
        XCTAssertNil(primary.session)
        XCTAssertNil(primary.pttPermission)
        XCTAssertEqual(hub.entries.map(\.id), replacementIDs)
        XCTAssertEqual(hub.activeID, selectedID)
        XCTAssertTrue(hub.activeService === selected)
        XCTAssertEqual(background.session?.id, backgroundSessionID)
        XCTAssertEqual(selected.session?.id, selectedSessionID)
        XCTAssertEqual(background.session?.state, .connected)
        XCTAssertEqual(selected.session?.state, .connected)
        XCTAssertEqual(background.pttPermission?(), false)
        XCTAssertEqual(selected.pttPermission?(), true)
        XCTAssertFalse(background.hasAudioFocus)
        XCTAssertTrue(selected.hasAudioFocus)
        await assertSessionObservationRemovesEntry(for: background, in: hub)
        XCTAssertEqual(hub.activeID, selectedID)
    }

    func testDisconnectAllPreservesSecondaryWhoseConnectIsStillSuspended() async throws {
        let primary = EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false))
        let teardownGate = QSOHubOperationGate("old teardown suspended")
        let connectionGate = QSOHubOperationGate("new secondary connection suspended")
        let hub = makeTeardownHub(primary: primary, connectOperation: { service, station in
            if station.callsign == "NEW-PENDING" { await connectionGate.wait() }
            service.session = QSOSession(station: station, state: .connected)
        }, disconnectOperation: { service in
            let sessionID = service.session?.id
            await teardownGate.wait()
            if service.session?.id == sessionID { service.session = nil }
        })
        defer {
            connectionGate.release()
            teardownGate.release()
            primary.session = nil
        }
        _ = await hub.connect(to: Station(callsign: "OLD-A", ipAddress: "127.0.0.1"), as: "N0OLD")
        let teardown = Task { await hub.disconnectAll() }
        await fulfillment(of: [teardownGate.entered], timeout: 2)
        let connection = Task {
            await hub.connect(to: Station(callsign: "NEW-PENDING", ipAddress: "127.0.0.2"), as: "N0NEW")
        }
        await fulfillment(of: [connectionGate.entered], timeout: 2)
        let pendingEntry = try XCTUnwrap(hub.entries.first { $0.callsign == "N0NEW" })
        defer { pendingEntry.service.session = nil }
        XCTAssertFalse(pendingEntry.service === primary)
        XCTAssertNil(pendingEntry.service.session)

        teardownGate.release()
        await teardown.value

        XCTAssertEqual(hub.entries.map(\.id), [pendingEntry.id])
        XCTAssertEqual(hub.activeID, pendingEntry.id)
        XCTAssertTrue(hub.activeService === pendingEntry.service)
        XCTAssertEqual(pendingEntry.service.pttPermission?(), true)
        XCTAssertTrue(pendingEntry.service.hasAudioFocus)
        connectionGate.release()
        let connected = await connection.value

        XCTAssertTrue(connected === pendingEntry.service)
        XCTAssertEqual(connected.session?.state, .connected)
        XCTAssertEqual(hub.entries.map(\.id), [pendingEntry.id])
        XCTAssertEqual(hub.activeID, pendingEntry.id)
        XCTAssertEqual(connected.pttPermission?(), true)
        await assertSessionObservationRemovesEntry(for: connected, in: hub)
    }

    func testDisconnectAllPreservesReusedPrimaryPermissionAndAudioFocus() async throws {
        let primary = EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false))
        let teardownGate = QSOHubOperationGate("old primary disconnect completed before hub cleanup")
        var disconnectCount = 0
        let hub = makeTeardownHub(primary: primary, disconnectOperation: { service in
            disconnectCount += 1
            service.session = nil
            if disconnectCount == 1 { await teardownGate.wait() }
        })
        defer {
            teardownGate.release()
            primary.session = nil
        }
        _ = await hub.connect(to: Station(callsign: "OLD-A", ipAddress: "127.0.0.1"), as: "N0OLD")
        let oldEntryID = try XCTUnwrap(hub.activeID)
        let teardown = Task { await hub.disconnectAll() }
        await fulfillment(of: [teardownGate.entered], timeout: 2)
        await hub.disconnect(callsign: "N0OLD")
        XCTAssertNil(hub.entry(for: oldEntryID))

        let replacement = await hub.connect(to: Station(callsign: "NEW-B", ipAddress: "127.0.0.2"), as: "N0NEW-B")
        let selected = await hub.connect(to: Station(callsign: "NEW-C", ipAddress: "127.0.0.3"), as: "N0NEW-C")
        defer { selected.session = nil }
        let replacementIDs = hub.entries.map(\.id)
        let selectedID = try XCTUnwrap(hub.activeID)
        let replacementSessionID = replacement.session?.id
        XCTAssertTrue(replacement === primary)
        XCTAssertEqual(replacement.pttPermission?(), false)
        XCTAssertFalse(replacement.hasAudioFocus)

        teardownGate.release()
        await teardown.value

        XCTAssertEqual(hub.entries.map(\.id), replacementIDs)
        XCTAssertEqual(hub.activeID, selectedID)
        XCTAssertTrue(hub.activeService === selected)
        XCTAssertEqual(replacement.session?.id, replacementSessionID)
        XCTAssertEqual(replacement.session?.state, .connected)
        XCTAssertEqual(selected.session?.state, .connected)
        XCTAssertNotNil(replacement.pttPermission)
        XCTAssertEqual(replacement.pttPermission?(), false)
        XCTAssertEqual(selected.pttPermission?(), true)
        XCTAssertFalse(replacement.hasAudioFocus)
        XCTAssertTrue(selected.hasAudioFocus)
        await assertSessionObservationRemovesEntry(for: replacement, in: hub)
        XCTAssertEqual(hub.activeID, selectedID)
    }

    func testDisconnectAllPreservesPrimaryAdoptedDuringSecondaryTeardown() async throws {
        let primary = EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false))
        let teardownGate = QSOHubOperationGate("captured secondary teardown suspended")
        let hub = makeTeardownHub(primary: primary, disconnectOperation: { service in
            let sessionID = service.session?.id
            if service !== primary { await teardownGate.wait() }
            if service.session?.id == sessionID { service.session = nil }
        })
        defer {
            teardownGate.release()
            primary.session = nil
        }
        _ = await hub.connect(to: Station(callsign: "OLD-A", ipAddress: "127.0.0.1"), as: "N0OLD-A")
        let oldSecondary = await hub.connect(to: Station(callsign: "OLD-B", ipAddress: "127.0.0.2"), as: "N0OLD-B")
        defer { oldSecondary.session = nil }
        await hub.disconnect(callsign: "N0OLD-A")
        XCTAssertEqual(hub.entries.count, 1)

        let teardown = Task { await hub.disconnectAll() }
        await fulfillment(of: [teardownGate.entered], timeout: 2)
        primary.authenticatedCallsign = "N0ADOPTED"
        primary.session = QSOSession(station: Station(callsign: "NEW-C", ipAddress: "127.0.0.3"), state: .connected)
        hub.adoptExistingPrimary(as: "N0ADOPTED")
        let adoptedID = try XCTUnwrap(hub.entries.first { $0.service === primary }?.id)
        let adoptedSessionID = primary.session?.id
        let selected = await hub.connect(to: Station(callsign: "NEW-D", ipAddress: "127.0.0.4"), as: "N0NEW")
        defer { selected.session = nil }
        let selectedID = try XCTUnwrap(hub.activeID)
        XCTAssertEqual(primary.pttPermission?(), false)
        XCTAssertFalse(primary.hasAudioFocus)

        teardownGate.release()
        await teardown.value

        XCTAssertNil(oldSecondary.session)
        XCTAssertNil(oldSecondary.pttPermission)
        XCTAssertEqual(hub.entries.map(\.id), [adoptedID, selectedID])
        XCTAssertEqual(hub.activeID, selectedID)
        XCTAssertTrue(hub.activeService === selected)
        XCTAssertEqual(primary.session?.id, adoptedSessionID)
        XCTAssertEqual(primary.session?.state, .connected)
        XCTAssertEqual(primary.pttPermission?(), false)
        XCTAssertEqual(selected.pttPermission?(), true)
        XCTAssertFalse(primary.hasAudioFocus)
        XCTAssertTrue(selected.hasAudioFocus)
        await assertSessionObservationRemovesEntry(for: primary, in: hub)
        XCTAssertEqual(hub.activeID, selectedID)
    }

    func testDisconnectAllSkipsPrimaryReplacedBeforeItsCapturedEntryIsVisited() async throws {
        let primary = EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false))
        let teardownGate = QSOHubOperationGate("earlier secondary teardown suspended")
        var disconnectedSessionIDs: [UUID] = []
        let hub = makeTeardownHub(primary: primary, disconnectOperation: { service in
            let sessionID = service.session?.id
            if let sessionID { disconnectedSessionIDs.append(sessionID) }
            if service !== primary { await teardownGate.wait() }
            if service.session?.id == sessionID { service.session = nil }
        })
        defer {
            teardownGate.release()
            primary.session = nil
        }
        _ = await hub.connect(to: Station(callsign: "SETUP-A", ipAddress: "127.0.0.1"), as: "N0SETUP")
        let oldSecondary = await hub.connect(to: Station(callsign: "OLD-B", ipAddress: "127.0.0.2"), as: "N0OLD-B")
        defer { oldSecondary.session = nil }
        await hub.disconnect(callsign: "N0SETUP")
        let secondaryID = try XCTUnwrap(hub.entries.first { $0.service === oldSecondary }?.id)
        let secondarySessionID = try XCTUnwrap(oldSecondary.session?.id)
        primary.authenticatedCallsign = "N0CAPTURED"
        primary.session = QSOSession(station: Station(callsign: "OLD-C", ipAddress: "127.0.0.3"), state: .connected)
        hub.adoptExistingPrimary(as: "N0CAPTURED")
        let capturedPrimaryID = try XCTUnwrap(hub.entries.first { $0.service === primary }?.id)
        let capturedSessionID = try XCTUnwrap(primary.session?.id)
        XCTAssertEqual(hub.entries.map(\.id), [secondaryID, capturedPrimaryID])
        disconnectedSessionIDs = []

        let teardown = Task { await hub.disconnectAll() }
        await fulfillment(of: [teardownGate.entered], timeout: 2)
        await hub.disconnect(callsign: "N0CAPTURED")
        XCTAssertNil(hub.entry(for: capturedPrimaryID))
        // Bulk teardown may already have detached the old entry; finish its synthetic session too.
        primary.session = nil
        let disconnectedBeforeReplacement = disconnectedSessionIDs
        let replacement = await hub.connect(to: Station(callsign: "NEW-D", ipAddress: "127.0.0.4"), as: "N0NEW-D")
        let selected = await hub.connect(to: Station(callsign: "NEW-E", ipAddress: "127.0.0.5"), as: "N0NEW-E")
        defer { selected.session = nil }
        let replacementID = try XCTUnwrap(hub.entries.first { $0.service === replacement }?.id)
        let replacementSessionID = try XCTUnwrap(replacement.session?.id)
        let selectedID = try XCTUnwrap(hub.activeID)
        XCTAssertTrue(replacement === primary)
        XCTAssertEqual(replacement.pttPermission?(), false)
        XCTAssertFalse(replacement.hasAudioFocus)

        teardownGate.release()
        await teardown.value

        XCTAssertEqual(disconnectedSessionIDs.first, secondarySessionID)
        XCTAssertTrue(disconnectedSessionIDs.allSatisfy { $0 == secondarySessionID || $0 == capturedSessionID })
        XCTAssertEqual(disconnectedSessionIDs, disconnectedBeforeReplacement)
        XCTAssertFalse(disconnectedSessionIDs.contains(replacementSessionID), "A stale captured service must not disconnect its replacement")
        XCTAssertNil(oldSecondary.session)
        XCTAssertEqual(hub.entries.map(\.id), [replacementID, selectedID])
        XCTAssertEqual(hub.activeID, selectedID)
        XCTAssertTrue(hub.activeService === selected)
        XCTAssertEqual(replacement.session?.id, replacementSessionID)
        XCTAssertEqual(replacement.session?.state, .connected)
        XCTAssertEqual(selected.session?.state, .connected)
        XCTAssertEqual(replacement.pttPermission?(), false)
        XCTAssertFalse(replacement.hasAudioFocus)
        XCTAssertEqual(selected.pttPermission?(), true)
        XCTAssertTrue(selected.hasAudioFocus)
        await assertSessionObservationRemovesEntry(for: replacement, in: hub)
    }

    func testOverlappingDisconnectAllCompletionsPreserveReplacementOwnership() async throws {
        let primary = EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false))
        let firstGate = QSOHubOperationGate("first bulk teardown suspended")
        let secondGate = QSOHubOperationGate("second bulk teardown suspended or completed")
        var disconnectCount = 0
        var secondSuspended = false
        let hub = makeTeardownHub(primary: primary, disconnectOperation: { service in
            let sessionID = service.session?.id
            disconnectCount += 1
            switch disconnectCount {
            case 1:
                await firstGate.wait()
            case 2:
                secondSuspended = true
                await secondGate.wait()
            default:
                break
            }
            if service.session?.id == sessionID { service.session = nil }
        })
        defer {
            firstGate.release()
            secondGate.release()
            primary.session = nil
        }
        _ = await hub.connect(to: Station(callsign: "OLD-A", ipAddress: "127.0.0.1"), as: "N0OLD")
        let firstTeardown = Task { await hub.disconnectAll() }
        await fulfillment(of: [firstGate.entered], timeout: 2)
        let secondTeardown = Task {
            await hub.disconnectAll()
            // A teardown may detach its captured entries before it suspends.
            if !secondSuspended { secondGate.entered.fulfill() }
        }
        await fulfillment(of: [secondGate.entered], timeout: 2)
        await hub.disconnect(callsign: "N0OLD")
        // The entry may already be detached by either suspended teardown.
        primary.session = nil
        let replacement = await hub.connect(to: Station(callsign: "NEW-B", ipAddress: "127.0.0.2"), as: "N0NEW-B")
        let selected = await hub.connect(to: Station(callsign: "NEW-C", ipAddress: "127.0.0.3"), as: "N0NEW-C")
        defer { selected.session = nil }
        let replacementIDs = hub.entries.map(\.id)
        let selectedID = try XCTUnwrap(hub.activeID)
        let replacementSessionID = replacement.session?.id
        XCTAssertTrue(replacement === primary)

        secondGate.release()
        await secondTeardown.value

        XCTAssertEqual(hub.entries.map(\.id), replacementIDs)
        XCTAssertEqual(hub.activeID, selectedID)
        XCTAssertEqual(replacement.session?.id, replacementSessionID)
        XCTAssertEqual(replacement.pttPermission?(), false)
        XCTAssertFalse(replacement.hasAudioFocus)
        XCTAssertEqual(selected.pttPermission?(), true)
        XCTAssertTrue(selected.hasAudioFocus)
        firstGate.release()
        await firstTeardown.value

        XCTAssertEqual(hub.entries.map(\.id), replacementIDs)
        XCTAssertEqual(hub.activeID, selectedID)
        XCTAssertTrue(hub.activeService === selected)
        XCTAssertEqual(replacement.session?.id, replacementSessionID)
        XCTAssertEqual(replacement.session?.state, .connected)
        XCTAssertEqual(selected.session?.state, .connected)
        XCTAssertEqual(replacement.pttPermission?(), false)
        XCTAssertFalse(replacement.hasAudioFocus)
        XCTAssertEqual(selected.pttPermission?(), true)
        XCTAssertTrue(selected.hasAudioFocus)

        await hub.disconnectAll()
        await hub.disconnectAll()
        XCTAssertTrue(hub.entries.isEmpty)
        XCTAssertNil(hub.activeID)
        XCTAssertNil(replacement.session)
        XCTAssertNil(selected.session)
        XCTAssertNil(replacement.pttPermission)
        XCTAssertNil(selected.pttPermission)
    }

    private func makeTeardownHub(
        primary: EchoLinkConnectionService,
        connectOperation: @escaping @MainActor (EchoLinkConnectionService, Station) async -> Void = { service, station in
            service.session = QSOSession(station: station, state: .connected)
        },
        disconnectOperation: @escaping @MainActor (EchoLinkConnectionService) async -> Void
    ) -> QSOHub {
        QSOHub(primary: primary,
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            disconnectOperation: disconnectOperation) { service, station in
                await connectOperation(service, station)
            }
    }

    private func assertSessionObservationRemovesEntry(
        for service: EchoLinkConnectionService,
        in hub: QSOHub,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard let entry = hub.entries.first(where: { $0.service === service }) else {
            XCTFail("Replacement entry must survive before checking its subscription", file: file, line: line)
            return
        }
        let removed = expectation(description: "replacement session observation removed its ended entry")
        let subscription = hub.$entries.first(where: { entries in
            !entries.contains { $0.id == entry.id }
        }).sink { _ in removed.fulfill() }
        defer { subscription.cancel() }
        service.session = nil
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertNil(hub.entry(for: entry.id), file: file, line: line)
        XCTAssertNil(service.pttPermission, file: file, line: line)
    }

    func testSecondaryCallStaysManagedWhileInitialConnectionCreatesItsSession() async {
        let started = expectation(description: "secondary connection started")
        var finishConnection: CheckedContinuation<Void, Never>?
        let hub = QSOHub(primary: EchoLinkConnectionService(),
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            connectOperation: { service, station in
                if station.callsign == "TEST-B" {
                    service.session = nil // Startup publishes before the new session exists.
                    await withCheckedContinuation { continuation in
                        finishConnection = continuation
                        started.fulfill()
                    }
                }
                service.installSimulatorDemoSession(station: station)
            })
        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let connection = Task {
            await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")
        }
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<10 { await Task.yield() }
        let entriesDuringStartup = hub.entries.count
        finishConnection?.resume()
        let service = await connection.value
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(entriesDuringStartup, 2)
        XCTAssertEqual(hub.entries.count, 2)
        XCTAssertTrue(hub.entries.contains { $0.service === service })
        XCTAssertEqual(service.session?.state, .connected)
        await hub.disconnectAll()
    }

    func testFreshRejectedAttemptCannotOfferPreviousStationsReconnect() async {
        let service = EchoLinkConnectionService()
        service.registerReconnectCandidate(Station(callsign: "OLD-R", ipAddress: "192.0.2.1"))
        let unavailable = Station(callsign: "NEW-R", description: "Receive only [r]", ipAddress: "192.0.2.2")
        await service.connect(to: unavailable)
        XCTAssertNil(service.reconnectCandidate)
        XCTAssertNotNil(service.error)
    }

    func testFailedInitialConnectionRemovesPresentationAndPreservesError() async {
        let station = Station(callsign: "TEST-RETRY", ipAddress: "127.0.0.1")
        let failure = ConnectionError.connectionFailed("The peer stopped responding.")
        let hub = QSOHub(primary: EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false)),
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            connectOperation: { service, station in
                service.registerReconnectCandidate(station)
                service.error = failure
                service.session = QSOSession(station: station, state: .disconnected)
                service.session = nil // The transport's delayed cleanup has completed.
            })
        let service = await hub.connect(to: station, as: "N0RETRY")

        XCTAssertTrue(hub.entries.isEmpty)
        XCTAssertNil(hub.activeID)
        XCTAssertEqual(hub.lastError, failure.localizedDescription)
        XCTAssertEqual(service.error?.localizedDescription, failure.localizedDescription)
        XCTAssertEqual(service.reconnectCandidate?.callsign, station.callsign)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(hub.entries.isEmpty)
        XCTAssertNil(hub.activeID)
        XCTAssertNil(service.pttPermission)
        XCTAssertEqual(hub.lastError, failure.localizedDescription)
        XCTAssertEqual(service.error?.localizedDescription, failure.localizedDescription)
    }

    func testFailedDisconnectedPrimaryIsNotReadoptedByDeferredSessionObservation() async {
        let failure = ConnectionError.connectionFailed("The initial handshake failed.")
        let hub = QSOHub(primary: EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false)),
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            connectOperation: { service, station in
                service.registerReconnectCandidate(station)
                service.session = QSOSession(station: station, state: .disconnected)
                service.error = failure
            })

        let service = await hub.connect(to: Station(callsign: "TEST-FAIL", ipAddress: "127.0.0.1"), as: "N0FAIL")

        XCTAssertTrue(hub.entries.isEmpty)
        XCTAssertNil(hub.activeID)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(hub.entries.isEmpty)
        XCTAssertNil(hub.activeID)
        XCTAssertNil(service.pttPermission)
        XCTAssertEqual(hub.lastError, failure.localizedDescription)
        XCTAssertEqual(service.error?.localizedDescription, failure.localizedDescription)
        service.session = nil
    }

    func testFailedSecondaryAttemptRestoresPreviouslySelectedCallAndPreservesOtherAccounts() async throws {
        let failure = ConnectionError.connectionFailed("The new station did not answer.")
        let hub = QSOHub(primary: EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false)),
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            connectOperation: { service, station in
                if station.callsign == "TEST-FAIL" {
                    service.registerReconnectCandidate(station)
                    service.session = QSOSession(station: station, state: .disconnected)
                    service.session = nil
                    service.error = failure
                } else {
                    service.session = QSOSession(station: station, state: .connected)
                }
            })
        let first = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let second = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")
        let existingIDs = hub.entries.map(\.id)
        let selectedID = try XCTUnwrap(existingIDs.first)
        hub.select(selectedID)

        let failed = await hub.connect(to: Station(callsign: "TEST-FAIL", ipAddress: "127.0.0.3"), as: "N0FAIL")
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(hub.entries.map(\.id), existingIDs)
        XCTAssertEqual(hub.activeID, selectedID)
        XCTAssertTrue(hub.activeService === first)
        XCTAssertEqual(first.session?.state, .connected)
        XCTAssertEqual(second.session?.state, .connected)
        XCTAssertEqual(first.pttPermission?(), true)
        XCTAssertEqual(second.pttPermission?(), false)
        XCTAssertTrue(first.hasAudioFocus)
        XCTAssertFalse(second.hasAudioFocus)
        XCTAssertNil(failed.pttPermission)
        XCTAssertEqual(hub.lastError, failure.localizedDescription)
        XCTAssertEqual(failed.error?.localizedDescription, failure.localizedDescription)
        first.session = nil
        second.session = nil
    }

    func testConnectingAttemptRemainsManagedUntilItFailsAfterConnectReturns() async throws {
        let failure = ConnectionError.connectionFailed("The pending handshake failed.")
        let station = Station(callsign: "TEST-PENDING", ipAddress: "127.0.0.1")
        let hub = QSOHub(primary: EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false)),
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            connectOperation: { service, station in
                service.registerReconnectCandidate(station)
                service.session = QSOSession(station: station, state: .connecting)
            })
        let service = await hub.connect(to: station, as: "N0PENDING")
        let id = try XCTUnwrap(hub.activeID)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(hub.entries.map(\.id), [id])
        XCTAssertEqual(hub.activeID, id)
        XCTAssertEqual(service.session?.state, .connecting)
        XCTAssertEqual(service.pttPermission?(), true)
        XCTAssertFalse(service.canTransmit)

        service.error = failure
        var disconnected = service.session
        disconnected?.state = .disconnected
        service.session = disconnected
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(hub.entries.isEmpty)
        XCTAssertNil(hub.activeID)
        XCTAssertNil(service.pttPermission)
        XCTAssertEqual(service.error?.localizedDescription, failure.localizedDescription)
        service.session = nil
    }

    func testCancelledInitialAttemptDoesNotRemainAfterSuspendedConnectReturns() async throws {
        let started = expectation(description: "initial connection started")
        var finishConnection: CheckedContinuation<Void, Never>?
        let hub = QSOHub(primary: EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false)),
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            connectOperation: { service, station in
                service.registerReconnectCandidate(station)
                service.session = QSOSession(station: station, state: .connecting)
                await withCheckedContinuation { continuation in
                    finishConnection = continuation
                    started.fulfill()
                }
            })
        let connection = Task {
            await hub.connect(to: Station(callsign: "TEST-CANCEL", ipAddress: "127.0.0.1"), as: "N0CANCEL")
        }
        await fulfillment(of: [started], timeout: 2)
        let pendingID = hub.activeID
        let pendingService = hub.entries.first?.service
        hub.cancelPendingConnection(as: "N0CANCEL")
        finishConnection?.resume()
        let service = await connection.value
        for _ in 0..<10 { await Task.yield() }

        XCTAssertNotNil(pendingID)
        XCTAssertTrue(pendingService === service)
        XCTAssertTrue(hub.entries.isEmpty)
        XCTAssertNil(hub.activeID)
        XCTAssertNil(service.session)
        XCTAssertNil(service.pttPermission)
    }

    func testConnectedPrimaryRetainsSameReconnectPresentationAfterDrop() async throws {
        let station = Station(callsign: "TEST-DROP", ipAddress: "127.0.0.1")
        let hub = QSOHub(primary: EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false)),
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            connectOperation: { service, station in
                service.session = QSOSession(station: station, state: .connected)
            })
        let service = await hub.connect(to: station, as: "N0DROP")
        let id = try XCTUnwrap(hub.activeID)
        service.registerReconnectCandidate(station)
        var disconnected = service.session
        disconnected?.state = .disconnected
        service.session = disconnected
        service.session = nil
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(hub.entries.map(\.id), [id])
        XCTAssertEqual(hub.activeID, id)
        XCTAssertTrue(hub.activeService === service)
        XCTAssertEqual(hub.entry(for: id)?.station?.callsign, station.callsign)
        XCTAssertEqual(service.pttPermission?(), true)
        XCTAssertFalse(service.canTransmit)
        await hub.disconnectAll()
    }

    func testRapidConnectAndDropWithinInitialOperationRetainsReconnectPresentation() async throws {
        let station = Station(callsign: "TEST-RAPID", ipAddress: "127.0.0.1")
        var connectingID: UUID?
        let hub = QSOHub(primary: EchoLinkConnectionService(audioEngine: AudioEngine(hardwareEnabled: false)),
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            connectOperation: { service, station in
                var session = QSOSession(station: station, state: .connecting)
                service.session = session
                connectingID = session.id
                session.state = .connected
                service.session = session
                service.registerReconnectCandidate(station)
                session.state = .disconnected
                service.session = session
                service.session = nil
            })
        let service = await hub.connect(to: station, as: "N0RAPID")
        let id = try XCTUnwrap(hub.activeID)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertNotNil(connectingID)
        XCTAssertEqual(hub.entries.map(\.id), [id])
        XCTAssertEqual(hub.activeID, id)
        XCTAssertTrue(hub.activeService === service)
        XCTAssertEqual(hub.entry(for: id)?.station?.callsign, station.callsign)
        XCTAssertEqual(service.pttPermission?(), true)
        XCTAssertFalse(service.canTransmit)
        await hub.disconnectAll()
    }

    func testBackgroundExpirationPreservesExistingAndOtherAccountAttempts() async {
        let mode = EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
        let hub = QSOHub(primary: EchoLinkConnectionService(), networkConfigurationProvider: { mode },
            connectOperation: { service, station in service.session = QSOSession(station: station) })
        let existing = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let existingIDs = Set(hub.entries.map(\.id))
        let otherAccount = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")
        hub.cancelPendingConnection(as: "n0aaa", excluding: existingIDs)
        XCTAssertEqual(existing.session?.state, .connecting)
        XCTAssertEqual(otherAccount.session?.state, .connecting)
        hub.cancelPendingConnection(as: "n0bbb", excluding: existingIDs)
        XCTAssertNil(otherAccount.session)
        XCTAssertEqual(existing.session?.state, .connecting)
        await hub.disconnectAll()
    }

    func testAutomaticDirectAccountsShareTheDirectPortConcurrencyLimit() async {
        let preference = EchoLinkProxyConfiguration(mode: .automatic, host: "", port: 8100, password: "PUBLIC")
        let effective = EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "")
        let selection = EchoLinkEffectiveTransport(preference: preference, configuration: effective, relayAddress: nil)
        let hub = QSOHub(primary: EchoLinkConnectionService(), networkConfigurationProvider: { preference }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })
        hub.effectiveTransportProvider = { _ in selection }
        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let rejected = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")
        XCTAssertEqual(hub.entries.map(\.mode), [.direct])
        XCTAssertNil(rejected.session)
        XCTAssertTrue(hub.lastError?.contains("Direct mode supports one active QSO") == true)
    }

    func testAutomaticDirectFallbackReleasesDirectOwnershipForAnotherAccount() async {
        let automatic = EchoLinkProxyConfiguration(mode: .automatic, host: "", port: 8100, password: "PUBLIC")
        var firstMode = EchoLinkNetworkMode.direct
        let hub = QSOHub(primary: EchoLinkConnectionService(), networkConfigurationProvider: { automatic },
            connectOperation: { service, station in
                if station.callsign == "TEST-A" { firstMode = .publicProxy }
                service.installSimulatorDemoSession(station: station)
            })
        hub.effectiveTransportProvider = { account in
            let mode = account == "N0AAA" ? firstMode : .direct
            return EchoLinkEffectiveTransport(preference: automatic,
                configuration: EchoLinkProxyConfiguration(mode: mode, host: "proxy.example", port: 8100,
                    password: mode == .publicProxy ? "PUBLIC" : ""), relayAddress: nil)
        }

        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let second = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")

        XCTAssertEqual(hub.entries.map(\.mode), [.publicProxy, .direct])
        XCTAssertEqual(second.session?.state, .connected)
        XCTAssertNil(hub.lastError)
        await hub.disconnectAll()
    }

    func testAccountsUseTheirFrozenEffectiveModesAfterPreferenceChanges() async {
        let automatic = EchoLinkProxyConfiguration(mode: .automatic, host: "", port: 8100, password: "PUBLIC")
        let currentPreference = EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "")
        let hub = QSOHub(primary: EchoLinkConnectionService(), networkConfigurationProvider: { currentPreference }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })
        hub.effectiveTransportProvider = { account in
            let mode: EchoLinkNetworkMode = account == "N0AAA" ? .relay : .publicProxy
            return EchoLinkEffectiveTransport(preference: automatic,
                configuration: EchoLinkProxyConfiguration(mode: mode, host: "proxy.example", port: 8100, password: "PUBLIC"),
                relayAddress: mode == .relay ? "198.51.100.7" : nil)
        }
        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        _ = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")
        XCTAssertEqual(hub.entries.map(\.mode), [.relay, .publicProxy])
    }

    func testTwoCallsKeepSeparateServicesAndOnlySelectedCallCanTransmit() async {
        let primary = EchoLinkConnectionService()
        let relay = EchoLinkProxyConfiguration(
            mode: .relay,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: ""
        )
        let hub = QSOHub(primary: primary, networkConfigurationProvider: { relay }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })
        let firstStation = Station(callsign: "TEST-A", ipAddress: "127.0.0.1")
        let secondStation = Station(callsign: "TEST-B", ipAddress: "127.0.0.2")

        let first = await hub.connect(to: firstStation, as: "N0AAA")
        let second = await hub.connect(to: secondStation, as: "N0BBB")

        XCTAssertTrue(first === primary)
        XCTAssertFalse(second === primary)
        XCTAssertEqual(hub.entries.count, 2)
        XCTAssertEqual(hub.entries[1].mode, .relay)
        XCTAssertEqual(first.localCallsign, "N0AAA")
        XCTAssertEqual(second.localCallsign, "N0BBB")
        XCTAssertFalse(first.canTransmit)
        XCTAssertTrue(second.canTransmit)
        XCTAssertFalse(first.hasAudioFocus)
        XCTAssertTrue(second.hasAudioFocus)

        hub.select(hub.entries[0].id)
        XCTAssertTrue(first.canTransmit)
        XCTAssertFalse(second.canTransmit)
        XCTAssertTrue(first.hasAudioFocus)
        XCTAssertFalse(second.hasAudioFocus)
    }

    func testSecondaryReconnectRetainsRetryPresentationAfterFailedLookup() async {
        let primary = EchoLinkConnectionService()
        let relay = EchoLinkProxyConfiguration(
            mode: .relay,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: ""
        )
        let hub = QSOHub(
            primary: primary,
            networkConfigurationProvider: { relay },
            connectOperation: { service, station in
                service.installSimulatorDemoSession(station: station)
            }
        )
        let firstStation = Station(callsign: "TEST-A", ipAddress: "127.0.0.1")
        let secondStation = Station(callsign: "TEST-B", ipAddress: "127.0.0.2")
        _ = await hub.connect(to: firstStation, as: "N0AAA")
        let secondary = await hub.connect(to: secondStation, as: "N0BBB")
        hub.select(hub.entries[0].id)

        var disconnected = secondary.session
        disconnected?.state = .disconnected
        secondary.session = disconnected
        secondary.registerReconnectCandidate(secondStation)

        let lookupStarted = expectation(description: "secondary reconnect lookup started")
        var finishLookup: CheckedContinuation<Station?, Error>?
        secondary.resolveReconnectStation = { _ in
            try await withCheckedThrowingContinuation { continuation in
                finishLookup = continuation
                lookupStarted.fulfill()
            }
        }

        let reconnectTask = Task { await secondary.reconnect() }
        await fulfillment(of: [lookupStarted], timeout: 1)
        for _ in 0..<10 { await Task.yield() }

        let remainedManagedWhileWaiting = hub.entries.contains { $0.service === secondary }
        let permissionWhileWaiting = secondary.pttPermission?()

        finishLookup?.resume(returning: nil)
        await reconnectTask.value
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(remainedManagedWhileWaiting)
        XCTAssertEqual(permissionWhileWaiting, false)
        XCTAssertTrue(hub.entries.contains { $0.service === secondary })
        XCTAssertEqual(secondary.pttPermission?(), false)
        await secondary.disconnect()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(hub.entries.contains { $0.service === secondary })
    }

    func testCancellingSecondaryReconnectRemovesItBeforeSuspendedLookupReturns() async {
        let primary = EchoLinkConnectionService()
        let relay = EchoLinkProxyConfiguration(
            mode: .relay,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: ""
        )
        let hub = QSOHub(
            primary: primary,
            networkConfigurationProvider: { relay },
            connectOperation: { service, station in
                service.installSimulatorDemoSession(station: station)
            }
        )
        _ = await hub.connect(
            to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"),
            as: "N0AAA"
        )
        let secondStation = Station(callsign: "TEST-B", ipAddress: "127.0.0.2")
        let secondary = await hub.connect(to: secondStation, as: "N0BBB")
        hub.select(hub.entries[0].id)

        var disconnected = secondary.session
        disconnected?.state = .disconnected
        secondary.session = disconnected
        secondary.registerReconnectCandidate(secondStation)

        let lookupStarted = expectation(description: "secondary reconnect lookup started")
        var finishLookup: CheckedContinuation<Station?, Error>?
        secondary.resolveReconnectStation = { _ in
            try await withCheckedThrowingContinuation { continuation in
                finishLookup = continuation
                lookupStarted.fulfill()
            }
        }

        let reconnectTask = Task { await secondary.reconnect() }
        await fulfillment(of: [lookupStarted], timeout: 1)
        await secondary.disconnect()
        for _ in 0..<10 where hub.entries.contains(where: { $0.service === secondary }) {
            await Task.yield()
        }
        let removedBeforeLookupReturned = !hub.entries.contains { $0.service === secondary }

        finishLookup?.resume(returning: secondStation)
        await reconnectTask.value
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(removedBeforeLookupReturned)
        XCTAssertNil(secondary.session)
        XCTAssertFalse(hub.entries.contains { $0.service === secondary })
        XCTAssertNil(secondary.pttPermission)
    }

    func testObsoleteReconnectCompletionDoesNotEndNewerSecondaryReconnect() async {
        let primary = EchoLinkConnectionService()
        let relay = EchoLinkProxyConfiguration(
            mode: .relay,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: ""
        )
        let hub = QSOHub(
            primary: primary,
            networkConfigurationProvider: { relay },
            connectOperation: { service, station in
                service.installSimulatorDemoSession(station: station)
            }
        )
        _ = await hub.connect(
            to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"),
            as: "N0AAA"
        )
        let secondStation = Station(callsign: "TEST-B", ipAddress: "127.0.0.2")
        let secondary = await hub.connect(to: secondStation, as: "N0BBB")
        hub.select(hub.entries[0].id)

        var disconnected = secondary.session
        disconnected?.state = .disconnected
        secondary.session = disconnected
        secondary.registerReconnectCandidate(secondStation)

        let firstLookupStarted = expectation(description: "first reconnect lookup started")
        let secondLookupStarted = expectation(description: "second reconnect lookup started")
        var lookupCount = 0
        var finishFirstLookup: CheckedContinuation<Station?, Error>?
        var finishSecondLookup: CheckedContinuation<Station?, Error>?
        secondary.resolveReconnectStation = { _ in
            lookupCount += 1
            return try await withCheckedThrowingContinuation { continuation in
                if lookupCount == 1 {
                    finishFirstLookup = continuation
                    firstLookupStarted.fulfill()
                } else {
                    finishSecondLookup = continuation
                    secondLookupStarted.fulfill()
                }
            }
        }

        let firstReconnect = Task { await secondary.reconnect() }
        await fulfillment(of: [firstLookupStarted], timeout: 1)
        await secondary.disconnect()

        secondary.session = QSOSession(station: secondStation, state: .disconnected)
        secondary.registerReconnectCandidate(secondStation)
        let secondReconnect = Task { await secondary.reconnect() }
        await fulfillment(of: [secondLookupStarted], timeout: 1)

        finishFirstLookup?.resume(returning: secondStation)
        await firstReconnect.value
        for _ in 0..<10 { await Task.yield() }

        let newerReconnectStillActive = secondary.isReconnecting
        let remainedManaged = hub.entries.contains { $0.service === secondary }
        let permissionStayedConstrained = secondary.pttPermission?()

        finishSecondLookup?.resume(returning: nil)
        await secondReconnect.value
        for _ in 0..<10 where hub.entries.contains(where: { $0.service === secondary }) {
            await Task.yield()
        }

        XCTAssertTrue(newerReconnectStillActive)
        XCTAssertTrue(remainedManaged)
        XCTAssertEqual(permissionStayedConstrained, false)
        XCTAssertTrue(hub.entries.contains { $0.service === secondary })
        await hub.disconnect(callsign: "N0BBB")
        XCTAssertFalse(hub.entries.contains { $0.service === secondary })
    }

    func testCancellingConnectingPhaseClearsReconnectAfterObsoleteLookupReturns() async {
        let primary = EchoLinkConnectionService()
        let relay = EchoLinkProxyConfiguration(
            mode: .relay,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: ""
        )
        let hub = QSOHub(
            primary: primary,
            networkConfigurationProvider: { relay },
            connectOperation: { service, station in
                service.installSimulatorDemoSession(station: station)
            }
        )
        _ = await hub.connect(
            to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"),
            as: "N0AAA"
        )
        let secondStation = Station(callsign: "TEST-B", ipAddress: "127.0.0.2")
        let secondary = await hub.connect(to: secondStation, as: "N0BBB")
        hub.select(hub.entries[0].id)

        var disconnected = secondary.session
        disconnected?.state = .disconnected
        secondary.session = disconnected
        secondary.registerReconnectCandidate(secondStation)

        let lookupStarted = expectation(description: "secondary reconnect lookup started")
        var finishLookup: CheckedContinuation<Station?, Error>?
        secondary.resolveReconnectStation = { _ in
            try await withCheckedThrowingContinuation { continuation in
                finishLookup = continuation
                lookupStarted.fulfill()
            }
        }

        let reconnectTask = Task { await secondary.reconnect() }
        await fulfillment(of: [lookupStarted], timeout: 1)
        secondary.session = QSOSession(station: secondStation, state: .connecting)
        secondary.cancelPendingConnection()

        finishLookup?.resume(returning: secondStation)
        await reconnectTask.value
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(secondary.isReconnecting)
        XCTAssertNil(secondary.session)
        XCTAssertFalse(hub.entries.contains { $0.service === secondary })
        XCTAssertNil(secondary.pttPermission)
    }

    func testSecondDirectCallIsRejectedInsteadOfSilentlyUsingRelay() async {
        let direct = EchoLinkProxyConfiguration(
            mode: .direct,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: ""
        )
        let hub = QSOHub(
            primary: EchoLinkConnectionService(),
            networkConfigurationProvider: { direct },
            connectOperation: { service, station in
                service.installSimulatorDemoSession(station: station)
            }
        )

        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let rejected = await hub.connect(
            to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"),
            as: "N0AAA"
        )

        XCTAssertEqual(hub.entries.count, 1)
        XCTAssertNil(rejected.session)
        XCTAssertEqual(hub.entries.map(\.mode), [.direct])
        XCTAssertTrue(hub.lastError?.contains("Direct mode supports one active QSO") == true)
    }

    func testAdoptsExternallyCreatedPrimaryAlongsideExistingCall() async {
        let primary = EchoLinkConnectionService()
        primary.authenticatedCallsign = "N0PRIMARY"
        primary.installSimulatorDemoSession(
            station: Station(callsign: "PRIMARY", ipAddress: "127.0.0.1")
        )
        let relay = EchoLinkProxyConfiguration(
            mode: .relay,
            host: "",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: ""
        )
        let hub = QSOHub(primary: primary, networkConfigurationProvider: { relay }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })

        let secondary = await hub.connect(
            to: Station(callsign: "SECONDARY", ipAddress: "127.0.0.2"),
            as: "N0SECONDARY"
        )
        await Task.yield()

        XCTAssertEqual(hub.entries.count, 2)
        XCTAssertTrue(hub.entries.contains { $0.service === primary && $0.callsign == "N0PRIMARY" })
        XCTAssertTrue(hub.entries.contains { $0.service === secondary && $0.callsign == "N0SECONDARY" })
        XCTAssertTrue(hub.activeService === secondary)
        XCTAssertFalse(primary.canTransmit)
        XCTAssertTrue(secondary.canTransmit)
    }

    func testSecondAccountKeepsSelectedProxyTransport() async {
        let proxy = EchoLinkProxyConfiguration(
            mode: .publicProxy,
            host: "proxy.example",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: "PUBLIC"
        )
        let hub = QSOHub(primary: EchoLinkConnectionService(), networkConfigurationProvider: { proxy }, connectOperation: { service, station in
            service.installSimulatorDemoSession(station: station)
        })
        _ = await hub.connect(
            to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"),
            as: "N0AAA"
        )
        _ = await hub.connect(
            to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"),
            as: "N0BBB"
        )

        XCTAssertEqual(hub.entries.map(\.mode), [.publicProxy, .publicProxy])
    }

    func testSecondProxyCallForSameAccountIsRejectedInsteadOfUsingRelay() async {
        let proxy = EchoLinkProxyConfiguration(
            mode: .publicProxy,
            host: "proxy.example",
            port: EchoLinkProxyConfiguration.defaultPort,
            password: "PUBLIC"
        )
        let hub = QSOHub(
            primary: EchoLinkConnectionService(),
            networkConfigurationProvider: { proxy },
            connectOperation: { service, station in
                service.installSimulatorDemoSession(station: station)
            }
        )

        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let rejected = await hub.connect(
            to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"),
            as: "n0aaa"
        )

        XCTAssertEqual(hub.entries.count, 1)
        XCTAssertNil(rejected.session)
        XCTAssertEqual(hub.entries.map(\.mode), [.publicProxy])
        XCTAssertTrue(hub.lastError?.contains("already has an active QSO") == true)
    }

    func testSecondRelayCallForSameAccountIsRejected() async {
        let relay = EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
        let hub = QSOHub(
            primary: EchoLinkConnectionService(),
            networkConfigurationProvider: { relay },
            connectOperation: { service, station in service.installSimulatorDemoSession(station: station) }
        )

        _ = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        let rejected = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "n0aaa")

        XCTAssertEqual(hub.entries.count, 1)
        XCTAssertNil(rejected.session)
        XCTAssertTrue(hub.lastError?.contains("already has an active QSO") == true)
    }

    func testReusedPrimaryCannotBypassActiveCallsignCheck() async {
        let relay = EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
        let hub = QSOHub(
            primary: EchoLinkConnectionService(),
            networkConfigurationProvider: { relay },
            connectOperation: { service, station in service.installSimulatorDemoSession(station: station) }
        )
        let first = await hub.connect(to: Station(callsign: "TEST-A", ipAddress: "127.0.0.1"), as: "N0AAA")
        _ = await hub.connect(to: Station(callsign: "TEST-B", ipAddress: "127.0.0.2"), as: "N0BBB")
        await first.disconnect()
        for _ in 0..<10 where hub.entries.count > 1 { await Task.yield() }

        XCTAssertEqual(hub.entries.count, 1)
        let rejected = await hub.connect(to: Station(callsign: "TEST-C", ipAddress: "127.0.0.3"), as: "N0BBB")
        XCTAssertNil(rejected.session)
        XCTAssertEqual(hub.entries.count, 1)
        XCTAssertTrue(hub.lastError?.contains("already has an active QSO") == true)
    }

    func testFailedConnectionDoesNotRemainInHub() async {
        let primary = EchoLinkConnectionService()
        let hub = QSOHub(primary: primary, connectOperation: { _, _ in })

        _ = await hub.connect(
            to: Station(callsign: "UNREACHABLE", ipAddress: "127.0.0.1"),
            as: "N0TEST"
        )

        XCTAssertTrue(hub.entries.isEmpty)
        XCTAssertNil(hub.activeID)
    }
}

@MainActor
private final class QSOHubOperationGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(_ description: String) {
        entered = XCTestExpectation(description: description)
    }

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            precondition(self.continuation == nil, "Each gate permits only one suspended operation")
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class ConnectionAttemptLifetimeTests: XCTestCase {
    func testCompletionEndsAssertionExactlyOnce() {
        var endings = 0
        var expirations = 0
        var expire: (@MainActor @Sendable () -> Void)?
        let lifetime = ConnectionAttemptLifetime { expirations += 1 }
        lifetime.begin { handler in
            expire = handler
            return { endings += 1 }
        }
        lifetime.end()
        lifetime.end()
        expire?()
        XCTAssertEqual(endings, 1)
        XCTAssertEqual(expirations, 0)
    }

    func testExpirationCancelsBeforeEndingAssertion() {
        var events: [String] = []
        var expire: (@MainActor @Sendable () -> Void)?
        let lifetime = ConnectionAttemptLifetime { events.append("cancel") }
        lifetime.begin { handler in
            expire = handler
            return { events.append("end") }
        }
        expire?()
        expire?()
        lifetime.end()
        XCTAssertEqual(events, ["cancel", "end"])
    }

    func testSynchronousExpirationStillEndsReturnedAssertion() {
        var endings = 0
        var expirations = 0
        let lifetime = ConnectionAttemptLifetime { expirations += 1 }
        lifetime.begin { handler in
            handler()
            return { endings += 1 }
        }
        lifetime.end()
        XCTAssertEqual(expirations, 1)
        XCTAssertEqual(endings, 1)
    }

    func testUnavailableAssertionStillAllowsNormalCompletion() {
        var expired = false
        let lifetime = ConnectionAttemptLifetime { expired = true }
        lifetime.begin { _ in nil }
        lifetime.end()
        XCTAssertFalse(expired)
    }
}
