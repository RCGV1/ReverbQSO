// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class EchoLinkAutomaticTransportTests: XCTestCase {
    private let preference = EchoLinkProxyConfiguration(mode: .automatic, host: "preferred.example", port: 8100, password: "PUBLIC")

    func testCallFallbackIsBoundedToUnansweredAutomaticDirectOrRelayHandshake() {
        let timeout = ConnectionError.handshakeTimedOut
        for mode in [EchoLinkNetworkMode.direct, .relay] {
            XCTAssertTrue(AutomaticCallFallbackPolicy.shouldAttempt(
                preference: preference,
                failedMode: mode,
                error: timeout,
                peerDatagramCount: 0,
                alreadyAttempted: false
            ))
            XCTAssertFalse(AutomaticCallFallbackPolicy.shouldAttempt(
                preference: preference,
                failedMode: mode,
                error: timeout,
                peerDatagramCount: 0,
                alreadyAttempted: true
            ))
            XCTAssertFalse(AutomaticCallFallbackPolicy.shouldAttempt(
                preference: preference,
                failedMode: mode,
                error: timeout,
                peerDatagramCount: 1,
                alreadyAttempted: false
            ))
        }
    }

    func testCallFallbackPreservesExplicitPreferencesAndDenials() {
        for mode in EchoLinkNetworkMode.allCases where mode != .automatic {
            let explicit = EchoLinkProxyConfiguration(mode: mode, host: "preferred.example", port: 8100, password: "PUBLIC")
            XCTAssertFalse(AutomaticCallFallbackPolicy.shouldAttempt(
                preference: explicit,
                failedMode: .direct,
                error: ConnectionError.handshakeTimedOut,
                peerDatagramCount: 0,
                alreadyAttempted: false
            ))
        }
        XCTAssertFalse(AutomaticCallFallbackPolicy.shouldAttempt(
            preference: preference,
            failedMode: .direct,
            error: ConnectionError.connectionFailed("Access denied"),
            peerDatagramCount: 0,
            alreadyAttempted: false
        ))
        XCTAssertFalse(AutomaticCallFallbackPolicy.shouldAttempt(
            preference: preference,
            failedMode: .publicProxy,
            error: ConnectionError.handshakeTimedOut,
            peerDatagramCount: 0,
            alreadyAttempted: false
        ))
    }

    func testCallBootstrapFallbackAllowsOnlyAutomaticReachabilityFailures() {
        let allowed: [Error] = [
            EchoLinkRelayClientError.registrationTimedOut,
            EchoLinkRelayClientError.resolutionFailed,
            BoundUDPSocket.SocketError.systemCall(operation: "bind", code: EADDRINUSE)
        ]
        for error in allowed {
            XCTAssertTrue(AutomaticCallFallbackPolicy.shouldAttemptBootstrap(
                preference: preference,
                failedMode: error is EchoLinkRelayClientError ? .relay : .direct,
                error: error,
                alreadyAttempted: false
            ))
        }

        let rejected: [Error] = [
            EchoLinkRelayClientError.registrationRejected,
            BoundUDPSocket.SocketError.systemCall(operation: "bind", code: EACCES),
            BoundUDPSocket.SocketError.invalidHost("bad"),
            ConnectionError.connectionFailed("Access denied"),
            CancellationError()
        ]
        for error in rejected {
            XCTAssertFalse(AutomaticCallFallbackPolicy.shouldAttemptBootstrap(
                preference: preference,
                failedMode: .relay,
                error: error,
                alreadyAttempted: false
            ))
        }
        XCTAssertFalse(AutomaticCallFallbackPolicy.shouldAttemptBootstrap(
            preference: preference,
            failedMode: .relay,
            error: EchoLinkRelayClientError.registrationTimedOut,
            alreadyAttempted: true
        ))
    }

    func testGlobalAddressSelectsDirectWithoutDiscovery() async throws {
        for address in ["8.8.8.8", "1.1.1.1"] {
            let selector = EchoLinkAutomaticTransportSelector(
                localAddresses: { [address] },
                discoverRelays: { XCTFail("Global address must skip relay discovery"); return [] }
            )
            let selection = try await selector.select(preference)
            XCTAssertEqual(selection.configuration.mode, .direct)
            XCTAssertEqual(selection.preference, preference)
            XCTAssertNil(selection.relayAddress)
        }
    }

    func testGlobalIPv6WithoutPublicIPv4StillProbesRelay() async throws {
        let selector = EchoLinkAutomaticTransportSelector(
            localAddresses: { ["2001:4860:4860::8888", "192.168.1.2"] },
            discoverRelays: { ["198.51.100.7"] }
        )
        let selection = try await selector.select(preference)
        XCTAssertEqual(selection.configuration.mode, .relay)
        XCTAssertEqual(selection.relayAddress, "198.51.100.7")
    }

    func testPrivateAddressesSelectOnlyRespondingRelay() async throws {
        let selector = EchoLinkAutomaticTransportSelector(
            localAddresses: { ["127.0.0.1", "10.0.0.1", "fd00::1", "fe80::1"] },
            discoverRelays: { ["198.51.100.7", "198.51.100.8"] },
            chooseRelay: { $0.last }
        )
        let selection = try await selector.select(preference)
        XCTAssertEqual(selection.configuration.mode, .relay)
        XCTAssertEqual(selection.relayAddress, "198.51.100.8")
        XCTAssertEqual(selection.preference.mode, .automatic)
    }

    func testNoRepliesOrDNSFailureSelectPublicProxy() async throws {
        for shouldFail in [false, true] {
            let selector = EchoLinkAutomaticTransportSelector(
                localAddresses: { ["192.168.1.2", "::1"] },
                discoverRelays: { if shouldFail { throw URLError(.cannotFindHost) }; return [] }
            )
            let selection = try await selector.select(preference)
            XCTAssertEqual(selection.configuration.mode, .publicProxy)
            XCTAssertEqual(selection.configuration.host, preference.host)
            XCTAssertEqual(selection.configuration.password, "PUBLIC")
            XCTAssertEqual(selection.preference.mode, .automatic)
        }
    }

    func testDiscoveryCancellationDoesNotBecomeProxyFallback() async {
        let selector = EchoLinkAutomaticTransportSelector(localAddresses: { [] }, discoverRelays: { throw CancellationError() })
        do {
            _ = try await selector.select(preference)
            XCTFail("Cancellation must abort selection")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testExplicitModesDoNotProbeOrChangeConfiguration() async throws {
        for mode in [EchoLinkNetworkMode.direct, .relay, .publicProxy, .customProxy] {
            let preference = EchoLinkProxyConfiguration(mode: mode, host: "192.0.2.1", port: 8123, password: "test")
            let selector = EchoLinkAutomaticTransportSelector(localAddresses: { XCTFail("Explicit mode must skip discovery"); return [] })
            let selection = try await selector.select(preference)
            XCTAssertEqual(selection.configuration, preference)
        }
    }

    func testPrivateLoopbackAndReservedAddressesAreNotGlobal() {
        for address in ["0.0.0.0", "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.1.1", "100.64.0.1", "224.0.0.1", "192.0.2.1", "::1", "::", "fd00::1", "fec0::1", "fe80::1%en0", "ff02::1", "2001:db8::1"] {
            XCTAssertFalse(EchoLinkAutomaticTransportSelector.isGlobalDirectIPv4Address(address), address)
        }
    }

    func testDiscoveryWireAndIPv6ResponderAdvertisement() {
        XCTAssertEqual(EchoLinkRelayProtocol.discoveryPing, Data([6, 0, 0, 0, 0, 0, 0, 0, 0]))
        let reply = Data([3, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(EchoLinkRelayProtocol.discoveryRelayAddress(reply, responder: "198.51.100.7"), "198.51.100.7")
        XCTAssertEqual(EchoLinkRelayProtocol.discoveryRelayAddress(reply + Data("ipv4:198.51.100.7\r\n".utf8), responder: "2001:db8::1"), "198.51.100.7")
        XCTAssertNil(EchoLinkRelayProtocol.discoveryRelayAddress(reply, responder: "2001:db8::1"))
        XCTAssertNil(EchoLinkRelayProtocol.discoveryRelayAddress(Data([3]), responder: "198.51.100.7"))
        XCTAssertNil(EchoLinkRelayProtocol.discoveryRelayAddress(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]), responder: "198.51.100.7"))
        XCTAssertNil(EchoLinkRelayProtocol.discoveryRelayAddress(reply + Data("ipv4:not-an-address\r\n".utf8), responder: "2001:db8::1"))
    }

    func testRealDiscoveryAcceptsLocalPingReplyAndHasOneDeadline() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let server = Task {
            let request = try await relay.receive()
            XCTAssertEqual(request.data, EchoLinkRelayProtocol.discoveryPing)
            try await relay.send(Data([3, 0, 0, 0, 0, 0, 0, 0, 0]), to: request.sourceHost, port: request.sourcePort)
        }
        let discovery = EchoLinkRelayDiscovery(timeout: 0.15, port: relay.actualLocalPort, resolve: { ["127.0.0.1"] })
        let started = ContinuousClock.now
        let responders = try await discovery.run()
        XCTAssertEqual(responders, ["127.0.0.1"])
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        try await server.value
    }

    func testDiscoveryTimeoutAndCancellationDoNotWaitForBlockedDNS() async throws {
        let discovery = EchoLinkRelayDiscovery(timeout: 0.03, resolve: { Thread.sleep(forTimeInterval: 0.3); return [] })
        let started = ContinuousClock.now
        let responders = try await discovery.run()
        XCTAssertTrue(responders.isEmpty)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(250))
        let cancelled = Task { try await EchoLinkRelayDiscovery(resolve: { Thread.sleep(forTimeInterval: 0.3); return [] }).run() }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation must abort discovery") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAutomaticPreferenceLoadsPublicProxyPreferenceWithoutReplacingMode() throws {
        let name = "automatic-transport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("automatic", forKey: EchoLinkProxyConfiguration.modeKey)
        defaults.set("preferred.example", forKey: EchoLinkProxyConfiguration.publicHostKey)
        defaults.set(8123, forKey: EchoLinkProxyConfiguration.publicPortKey)
        let loaded = EchoLinkProxyConfiguration.load(defaults: defaults)
        XCTAssertEqual(loaded.mode, .automatic)
        XCTAssertEqual(loaded.host, "preferred.example")
        XCTAssertEqual(loaded.port, 8123)
        XCTAssertEqual(loaded.password, "PUBLIC")
        XCTAssertEqual(defaults.string(forKey: EchoLinkProxyConfiguration.modeKey), "automatic")
    }
}
