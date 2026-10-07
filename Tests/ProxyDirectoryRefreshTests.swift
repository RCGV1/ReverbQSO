// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import XCTest
@testable import ReverbQSO

@MainActor
final class ProxyDirectoryRefreshTests: XCTestCase {
    func testAutomaticDirectTimeoutUsesOneProxyFallbackAndExchangesVoice() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh, acceptPeerControl: true)
        try await proxy.start()
        defer { proxy.stop() }
        let (directory, _) = makeService(proxy: proxy)
        await directory.login(callsign: "N0TEST", password: "directory-password")
        let preference = EchoLinkProxyConfiguration(mode: .automatic, host: "", port: 8100, password: "PUBLIC")
        let direct = EchoLinkEffectiveTransport(preference: preference,
            configuration: EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: ""), relayAddress: nil)
        let connection = EchoLinkConnectionService(networkConfigurationProvider: { preference },
            handshakeRetryIntervals: [.milliseconds(50)])
        connection.authenticatedCallsign = "N0TEST"
        connection.setBackgroundMuted(true)
        connection.effectiveTransportProvider = { direct }
        connection.resolveProxySession = { try await directory.prepareProxySession(callsign: $0) }
        var fallbackCount = 0
        connection.prepareAutomaticPublicProxyFallback = { _ in
            fallbackCount += 1
            return EchoLinkEffectiveTransport(preference: preference,
                configuration: EchoLinkProxyConfiguration(mode: .publicProxy, host: "", port: 8100, password: "PUBLIC"),
                relayAddress: nil)
        }
        await connection.connect(to: Station(callsign: "TEST-R", ipAddress: "127.0.0.2"))
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertEqual(connection.session?.state, .connected, connection.error?.localizedDescription ?? "")
        XCTAssertNil(connection.error)
        await connection.sendChat(message: "Fallback worked")
        for _ in 0..<100 where !connection.incomingChatMessages.contains(where: { !$0.isOutgoing }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(connection.incomingChatMessages.contains(where: { !$0.isOutgoing }))
        await connection.disconnect()
        await directory.logout()
        await directory.closeProxySession()
    }

    func testDirectoryTimeoutPreservesVoiceUntilDisconnectThenRecoversDirectory() async throws {
        let proxy = try RefreshTestProxy(behavior: .stallFirstRefresh, acceptPeerControl: true)
        try await proxy.start()
        defer { proxy.stop() }
        let (directory, _) = makeService(proxy: proxy)
        await directory.login(callsign: "N0TEST", password: "directory-password")
        XCTAssertTrue(directory.isLoggedIn)
        let prepared = try await directory.prepareProxySession(callsign: "N0TEST")
        let shared = try XCTUnwrap(prepared)
        let configuration = await shared.configuration
        let connection = EchoLinkConnectionService(networkConfigurationProvider: { configuration },
            handshakeRetryIntervals: [.milliseconds(200)])
        connection.authenticatedCallsign = "N0TEST"
        connection.setBackgroundMuted(true)
        connection.resolveProxySession = { try await directory.prepareProxySession(callsign: $0) }
        await connection.connect(to: Station(callsign: "TEST-R", ipAddress: "198.51.100.10"))
        XCTAssertEqual(connection.session?.state, .connected)

        do {
            _ = try await shared.serializedDirectoryRequest(Data("s".utf8), host: "127.0.0.1",
                boundary: .marker(Data("+++".utf8)), timeout: .milliseconds(50))
            XCTFail("The local directory intentionally stalls")
        } catch { }
        let usable = await shared.isUsable()
        XCTAssertTrue(usable, "A directory timeout must not close a working voice tunnel")
        let refreshedWhileConnected = await directory.refresh()
        XCTAssertFalse(refreshedWhileConnected, "Do not reuse an uncorrelated directory channel")
        XCTAssertTrue(directory.isLoggedIn, "Keep the local account and active QSO")
        XCTAssertEqual(proxy.authenticatedConnectionCount, 1)
        XCTAssertEqual(connection.session?.state, .connected)
        XCTAssertNil(connection.error)

        await connection.sendChat(message: "Voice tunnel survived")
        for _ in 0..<100 where !connection.incomingChatMessages.contains(where: { !$0.isOutgoing }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(connection.incomingChatMessages.contains(where: { !$0.isOutgoing }))
        var voicePackets = 0
        connection.onAuditIncomingDatagram = { _ in voicePackets += 1 }
        let payload = try XCTUnwrap(GSMCodec.stripHeader(GSMCodec().encode([Int16](repeating: 0, count: 640))))
        try await shared.sendAudio(EchoLinkAudioPacketCodec.buildLegacyVoicePacket(gsmPayload: payload, sequence: 1),
            to: "198.51.100.10")
        for _ in 0..<100 where voicePackets == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(voicePackets, 1)
        connection.onAuditIncomingDatagram = nil
        await connection.disconnect()
        for _ in 0..<100 where proxy.authenticatedConnectionCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(proxy.authenticatedConnectionCount, 2,
            "Hanging up must automatically renew the directory, without a manual refresh")
        let recovered = await directory.refresh()
        XCTAssertTrue(recovered, directory.error?.localizedDescription ?? "")
        XCTAssertEqual(proxy.authenticatedConnectionCount, 2)
        XCTAssertNil(directory.error)
        await directory.logout()
        await directory.closeProxySession()
    }

    func testDirectoryCommandFailureKeepsConnectedQSOAndVoiceTunnelAlive() async throws {
        for behavior in [RefreshTestProxy.Behavior.closeFirstRefresh, .rejectFirstRefreshOpen] {
            let proxy = try RefreshTestProxy(behavior: behavior, acceptPeerControl: true)
            try await proxy.start()
            let (directory, _) = makeService(proxy: proxy)
            await directory.login(callsign: "N0TEST", password: "directory-password")
            XCTAssertTrue(directory.isLoggedIn)
            let prepared = try await directory.prepareProxySession(callsign: "N0TEST")
            let shared = try XCTUnwrap(prepared)
            let configuration = await shared.configuration
            let connection = EchoLinkConnectionService(networkConfigurationProvider: { configuration },
                handshakeRetryIntervals: [.milliseconds(200)])
            connection.authenticatedCallsign = "N0TEST"
            connection.setBackgroundMuted(true)
            connection.resolveProxySession = { try await directory.prepareProxySession(callsign: $0) }
            await connection.connect(to: Station(callsign: "TEST-R", ipAddress: "198.51.100.10"))
            XCTAssertEqual(connection.session?.state, .connected)

            let refreshed = await directory.refresh()
            XCTAssertTrue(refreshed)
            let usable = await shared.isUsable()
            XCTAssertTrue(usable, "A framed directory close must not close the shared UDP tunnel")
            XCTAssertEqual(connection.session?.state, .connected)
            XCTAssertNil(connection.error)
            XCTAssertEqual(proxy.authenticatedConnectionCount, 1, "Keep the proxy's existing voice endpoint")
            await connection.sendChat(message: "Still connected")
            for _ in 0..<100 where !connection.incomingChatMessages.contains(where: { !$0.isOutgoing }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(connection.incomingChatMessages.contains(where: { !$0.isOutgoing }),
                "Proxied incoming traffic must still flow after directory recovery")
            var voicePackets = 0
            connection.onAuditIncomingDatagram = { _ in voicePackets += 1 }
            let payload = try XCTUnwrap(GSMCodec.stripHeader(GSMCodec().encode(
                [Int16](repeating: 0, count: 640))))
            let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(gsmPayload: payload, sequence: 1)
            try await shared.sendAudio(packet, to: "198.51.100.10")
            for _ in 0..<100 where voicePackets == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(voicePackets, 1, "Voice packets must still cross the same proxy in both directions")
            connection.onAuditIncomingDatagram = nil
            await connection.disconnect()
            await directory.logout()
            await directory.closeProxySession()
            proxy.stop()
        }
    }

    func testLoginReplacesPublicProxyThatCannotReachTheDirectory() async throws {
        let broken = try RefreshTestProxy(behavior: .rejectDirectoryOpen)
        let healthy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await broken.start()
        try await healthy.start()
        defer { broken.stop(); healthy.stop() }
        let preference = EchoLinkProxyConfiguration(mode: .publicProxy, host: "", port: 8100, password: "PUBLIC")
        let candidates = [broken, healthy].map {
            EchoLinkProxyConfiguration(mode: .publicProxy, host: "127.0.0.1", port: $0.port, password: "PUBLIC")
        }
        let store = EchoLinkProxySessionStore(configurationProvider: { preference }, resolveCandidates: { _ in candidates })
        let service = EchoLinkDirectoryService(proxySessionStore: store, configurationProvider: { preference },
            client: DirectoryClient(host: "127.0.0.1"), saveCredentials: { _, _, _ in true })
        await service.login(callsign: "N0TEST", password: "directory-password")
        XCTAssertTrue(service.isLoggedIn, "A ready proxy can fail to reach the directory; try the next endpoint")
        XCTAssertEqual(service.stations.first?.callsign, "K6FRESH-R")
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(healthy.authenticatedConnectionCount, 1)
        await service.logout()
        await store.close()
    }

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
        let third = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await first.start()
        try await second.start()
        try await third.start()
        defer { first.stop(); second.stop(); third.stop() }
        let preference = EchoLinkProxyConfiguration(mode: .publicProxy, host: "", port: 8100, password: "PUBLIC")
        let candidates = [first, second, third].map {
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
        await connection.connect(to: Station(callsign: "TEST-R", ipAddress: "198.51.100.10"))
        XCTAssertEqual(reports, 2)
        let thirdSession = try await service.prepareProxySession(callsign: "N0TEST")
        let thirdConfiguration = await thirdSession?.configuration
        XCTAssertEqual(thirdConfiguration?.port, third.port, "Repeated unanswered attempts must not cycle between the first two proxies")
        XCTAssertEqual(third.authenticatedConnectionCount, 1)
        XCTAssertEqual(third.registrationRequestCount, 1)
        if let thirdSession { await service.reportUnansweredProxyHandshake(thirdSession) }
        do {
            _ = try await service.prepareProxySession(callsign: "N0TEST")
            XCTFail("All three unanswered paths should have been excluded")
        } catch { }
        let afterExhaustion = try await service.prepareProxySession(callsign: "N0TEST")
        let afterExhaustionConfiguration = await afterExhaustion?.configuration
        XCTAssertEqual(afterExhaustionConfiguration?.port, first.port, "Candidate exhaustion must allow another explicit retry without signing in again")
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

final class RefreshTestProxy: @unchecked Sendable {
    enum Behavior {
        case delayFirstRefresh
        case dropFirstRefresh
        case rejectDirectoryOpen
        case closeFirstRefresh
        case rejectFirstRefreshOpen
        case stallFirstRefresh
        case stallRegistration
    }

    private let behavior: Behavior
    private let replyToControl: Bool
    private let acceptPeerControl: Bool
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
    private var directoryOpens = 0
    private var stalledRegistrationConnection: NWConnection?
    let registrationReceived = XCTestExpectation(description: "proxy registration reached local fixture")

    var port: UInt16 { listener.port!.rawValue }
    var refreshRequestCount: Int { queue.sync { max(0, stationRequests - 1) } }
    var registrationRequestCount: Int { queue.sync { registrations } }
    var authenticatedConnectionCount: Int { queue.sync { authentications } }

    init(behavior: Behavior, replyToControl: Bool = false, acceptPeerControl: Bool = false) throws {
        self.behavior = behavior
        self.replyToControl = replyToControl
        self.acceptPeerControl = acceptPeerControl
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

    func releaseRegistration() {
        queue.async { [weak self] in
            guard let self, let connection = self.stalledRegistrationConnection else { return }
            self.stalledRegistrationConnection = nil
            self.send(.tcpData, payload: Data("LOGIN-RESULT\nresult:success\n\n".utf8), on: connection)
        }
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
            directoryOpens += 1
            send(.tcpStatus, payload: (behavior == .rejectDirectoryOpen
                 || (behavior == .rejectFirstRefreshOpen && directoryOpens == 3))
                 ? Data([1, 0, 0, 0]) : Data(repeating: 0, count: 4), on: connection)
        case .tcpData:
            if message.payload.starts(with: Data("-LOGIN\n".utf8)) {
                registrations += 1
                if case .stallRegistration = behavior, stalledRegistrationConnection == nil {
                    stalledRegistrationConnection = connection
                    registrationReceived.fulfill()
                } else {
                    send(.tcpData, payload: Data("LOGIN-RESULT\nresult:success\n\n".utf8), on: connection)
                }
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
                    case .rejectDirectoryOpen:
                        break
                    case .closeFirstRefresh:
                        send(.tcpClose, payload: Data(), on: connection)
                    case .rejectFirstRefreshOpen:
                        sendStationList(on: connection)
                    case .stallFirstRefresh:
                        break
                    case .stallRegistration:
                        sendStationList(on: connection)
                    }
                } else {
                    sendStationList(on: connection)
                }
            }
        case .udpControl:
            if !receivedControl { receivedControl = true; controlReceived.fulfill() }
            if acceptPeerControl {
                let frame = try! EchoLinkProxyProtocol.encode(type: .udpControl,
                    remoteHost: message.remoteHost,
                    payload: EchoLinkControlPacketCodec.buildSDESPacket(callsign: "TEST-R"))
                connection.send(content: frame, completion: .idempotent)
            }
            if replyToControl {
                // A valid peer RR is deliberately not a handshake acceptance.
                let frame = try! EchoLinkProxyProtocol.encode(type: .udpControl,
                    remoteHost: message.remoteHost, payload: Data([0x80, 201, 0, 1, 0, 0, 0, 1]))
                connection.send(content: frame, completion: .idempotent)
            }
        case .udpData:
            if acceptPeerControl {
                let frame = try! EchoLinkProxyProtocol.encode(type: .udpData,
                    remoteHost: message.remoteHost, payload: message.payload)
                connection.send(content: frame, completion: .idempotent)
            }
        case .tcpClose, .tcpStatus, .system:
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
