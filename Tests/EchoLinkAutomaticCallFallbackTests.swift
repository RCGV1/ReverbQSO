// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

@MainActor
final class EchoLinkAutomaticCallFallbackTests: XCTestCase {
    func testCancelledRelayFallbackCleanupCannotEraseReplacementRelayRegistration() async throws {
        let oldRelay = try BoundUDPSocket(localPort: 0)
        let replacementRelay = try BoundUDPSocket(localPort: 0)
        defer { oldRelay.close(); replacementRelay.close() }

        let preference = EchoLinkProxyConfiguration(
            mode: .automatic, host: "", port: 8100, password: "PUBLIC"
        )
        let relaySelection = EchoLinkEffectiveTransport(
            preference: preference,
            configuration: .init(mode: .relay, host: "", port: 8100, password: ""),
            relayAddress: "127.0.0.1"
        )
        var relayFactoryCalls = 0
        let service = EchoLinkConnectionService(
            selectedRelayClientFactory: { address in
                relayFactoryCalls += 1
                return EchoLinkRelayClient(
                    host: address,
                    port: relayFactoryCalls == 1
                        ? oldRelay.actualLocalPort : replacementRelay.actualLocalPort,
                    resolvedIPv4Candidates: [address]
                )
            },
            networkConfigurationProvider: { preference },
            handshakeRetryIntervals: [.milliseconds(20)]
        )
        service.authenticatedCallsign = "N0TEST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        service.setBackgroundMuted(true)
        service.effectiveTransportProvider = { relaySelection }
        service.prepareRelayDirectory = { _, _ in }
        service.prepareAutomaticPublicProxyFallback = { _ in nil }

        let cleanupStarted = expectation(description: "old Relay directory cleanup suspended")
        let replacementRegistrationFinished = expectation(description: "replacement Relay registration cleaned up")
        let cleanupGate = AutomaticFallbackCleanupGate()
        var cleanupCalls = 0
        service.finishRelayDirectory = { _, _ in
            cleanupCalls += 1
            if cleanupCalls == 1 {
                cleanupStarted.fulfill()
                await cleanupGate.wait()
            } else {
                replacementRegistrationFinished.fulfill()
            }
        }
        let oldRelayServer = Task {
            let registration = try await oldRelay.receive()
            try await oldRelay.send(
                Data([EchoLinkRelayResponseType.ack.rawValue, 0, 0, 0, 0, 0, 0, 0, 0]),
                to: registration.sourceHost, port: registration.sourcePort
            )
            _ = try await oldRelay.receive() // Peer SDES; deliberately unanswered.
        }
        let replacementRelayServer = Task {
            let registration = try await replacementRelay.receive()
            try await replacementRelay.send(
                Data([EchoLinkRelayResponseType.ack.rawValue, 0, 0, 0, 0, 0, 0, 0, 0]),
                to: registration.sourceHost, port: registration.sourcePort
            )
            let request = try await replacementRelay.receive()
            let sdes = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "NEW-R")
            try await replacementRelay.send(
                Data([1, 198, 51, 100, 11, 0, 0, 0x14, 0x4F]) + sdes,
                to: request.sourceHost, port: request.sourcePort
            )
        }
        let oldAttempt = Task {
            await service.connect(to: Station(callsign: "OLD-R", ipAddress: "198.51.100.10"))
        }
        await fulfillment(of: [cleanupStarted], timeout: 3)

        service.cancelPendingConnection()
        let replacement = Task {
            await service.connect(to: Station(callsign: "NEW-R", ipAddress: "198.51.100.11"))
        }
        for _ in 0..<200 where service.session?.state != .connected {
            try await Task.sleep(for: .milliseconds(5))
        }
        let replacementSessionID = service.session?.id
        XCTAssertEqual(service.session?.station.callsign, "NEW-R")
        XCTAssertEqual(service.session?.state, .connected)

        await cleanupGate.open()
        await oldAttempt.value
        await replacement.value
        try await oldRelayServer.value
        try await replacementRelayServer.value
        XCTAssertEqual(service.session?.id, replacementSessionID)
        XCTAssertEqual(service.session?.station.callsign, "NEW-R")
        XCTAssertEqual(service.session?.state, .connected)
        await service.disconnect()
        await fulfillment(of: [replacementRegistrationFinished], timeout: 1)
        XCTAssertEqual(cleanupCalls, 2)
    }

    func testAutomaticDirectBindConflictFallsBackOnceToLocalPublicProxy() async throws {
        let occupiedAudioPort = try BoundUDPSocket(localPort: 5198)
        defer { occupiedAudioPort.close() }
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh, acceptPeerControl: true)
        try await proxy.start()
        defer { proxy.stop() }

        let preference = EchoLinkProxyConfiguration(
            mode: .automatic, host: "127.0.0.1", port: proxy.port, password: "PUBLIC"
        )
        let directSelection = EchoLinkEffectiveTransport(
            preference: preference,
            configuration: .init(mode: .direct, host: "", port: 8100, password: ""),
            relayAddress: nil
        )
        let proxyConfiguration = EchoLinkProxyConfiguration(
            mode: .publicProxy, host: "127.0.0.1", port: proxy.port, password: "PUBLIC"
        )
        let proxySelection = EchoLinkEffectiveTransport(
            preference: preference, configuration: proxyConfiguration, relayAddress: nil
        )
        let proxySession = try await EchoLinkProxySession.connect(
            configurations: [proxyConfiguration], callsign: "N0TEST"
        )
        defer { Task { await proxySession.close() } }

        let service = EchoLinkConnectionService(
            networkConfigurationProvider: { preference },
            handshakeRetryIntervals: [.milliseconds(50)]
        )
        service.authenticatedCallsign = "N0TEST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        service.setBackgroundMuted(true)
        service.effectiveTransportProvider = { directSelection }
        var fallbackRequests = 0
        service.prepareAutomaticPublicProxyFallback = { _ in
            fallbackRequests += 1
            return proxySelection
        }
        service.resolveProxySession = { _ in proxySession }

        await service.connect(to: Station(callsign: "TEST-R", ipAddress: "198.51.100.10"))

        XCTAssertEqual(fallbackRequests, 1)
        XCTAssertEqual(service.session?.state, .connected)
        XCTAssertNil(service.error)
        await service.disconnect()
    }

    func testAutomaticRelayRegistrationTimeoutFallsBackOnceToLocalPublicProxy() async throws {
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh, acceptPeerControl: true)
        try await proxy.start()
        defer { proxy.stop() }

        let preference = EchoLinkProxyConfiguration(
            mode: .automatic, host: "127.0.0.1", port: proxy.port, password: "PUBLIC"
        )
        let relaySelection = EchoLinkEffectiveTransport(
            preference: preference,
            configuration: .init(mode: .relay, host: "", port: 8100, password: ""),
            relayAddress: "127.0.0.1"
        )
        let proxyConfiguration = EchoLinkProxyConfiguration(
            mode: .publicProxy, host: "127.0.0.1", port: proxy.port, password: "PUBLIC"
        )
        let proxySelection = EchoLinkEffectiveTransport(
            preference: preference, configuration: proxyConfiguration, relayAddress: nil
        )
        let proxySession = try await EchoLinkProxySession.connect(
            configurations: [proxyConfiguration], callsign: "N0TEST"
        )
        defer { Task { await proxySession.close() } }

        let unusedRelay = try BoundUDPSocket(localPort: 0)
        let unusedRelayPort = unusedRelay.actualLocalPort
        unusedRelay.close()
        let timing = EchoLinkRelayTiming(
            ackTimeout: .milliseconds(10), registrationAttempts: 1,
            keepaliveInterval: .seconds(20), registrationInterval: .seconds(20)
        )
        let service = EchoLinkConnectionService(
            selectedRelayClientFactory: { address in
                EchoLinkRelayClient(
                    host: address, port: unusedRelayPort, timing: timing,
                    resolvedIPv4Candidates: [address]
                )
            },
            networkConfigurationProvider: { preference },
            handshakeRetryIntervals: [.milliseconds(50)]
        )
        service.authenticatedCallsign = "N0TEST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        service.setBackgroundMuted(true)
        service.effectiveTransportProvider = { relaySelection }
        var fallbackRequests = 0
        service.prepareAutomaticPublicProxyFallback = { _ in
            fallbackRequests += 1
            return proxySelection
        }
        service.resolveProxySession = { _ in proxySession }

        await service.connect(to: Station(callsign: "TEST-R", ipAddress: "198.51.100.10"))

        XCTAssertEqual(fallbackRequests, 1)
        XCTAssertEqual(service.session?.state, .connected)
        XCTAssertNil(service.error)
        await service.disconnect()
    }
}

private actor AutomaticFallbackCleanupGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
