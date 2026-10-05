// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import XCTest
@testable import ReverbQSO

@MainActor
final class ProxyDirectoryRefreshTests: XCTestCase {
    func testMatchedControlWithoutSDESAndCancellationDoNotReportUnansweredProxy() async throws {
        for cancel in [false, true] {
            let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh, replyToControl: !cancel)
            try await proxy.start()
            defer { proxy.stop() }
            let preference = EchoLinkProxyConfiguration(mode: .publicProxy, host: "", port: 8100, password: "PUBLIC")
            let candidate = EchoLinkProxyConfiguration(mode: .publicProxy, host: "127.0.0.1", port: proxy.port, password: "PUBLIC")
            let store = EchoLinkProxySessionStore(configurationProvider: { preference }, resolveCandidates: { _ in [candidate] })
            let service = EchoLinkDirectoryService(proxySessionStore: store, configurationProvider: { preference },
                client: DirectoryClient(host: "127.0.0.1"), saveCredentials: { _, _, _ in true })
            await service.login(callsign: "N0TEST", password: "directory-password")
            XCTAssertTrue(service.isLoggedIn)
            let connection = EchoLinkConnectionService(networkConfigurationProvider: { preference },
                handshakeRetryIntervals: [cancel ? .seconds(5) : .milliseconds(200)])
            connection.authenticatedCallsign = "N0TEST"
            connection.setBackgroundMuted(true)
            connection.resolveProxySession = { try await service.prepareProxySession(callsign: $0) }
            var reports = 0
            connection.reportUnansweredProxyHandshake = { _ in reports += 1 }
            let operation = Task { await connection.connect(to: Station(callsign: "TEST-R", ipAddress: "198.51.100.10")) }
            await fulfillment(of: [proxy.controlReceived], timeout: 3)
            if cancel { connection.cancelPendingConnection(); operation.cancel() }
            await operation.value
            XCTAssertEqual(reports, 0, cancel ? "Cancellation must not mark a public proxy" : "Matched control is evidence of a working inbound path even without SDES")
            await service.logout()
        }
    }

    func testExplicitRetryReplacesUnansweredPublicProxyAndRegistersBeforeReturning() async throws {
        let first = try RefreshTestProxy(behavior: .delayFirstRefresh)
        let second = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await first.start()
        try await second.start()
        defer { first.stop(); second.stop() }
        let preference = EchoLinkProxyConfiguration(mode: .publicProxy, host: "", port: 8100, password: "PUBLIC")
        let candidates = [first, second].map {
            EchoLinkProxyConfiguration(mode: .publicProxy, host: "127.0.0.1", port: $0.port, password: "PUBLIC")
        }
        let store = EchoLinkProxySessionStore(configurationProvider: { preference }, resolveCandidates: { _ in candidates })
        let client = DirectoryClient(host: "127.0.0.1")
        let service = EchoLinkDirectoryService(proxySessionStore: store, configurationProvider: { preference },
            client: client, saveCredentials: { _, _, _ in true })
        await service.login(callsign: "N0TEST", password: "directory-password")
        XCTAssertTrue(service.isLoggedIn)
        let unansweredSession = try await service.prepareProxySession(callsign: "N0TEST")
        let unanswered = try XCTUnwrap(unansweredSession)
        let sameHealthy = try await service.prepareProxySession(callsign: "N0TEST")
        XCTAssertTrue(sameHealthy === unanswered)
        let connection = EchoLinkConnectionService(networkConfigurationProvider: { preference },
            handshakeRetryIntervals: [.milliseconds(50)])
        connection.authenticatedCallsign = "N0TEST"
        connection.setBackgroundMuted(true)
        connection.resolveProxySession = { try await service.prepareProxySession(callsign: $0) }
        var reports = 0
        connection.reportUnansweredProxyHandshake = {
            reports += 1
            await service.reportUnansweredProxyHandshake($0)
        }
        await connection.connect(to: Station(callsign: "TEST-R", ipAddress: "198.51.100.10"))
        XCTAssertEqual(reports, 1, "Only an unanswered handshake timeout marks the tunnel")
        let replacementSession = try await service.prepareProxySession(callsign: "N0TEST")
        let replacement = try XCTUnwrap(replacementSession)
        XCTAssertFalse(replacement === unanswered)
        let replacementConfiguration = await replacement.configuration
        XCTAssertEqual(replacementConfiguration.port, second.port)
        XCTAssertEqual(second.authenticatedConnectionCount, 1)
        XCTAssertEqual(second.registrationRequestCount, 1, "Replacement must register directory before QSO can send")
        let active = await client.activeProxySession()
        XCTAssertTrue(active === replacement)
        await service.reportUnansweredProxyHandshake(unanswered)
        let afterStaleReport = try await service.prepareProxySession(callsign: "N0TEST")
        XCTAssertTrue(afterStaleReport === replacement, "Old attempts cannot retire a newer tunnel")
        await service.logout()
    }

    func testUnansweredHandshakeDoesNotRotateCustomProxy() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let (service, _) = makeService(proxy: proxy)
        await service.login(callsign: "N0TEST", password: "directory-password")
        let originalSession = try await service.prepareProxySession(callsign: "N0TEST")
        let original = try XCTUnwrap(originalSession)
        let configuration = await original.configuration
        let connection = EchoLinkConnectionService(networkConfigurationProvider: { configuration },
            handshakeRetryIntervals: [.milliseconds(50)])
        connection.authenticatedCallsign = "N0TEST"
        connection.setBackgroundMuted(true)
        connection.resolveProxySession = { try await service.prepareProxySession(callsign: $0) }
        var reports = 0
        connection.reportUnansweredProxyHandshake = { _ in reports += 1 }
        await connection.connect(to: Station(callsign: "TEST-R", ipAddress: "198.51.100.10"))
        XCTAssertEqual(reports, 0)
        await service.reportUnansweredProxyHandshake(original)
        let next = try await service.prepareProxySession(callsign: "N0TEST")
        XCTAssertTrue(next === original)
        XCTAssertEqual(proxy.authenticatedConnectionCount, 1)
        await service.logout()
    }

    private final class CQCapturingClient: CallCQClientProtocol, @unchecked Sendable {
        var address: String?
        func register(_ registration: CallCQRegistration, password: String) async throws {
            address = registration.internetAddress
        }
        func find(callsign: String, password: String) async throws -> CallCQPollResponse {
            .matched(callsign: "K1MATCH", internetAddress: "192.0.2.10")
        }
        func cancel(callsign: String, password: String) async {}
    }

    func testCQAdvertisesAuthenticatedProxyAddressWhenRegistrationHasNoAddress() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let (directory, _) = makeService(proxy: proxy)
        await directory.login(callsign: "N0TEST", password: "directory-password")
        XCTAssertTrue(directory.isLoggedIn)
        let registration = CallCQRegistration(callsign: "N0TEST", nodeType: "U", internetAddress: nil,
            countryCode: "US", isReachable: true, acceptCountryCodes: [], acceptLanguageCodes: ["en"],
            declineCallsigns: [], acceptNodeTypes: ["U"])
        let client = CQCapturingClient()
        let backend = LiveCallCQBackend(registration: registration, password: "cq-test", directory: directory,
            policy: CallAccessPolicy(), client: client, pollDelay: .zero)
        _ = try await backend.waitForMatch(preferences: .default)
        XCTAssertEqual(client.address, "127.0.0.1", "Advertise the authenticated tunnel, not an empty proxy preference")
        XCTAssertFalse(directory.isAvailableForCalls)
        await directory.logout()
    }

    func testOverlappingRefreshesAreSerializedAndLatestRefreshSucceeds() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let (service, _) = makeService(proxy: proxy)

        await service.login(callsign: "N0TEST", password: "directory-password")
        XCTAssertTrue(service.isLoggedIn, service.error?.localizedDescription ?? "")

        let first = Task { await service.refresh() }
        await proxy.waitForDelayedRefresh()
        let second = Task { await service.refresh() }

        _ = await first.value // It may be superseded by the newer refresh generation.
        let secondSucceeded = await second.value
        XCTAssertTrue(secondSucceeded)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.stations.map(\.callsign), ["K6FRESH-R"])
        XCTAssertEqual(proxy.refreshRequestCount, 2)
    }

    func testRefreshAndAvailabilityRegistrationShareSerializedProxyDirectoryAccess() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let (service, _) = makeService(proxy: proxy)

        await service.login(callsign: "N0TEST", password: "directory-password")
        XCTAssertTrue(service.isLoggedIn, service.error?.localizedDescription ?? "")

        let refresh = Task { await service.refresh() }
        await proxy.waitForDelayedRefresh()
        let availability = Task { await service.setAvailableForCalls(true) }

        let refreshSucceeded = await refresh.value
        let availabilitySucceeded = await availability.value
        XCTAssertTrue(refreshSucceeded)
        XCTAssertTrue(availabilitySucceeded)
        XCTAssertTrue(service.isAvailableForCalls)
        XCTAssertNil(service.error)
        XCTAssertEqual(proxy.refreshRequestCount, 1)
        XCTAssertEqual(proxy.registrationRequestCount, 2)
    }

    func testRefreshReauthenticatesAfterProxyDropsWithoutReadingKeychain() async throws {
        let proxy = try RefreshTestProxy(behavior: .dropFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let (service, _) = makeService(proxy: proxy)

        await service.login(callsign: "N0TEST", password: "directory-password")
        XCTAssertTrue(service.isLoggedIn, service.error?.localizedDescription ?? "")

        let availabilitySucceeded = await service.setAvailableForCalls(true)
        let refreshSucceeded = await service.refresh()
        XCTAssertTrue(availabilitySucceeded)
        XCTAssertTrue(refreshSucceeded)

        XCTAssertTrue(service.isLoggedIn)
        XCTAssertTrue(service.isAvailableForCalls)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.stations.map(\.callsign), ["K6FRESH-R"])
        XCTAssertEqual(proxy.authenticatedConnectionCount, 2)
        XCTAssertEqual(proxy.registrationRequestCount, 3)
    }

    func testCancellingActiveRefreshDrainsResponseWithoutRetiringSharedProxy() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let (service, _) = makeService(proxy: proxy)

        await service.login(callsign: "N0TEST", password: "directory-password")
        XCTAssertTrue(service.isLoggedIn, service.error?.localizedDescription ?? "")

        let cancelledRefresh = Task { await service.refresh() }
        await proxy.waitForDelayedRefresh()
        cancelledRefresh.cancel()

        let cancelledSucceeded = await cancelledRefresh.value
        XCTAssertFalse(cancelledSucceeded)
        XCTAssertNil(service.error)

        let subsequentSucceeded = await service.refresh()
        XCTAssertTrue(subsequentSucceeded)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.stations.map(\.callsign), ["K6FRESH-R"])
        XCTAssertEqual(proxy.refreshRequestCount, 2)
        XCTAssertEqual(proxy.authenticatedConnectionCount, 1)
    }

    func testCancellingQueuedRefreshRemovesItWithoutPoisoningProxyChannel() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let (service, _) = makeService(proxy: proxy)

        await service.login(callsign: "N0TEST", password: "directory-password")
        XCTAssertTrue(service.isLoggedIn, service.error?.localizedDescription ?? "")

        let activeRefresh = Task { await service.refresh() }
        await proxy.waitForDelayedRefresh()
        let cancelledQueuedRefresh = Task { await service.refresh() }
        await Task.yield()
        cancelledQueuedRefresh.cancel()

        let cancelledSucceeded = await cancelledQueuedRefresh.value
        XCTAssertFalse(cancelledSucceeded)
        _ = await activeRefresh.value // Superseded by the queued refresh generation.
        XCTAssertNil(service.error)

        let subsequentSucceeded = await service.refresh()
        XCTAssertTrue(subsequentSucceeded)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.stations.map(\.callsign), ["K6FRESH-R"])
        XCTAssertEqual(proxy.refreshRequestCount, 2, "A cancelled queued refresh must not send a proxy command")
        XCTAssertEqual(proxy.authenticatedConnectionCount, 1)
    }

    private func makeService(proxy: RefreshTestProxy) -> (EchoLinkDirectoryService, DirectoryClient) {
        let configuration = EchoLinkProxyConfiguration(
            mode: .customProxy,
            host: "127.0.0.1",
            port: proxy.port,
            password: "proxy-password"
        )
        let client = DirectoryClient(host: "127.0.0.1")
        let store = EchoLinkProxySessionStore(configurationProvider: { configuration })
        let service = EchoLinkDirectoryService(
            proxySessionStore: store,
            configurationProvider: { configuration },
            client: client,
            saveCredentials: { _, _, _ in true }
        )
        return (service, client)
    }
}

private final class RefreshTestProxy: @unchecked Sendable {
    enum Behavior {
        case delayFirstRefresh
        case dropFirstRefresh
    }

    private let behavior: Behavior
    private let replyToControl: Bool
    let controlReceived = XCTestExpectation(description: "outgoing peer control reached local proxy")
    private var receivedControl = false
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ProxyDirectoryRefreshTests.proxy")
    private let ready = XCTestExpectation(description: "loopback proxy ready")
    private let delayedRefresh = XCTestExpectation(description: "first refresh reached proxy")
    private var connections: [NWConnection] = []
    private var stationRequests = 0
    private var registrations = 0
    private var authentications = 0

    var port: UInt16 { listener.port!.rawValue }
    var refreshRequestCount: Int { queue.sync { max(0, stationRequests - 1) } }
    var registrationRequestCount: Int { queue.sync { registrations } }
    var authenticatedConnectionCount: Int { queue.sync { authentications } }

    init(behavior: Behavior, replyToControl: Bool = false) throws {
        self.behavior = behavior
        self.replyToControl = replyToControl
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    func start() async throws {
        listener.start(queue: queue)
        _ = await XCTWaiter.fulfillment(of: [ready], timeout: 2)
        _ = try XCTUnwrap(listener.port)
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    func waitForDelayedRefresh() async {
        _ = await XCTWaiter.fulfillment(of: [delayedRefresh], timeout: 2)
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.send(content: Data("12345678".utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { return }
            self?.receiveAuthentication(on: connection)
        })
    }

    private func receiveAuthentication(on connection: NWConnection) {
        // "N0TEST\n" followed by the 16-byte MD5 response.
        connection.receive(minimumIncompleteLength: 23, maximumLength: 23) { [weak self] data, _, _, error in
            guard let self, error == nil, data?.prefix(7) == Data("N0TEST\n".utf8) else {
                connection.cancel()
                return
            }
            self.authentications += 1
            self.receiveFrames(on: connection, buffer: Data())
        }
    }

    private func receiveFrames(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var pending = buffer
            if let data { pending.append(data) }
            do {
                while let message = try EchoLinkProxyProtocol.parseNextMessage(from: &pending) {
                    self.handle(message, on: connection)
                }
            } catch {
                connection.cancel()
                return
            }
            guard error == nil, !complete else { return }
            self.receiveFrames(on: connection, buffer: pending)
        }
    }

    private func handle(_ message: EchoLinkProxyMessage, on connection: NWConnection) {
        switch message.type {
        case .tcpOpen:
            send(.tcpStatus, payload: Data(repeating: 0, count: 4), on: connection)
        case .tcpData:
            if message.payload.starts(with: Data("-LOGIN\n".utf8)) {
                registrations += 1
                send(.tcpData, payload: Data("LOGIN-RESULT\nresult:success\n\n".utf8), on: connection)
            } else if message.payload == Data("s".utf8) {
                stationRequests += 1
                let ordinal = stationRequests
                if ordinal == 2 {
                    delayedRefresh.fulfill()
                    switch behavior {
                    case .delayFirstRefresh:
                        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                            self?.sendStationList(on: connection)
                        }
                    case .dropFirstRefresh:
                        connection.cancel()
                    }
                } else {
                    sendStationList(on: connection)
                }
            }
        case .udpControl:
            if !receivedControl { receivedControl = true; controlReceived.fulfill() }
            if replyToControl {
                // A valid peer RR is deliberately not a handshake acceptance.
                let frame = try! EchoLinkProxyProtocol.encode(type: .udpControl,
                    remoteHost: message.remoteHost, payload: Data([0x80, 201, 0, 1, 0, 0, 0, 1]))
                connection.send(content: frame, completion: .idempotent)
            }
        case .tcpClose, .udpData, .tcpStatus, .system:
            break
        }
    }

    private func sendStationList(on connection: NWConnection) {
        let payload = Data("@@@\n1\nK6FRESH-R\nRefresh Test\n12345\n192.0.2.25\n+++\n".utf8)
        send(.tcpData, payload: payload, on: connection)
    }

    private func send(
        _ type: EchoLinkProxyMessage.MessageType,
        payload: Data,
        on connection: NWConnection
    ) {
        let frame = try! EchoLinkProxyProtocol.encode(
            type: type,
            remoteHost: "0.0.0.0",
            payload: payload
        )
        connection.send(content: frame, completion: .idempotent)
    }
}
