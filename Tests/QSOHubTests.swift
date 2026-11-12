// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class QSOHubTests: XCTestCase {
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
