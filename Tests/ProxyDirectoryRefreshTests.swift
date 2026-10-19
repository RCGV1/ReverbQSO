// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import XCTest
@testable import ReverbQSO

@MainActor
final class ProxyDirectoryRefreshTests: XCTestCase {
    func testProxyConsumerReleaseBeforeFirstReadDoesNotNeedIteratorCancellation() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let (directory, _) = makeService(proxy: proxy)
        await directory.login(callsign: "N0TEST", password: "directory-password")
        let prepared = try await directory.prepareProxySession(callsign: "N0TEST")
        let session = try XCTUnwrap(prepared)
        let consumerID = UUID()
        let stream = await session.udpMessages(consumerID: consumerID)
        let activeBeforeRelease = await session.hasActiveVoiceConsumer()
        XCTAssertTrue(activeBeforeRelease)

        // The connection may finish before AsyncThrowingStream calls buffer.next().
        await session.releaseUDPConsumer(consumerID)
        let activeAfterRelease = await session.hasActiveVoiceConsumer()
        XCTAssertFalse(activeAfterRelease)
        withExtendedLifetime(stream) {}
        await directory.logout()
        await directory.closeProxySession()
    }

    func testProxyConsumerStaleCompletionCannotReleaseReplacementStream() async throws {
        let proxy = try RefreshTestProxy(behavior: .stallFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let (directory, _) = makeService(proxy: proxy)
        await directory.login(callsign: "N0TEST", password: "directory-password")
        let prepared = try await directory.prepareProxySession(callsign: "N0TEST")
        let session = try XCTUnwrap(prepared)
        let previousID = UUID(), replacementID = UUID()
        let previous = await session.udpMessages(consumerID: previousID)
        let replacement = await session.udpMessages(consumerID: replacementID)
        do {
            _ = try await session.serializedDirectoryRequest(Data("s".utf8), host: "127.0.0.1",
                boundary: .marker(Data("+++".utf8)), timeout: .milliseconds(50))
            XCTFail("The local directory intentionally stalls")
        } catch { }
        let recovered = expectation(description: "matching consumer completion releases recovery once")
        recovered.assertForOverFulfill = true
        await session.recoverDirectoryWhenVoiceEnds { recovered.fulfill() }

        await session.releaseUDPConsumer(previousID)
        let replacementStillActive = await session.hasActiveVoiceConsumer()
        XCTAssertTrue(replacementStillActive)
        await session.releaseUDPConsumer(replacementID)
        await session.releaseUDPConsumer(replacementID)
        let activeAfterCompletion = await session.hasActiveVoiceConsumer()
        XCTAssertFalse(activeAfterCompletion)
        await fulfillment(of: [recovered], timeout: 1)
        withExtendedLifetime((previous, replacement)) {}
        await directory.logout()
        await directory.closeProxySession()
    }

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

    func testProxyCountedDirectoryWaitsPastDescriptionMarkersAndSplitTerminator() async throws {
        let chunks = ["@@@\r\n2\r\nK6FIRST-R\r\nCafé +++ road\r\n",
                      "123\r\n192.0.2.1\r\nK6LAST-L\r\n+++\r\n456\r\n192.0.2.2\r\n+", "+", "+"]
            .map { $0.data(using: .isoLatin1)! }
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh, directoryChunks: chunks)
        try await proxy.start()
        defer { proxy.stop() }
        let configuration = EchoLinkProxyConfiguration(mode: .customProxy, host: "127.0.0.1",
                                                       port: proxy.port, password: "proxy-password")
        let session = try await EchoLinkProxySession.connect(configurations: [configuration], callsign: "N0TEST")
        let response = try await session.directoryRequest(Data("s".utf8), host: "127.0.0.1",
            boundary: .marker(Data("+++".utf8)), timeout: .seconds(2))
        XCTAssertEqual(response, chunks.reduce(Data(), +))
        XCTAssertEqual(StationParser.parseDirectory(raw: response).map(\.callsign), ["K6FIRST-R", "K6LAST-L"])
        await session.close()
    }

    func testProxyCountedDirectoryCloseRejectsIncompleteAdvertisedCount() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh, directoryChunks: [
            Data("@@@\n2\nK6PART-R\nOnly one station\n123\n192.0.2.1\n+++".utf8)
        ], closeDirectoryAfterResponse: true)
        try await proxy.start()
        defer { proxy.stop() }
        let configuration = EchoLinkProxyConfiguration(mode: .customProxy, host: "127.0.0.1",
                                                       port: proxy.port, password: "proxy-password")
        let session = try await EchoLinkProxySession.connect(configurations: [configuration], callsign: "N0TEST")
        do {
            _ = try await session.directoryRequest(Data("s".utf8), host: "127.0.0.1",
                boundary: .marker(Data("+++".utf8)), timeout: .seconds(2))
            XCTFail("A proxy directory close cannot commit an incomplete counted response")
        } catch { }
        await session.close()
    }

    func testProxyCountedDirectoryRejectsOversizedIncompleteResponse() async throws {
        let prefix = Data("@@@\n2\nK6PART-R\nOne station\n123\n192.0.2.1\nK6NEXT-R\n".utf8)
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh,
            directoryChunks: [prefix] + Array(repeating: Data(repeating: 65, count: 5_000), count: 801),
            closeDirectoryAfterResponse: true, directoryChunkInterval: 0.001)
        try await proxy.start()
        defer { proxy.stop() }
        let configuration = EchoLinkProxyConfiguration(mode: .customProxy, host: "127.0.0.1",
                                                       port: proxy.port, password: "proxy-password")
        let session = try await EchoLinkProxySession.connect(configurations: [configuration], callsign: "N0TEST")
        do {
            _ = try await session.directoryRequest(Data("s".utf8), host: "127.0.0.1",
                boundary: .marker(Data("+++".utf8)), timeout: .seconds(5))
            XCTFail("The proxy response limit must reject an incomplete directory")
        } catch DirectoryClientError.unexpectedResponse { }
        await session.close()
    }

    func testProxyDirectoryDescriptionsCannotLogOutAnAuthenticatedAccount() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh, directoryChunks: [
            Data("@@@\n3\nK6FIRST-R\nDENIED access road\n123\n192.0.2.1\nK6NEXT-R\nINCORRECT PASSWORD help\n456\n192.0.2.2\nK6LAST-L\nIN-USE antenna\n789\n192.0.2.3\n+++".utf8)
        ])
        try await proxy.start()
        defer { proxy.stop() }
        let (service, _) = makeService(proxy: proxy)
        await service.login(callsign: "N0TEST", password: "directory-password")
        XCTAssertTrue(service.isLoggedIn, service.error?.localizedDescription ?? "")
        XCTAssertEqual(service.stations.map(\.callsign), ["K6FIRST-R", "K6NEXT-R", "K6LAST-L"])
        XCTAssertNil(service.error)
        await service.logout()
        await service.closeProxySession()
    }

    func testDirectoryResolutionDoesNotBlockIncomingProxyVoice() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let resolver = SuspendedProxyDirectoryResolver()
        defer { resolver.release() }
        let session = try await makeResolvingSession(proxy: proxy, resolver: resolver)
        let stream = await session.udpMessages()
        let received = expectation(description: "proxy UDP voice delivered during directory resolution")
        let payload = try XCTUnwrap(GSMCodec.stripHeader(GSMCodec().encode([Int16](repeating: 0, count: 640))))
        let receive = Task {
            var iterator = stream.makeAsyncIterator()
            let message = try await iterator.next()
            XCTAssertEqual(message?.payload, payload)
            received.fulfill()
        }
        defer { receive.cancel() }
        let request = Task {
            try await session.serializedDirectoryRequest(Data("s".utf8), host: "directory.invalid",
                boundary: .marker(Data("+++".utf8)), timeout: .seconds(2))
        }
        await fulfillment(of: [resolver.entered], timeout: 1)
        proxy.sendVoiceToClients(payload)
        await fulfillment(of: [received], timeout: 0.5)
        resolver.release()
        _ = try await request.value
        try await receive.value
        await session.close()
    }

    func testDirectoryResolutionTimeoutKeepsVoiceTunnelAndDoesNotOpenLate() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let resolver = SuspendedProxyDirectoryResolver()
        defer { resolver.release() }
        let session = try await makeResolvingSession(proxy: proxy, resolver: resolver,
                                                      resolutionTimeout: .milliseconds(50))
        let completed = expectation(description: "directory resolution times out while resolver remains suspended")
        let request = Task { () -> Error? in
            defer { completed.fulfill() }
            do {
                _ = try await session.serializedDirectoryRequest(Data("s".utf8), host: "directory.invalid",
                    boundary: .marker(Data("+++".utf8)), timeout: .seconds(2))
                return nil
            } catch { return error }
        }
        await fulfillment(of: [resolver.entered], timeout: 1)
        await fulfillment(of: [completed], timeout: 0.5)
        resolver.release()
        let error = await request.value
        guard let error, case EchoLinkProxySession.SessionError.timedOut = error else {
            await session.close()
            return XCTFail("Expected resolution timeout, got \(String(describing: error))")
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(proxy.directoryOpenCount, 0, "A late lookup result must not send TCP_OPEN")
        let usable = await session.isUsable()
        XCTAssertTrue(usable, "A lookup timeout must preserve the authenticated UDP tunnel")
        await assertVoiceArrives(session: session, proxy: proxy)
        await session.close()
    }

    func testCancellingDirectoryResolutionKeepsVoiceTunnelAndDoesNotOpenLate() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let resolver = SuspendedProxyDirectoryResolver()
        defer { resolver.release() }
        let session = try await makeResolvingSession(proxy: proxy, resolver: resolver)
        let completed = expectation(description: "directory resolution cancels while resolver remains suspended")
        let request = Task { () -> Error? in
            defer { completed.fulfill() }
            do {
                _ = try await session.serializedDirectoryRequest(Data("s".utf8), host: "directory.invalid",
                    boundary: .marker(Data("+++".utf8)), timeout: .seconds(2))
                return nil
            } catch { return error }
        }
        await fulfillment(of: [resolver.entered], timeout: 1)
        request.cancel()
        await fulfillment(of: [completed], timeout: 0.5)
        resolver.release()
        let cancellation = await request.value
        XCTAssertTrue(cancellation is CancellationError)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(proxy.directoryOpenCount, 0)
        let usable = await session.isUsable()
        XCTAssertTrue(usable, "Cancelling DNS must preserve the shared UDP tunnel")
        await assertVoiceArrives(session: session, proxy: proxy)
        await session.close()
    }

    func testClosingProxyDuringDirectoryResolutionCannotOpenLate() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let resolver = SuspendedProxyDirectoryResolver()
        defer { resolver.release() }
        let session = try await makeResolvingSession(proxy: proxy, resolver: resolver)
        let request = Task { () -> Error? in
            do {
                _ = try await session.serializedDirectoryRequest(Data("s".utf8), host: "directory.invalid",
                    boundary: .marker(Data("+++".utf8)), timeout: .seconds(2))
                return nil
            } catch { return error }
        }
        await fulfillment(of: [resolver.entered], timeout: 1)
        let closed = expectation(description: "proxy close completes during a suspended directory lookup")
        let close = Task { await session.close(); closed.fulfill() }
        await fulfillment(of: [closed], timeout: 0.5)
        resolver.release()
        await close.value
        let error = await request.value
        XCTAssertNotNil(error)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(proxy.directoryOpenCount, 0)
    }

    private func makeResolvingSession(proxy: RefreshTestProxy, resolver: SuspendedProxyDirectoryResolver,
                                      resolutionTimeout: Duration = .seconds(2)) async throws -> EchoLinkProxySession {
        let configuration = EchoLinkProxyConfiguration(mode: .customProxy, host: "127.0.0.1",
                                                       port: proxy.port, password: "proxy-password")
        return try await EchoLinkProxySession.connect(configurations: [configuration], callsign: "N0TEST",
            directoryResolutionTimeout: resolutionTimeout, directoryResolver: { try resolver.resolve($0) })
    }

    private func assertVoiceArrives(session: EchoLinkProxySession, proxy: RefreshTestProxy) async {
        let stream = await session.udpMessages()
        let received = expectation(description: "authenticated proxy UDP still works")
        let receive = Task {
            var iterator = stream.makeAsyncIterator()
            do {
                let packet = try await iterator.next()
                XCTAssertEqual(packet?.type, .udpData)
                received.fulfill()
            } catch { XCTFail("UDP tunnel failed: \(error)") }
        }
        defer { receive.cancel() }
        let payload = GSMCodec.stripHeader(GSMCodec().encode([Int16](repeating: 0, count: 640)))!
        proxy.sendVoiceToClients(payload)
        await fulfillment(of: [received], timeout: 0.5)
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
    private let directoryChunks: [Data]?
    private let closeDirectoryAfterResponse: Bool
    private let directoryChunkInterval: TimeInterval
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
    var directoryOpenCount: Int { queue.sync { directoryOpens } }

    init(behavior: Behavior, replyToControl: Bool = false, acceptPeerControl: Bool = false,
         directoryChunks: [Data]? = nil, closeDirectoryAfterResponse: Bool = false,
         directoryChunkInterval: TimeInterval = 0.04) throws {
        self.behavior = behavior
        self.directoryChunks = directoryChunks
        self.closeDirectoryAfterResponse = closeDirectoryAfterResponse
        self.directoryChunkInterval = directoryChunkInterval
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

    func sendVoiceToClients(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections { self.send(.udpData, payload: payload, on: connection) }
        }
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
        if let directoryChunks {
            sendDirectoryChunk(directoryChunks, index: 0, on: connection)
            return
        }
        let payload = Data("@@@\n1\nK6FRESH-R\nRefresh Test\n12345\n192.0.2.25\n+++\n".utf8)
        send(.tcpData, payload: payload, on: connection)
    }

    private func sendDirectoryChunk(_ chunks: [Data], index: Int, on connection: NWConnection) {
        guard index < chunks.count else {
            if closeDirectoryAfterResponse { send(.tcpClose, payload: Data(), on: connection) }
            return
        }
        send(.tcpData, payload: chunks[index], on: connection)
        queue.asyncAfter(deadline: .now() + directoryChunkInterval) { [weak self] in
            self?.sendDirectoryChunk(chunks, index: index + 1, on: connection)
        }
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

private final class SuspendedProxyDirectoryResolver: @unchecked Sendable {
    let entered = XCTestExpectation(description: "injected directory resolver started")
    private let gate = DispatchSemaphore(value: 0)

    func resolve(_ host: String) throws -> String {
        entered.fulfill()
        gate.wait()
        return "127.0.0.1"
    }

    func release() { gate.signal() }
}
