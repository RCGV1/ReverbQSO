// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import XCTest
@testable import ReverbQSO

@MainActor
final class EchoLinkAutomaticDirectoryTests: XCTestCase {
    func testAutomaticFallbackRegistersProxyUsingCurrentAccountWithoutKeychainReload() async throws {
        let server = try LocalAutomaticDirectory()
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let automatic = EchoLinkProxyConfiguration(mode: .automatic, host: "preferred.example", port: 8123, password: "PUBLIC")
        let candidate = EchoLinkProxyConfiguration(mode: .publicProxy, host: "127.0.0.1", port: proxy.port, password: "PUBLIC")
        var requestedFallback: EchoLinkProxyConfiguration?
        let store = EchoLinkProxySessionStore(configurationProvider: { automatic }, resolveCandidates: {
            requestedFallback = $0
            return [candidate]
        })
        let directory = EchoLinkDirectoryService(proxySessionStore: store,
            transportSelector: EchoLinkAutomaticTransportSelector(localAddresses: { ["8.8.8.8"] }),
            configurationProvider: { automatic }, client: DirectoryClient(host: "127.0.0.1", port: port),
            saveCredentials: { _, _, _ in true })
        await directory.login(callsign: "N0TEST", password: "test-only-password")
        XCTAssertTrue(directory.isLoggedIn)
        XCTAssertEqual(directory.effectiveTransport?.configuration.mode, .direct)
        let fallback = try await directory.prepareAutomaticPublicProxyFallback(callsign: "N0TEST")
        XCTAssertEqual(fallback?.configuration.mode, .publicProxy)
        XCTAssertEqual(requestedFallback?.host, "preferred.example")
        XCTAssertEqual(requestedFallback?.port, 8123)
        XCTAssertEqual(fallback?.configuration.host, "preferred.example")
        XCTAssertEqual(fallback?.configuration.port, 8123)
        XCTAssertEqual(fallback?.preference, automatic, "Do not rewrite the user's saved transport preference")
        XCTAssertEqual(directory.effectiveTransport, fallback)
        XCTAssertEqual(proxy.registrationRequestCount, 1, "Register the new source address before starting the QSO")
        let prepared = try await directory.prepareProxySession(callsign: "N0TEST")
        XCTAssertNotNil(prepared)
        XCTAssertEqual(proxy.authenticatedConnectionCount, 1)
        let repeated = try await directory.prepareAutomaticPublicProxyFallback(callsign: "N0TEST")
        XCTAssertEqual(repeated, fallback)
        XCTAssertEqual(proxy.registrationRequestCount, 1)
        await directory.logout()
        await directory.closeProxySession()
    }

    func testCancellingOnlyAutomaticFallbackWaiterAllowsFreshRetryWithoutOldCommit() async throws {
        let server = try LocalAutomaticDirectory()
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let directoryPort = try XCTUnwrap(server.listener.port?.rawValue)
        let proxy = try RefreshTestProxy(behavior: .delayFirstRefresh)
        try await proxy.start()
        defer { proxy.stop() }
        let automatic = EchoLinkProxyConfiguration(mode: .automatic, host: "preferred.example", port: 8123, password: "PUBLIC")
        let candidate = EchoLinkProxyConfiguration(mode: .publicProxy, host: "127.0.0.1", port: proxy.port, password: "PUBLIC")
        let resolverStarted = expectation(description: "fallback candidate resolution suspended")
        let gate = AutomaticFallbackResolverGate()
        var resolverCalls = 0
        let store = EchoLinkProxySessionStore(configurationProvider: { automatic }, resolveCandidates: { _ in
            resolverCalls += 1
            if resolverCalls == 1 { resolverStarted.fulfill() }
            await gate.wait()
            return [candidate]
        })
        let directory = EchoLinkDirectoryService(proxySessionStore: store,
            transportSelector: EchoLinkAutomaticTransportSelector(localAddresses: { ["8.8.8.8"] }),
            configurationProvider: { automatic }, client: DirectoryClient(host: "127.0.0.1", port: directoryPort),
            saveCredentials: { _, _, _ in true })
        await directory.login(callsign: "N0TEST", password: "test-only-password")
        XCTAssertEqual(directory.effectiveTransport?.configuration.mode, .direct)

        let fallback = Task { try await directory.prepareAutomaticPublicProxyFallback(callsign: "N0TEST") }
        await fulfillment(of: [resolverStarted], timeout: 2)
        fallback.cancel()
        let retry = Task { try await directory.prepareAutomaticPublicProxyFallback(callsign: "N0TEST") }
        XCTAssertEqual(directory.effectiveTransport?.configuration.mode, .direct)
        await gate.open()
        do {
            _ = try await fallback.value
            XCTFail("Cancelled sole waiter must not complete fallback")
        } catch { XCTAssertTrue(error is CancellationError) }

        let recovered = try await retry.value
        XCTAssertEqual(recovered?.configuration.mode, .publicProxy)
        XCTAssertEqual(directory.effectiveTransport, recovered)
        XCTAssertEqual(proxy.registrationRequestCount, 1)
        XCTAssertGreaterThanOrEqual(resolverCalls, 2)
        await directory.logout()
        await directory.closeProxySession()
    }

    func testCancellingAcceptedProxySwitchCompensatesOriginalRelayRegistration() async throws {
        let server = try LocalAutomaticDirectory()
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let directoryPort = try XCTUnwrap(server.listener.port?.rawValue)
        let proxy = try RefreshTestProxy(behavior: .stallRegistration)
        try await proxy.start()
        defer { proxy.stop() }
        let client = DirectoryClient(host: "127.0.0.1", port: directoryPort,
            relayDirectoryHosts: ["127.0.0.1"], relayDirectoryPort: directoryPort)
        let relayAddress = "198.51.100.7"
        try await client.login(callsign: "N0TEST", password: "test-only-password", relayAddress: relayAddress)
        let initialRelayRegistrations = server.relayAddresses.count
        let proxyConfiguration = EchoLinkProxyConfiguration(
            mode: .publicProxy, host: "127.0.0.1", port: proxy.port, password: "PUBLIC"
        )
        let session = try await EchoLinkProxySession.connect(
            configurations: [proxyConfiguration], callsign: "N0TEST"
        )
        defer { Task { await session.close() } }

        let switching = Task { try await client.switchToPublicProxy(session, callsign: "N0TEST") }
        await fulfillment(of: [proxy.registrationReceived], timeout: 2)
        switching.cancel()
        proxy.releaseRegistration()
        do {
            try await switching.value
            XCTFail("Cancelled switch must report cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }

        let clientStillLoggedIn = await client.isLoggedIn
        XCTAssertTrue(clientStillLoggedIn)
        XCTAssertGreaterThan(server.relayAddresses.count, initialRelayRegistrations)
        XCTAssertEqual(server.relayAddresses.last, relayAddress)
    }

    func testPublicProxyCandidateRejectionRetriesWithinBound() {
        let publicProxy = EchoLinkProxyConfiguration(
            mode: .publicProxy, host: "proxy.example", port: 8100, password: "PUBLIC"
        )
        XCTAssertTrue(DirectoryPublicProxyRetryPolicy.shouldRetry(
            configuration: publicProxy,
            error: EchoLinkProxyClient.ClientError.badPassword,
            rejectedCandidateCount: 1
        ))
        XCTAssertTrue(DirectoryPublicProxyRetryPolicy.shouldRetry(
            configuration: publicProxy,
            error: EchoLinkProxyClient.ClientError.accessDenied,
            rejectedCandidateCount: 2
        ))
        XCTAssertFalse(DirectoryPublicProxyRetryPolicy.shouldRetry(
            configuration: publicProxy,
            error: EchoLinkProxyClient.ClientError.badPassword,
            rejectedCandidateCount: EchoLinkPublicProxyListClient.defaultCandidateLimit
        ))
    }

    func testPublicProxyRetryDoesNotHideDirectoryOrCustomProxyErrors() {
        let customProxy = EchoLinkProxyConfiguration(
            mode: .customProxy, host: "proxy.example", port: 8100, password: "private"
        )
        let publicProxy = EchoLinkProxyConfiguration(
            mode: .publicProxy, host: "proxy.example", port: 8100, password: "PUBLIC"
        )
        XCTAssertFalse(DirectoryPublicProxyRetryPolicy.shouldRetry(
            configuration: customProxy,
            error: EchoLinkProxyClient.ClientError.badPassword,
            rejectedCandidateCount: 1
        ))
        XCTAssertFalse(DirectoryPublicProxyRetryPolicy.shouldRetry(
            configuration: publicProxy,
            error: DirectoryClientError.loginDenied,
            rejectedCandidateCount: 1
        ))
        XCTAssertTrue(DirectoryPublicProxyRetryPolicy.shouldRetry(
            configuration: publicProxy,
            error: EchoLinkProxyClient.ClientError.connectionClosed,
            rejectedCandidateCount: 1
        ))
    }

    func testSelectedRelayIsAdvertisedDuringLoginAndRetainedForAccountRecovery() async throws {
        let server = try LocalAutomaticDirectory()
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let automatic = EchoLinkProxyConfiguration(mode: .automatic, host: "", port: 8100, password: "PUBLIC")
        var savedPreference = automatic
        let probes = DiscoveryCounter()
        let selector = EchoLinkAutomaticTransportSelector(localAddresses: { ["10.0.0.1"] }, discoverRelays: {
            probes.increment()
            return ["198.51.100.7"]
        })
        let directory = EchoLinkDirectoryService(
            transportSelector: selector, configurationProvider: { savedPreference },
            client: DirectoryClient(host: "127.0.0.1", port: port,
                relayDirectoryHosts: ["127.0.0.1"], relayDirectoryPort: port),
            saveCredentials: { _, _, _ in true }
        )
        await directory.login(callsign: "N0TEST", password: "test-only-password")
        XCTAssertTrue(directory.isLoggedIn, directory.error?.localizedDescription ?? "")
        let selected = try XCTUnwrap(directory.effectiveTransport)
        XCTAssertEqual(selected.preference.mode, .automatic)
        XCTAssertEqual(selected.configuration.mode, .relay)
        XCTAssertEqual(selected.relayAddress, "198.51.100.7")
        XCTAssertEqual(server.relayAddresses, ["198.51.100.7", "198.51.100.7"])
        XCTAssertEqual(probes.count, 1)

        savedPreference = EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "")
        let refreshed = await directory.refresh()
        XCTAssertTrue(refreshed)
        await directory.stopAdvertisingRelay(address: "198.51.100.7")
        let available = await directory.setAvailableForCalls(true)
        XCTAssertTrue(available)
        XCTAssertEqual(directory.effectiveTransport, selected)
        XCTAssertEqual(probes.count, 1)
        XCTAssertTrue(server.relayAddresses.allSatisfy { $0 == selected.relayAddress })
        XCTAssertEqual(server.relayAddresses.count, 4)

        // Internal tunnel recovery explicitly retains the original selection.
        await directory.login(callsign: "N0TEST", password: "test-only-password", retainingTransport: selected)
        XCTAssertTrue(directory.isLoggedIn, directory.error?.localizedDescription ?? "")
        XCTAssertEqual(directory.effectiveTransport, selected)
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(server.relayAddresses.count, 6)

        // A fresh explicit login adopts the new configured preference.
        await directory.login(callsign: "N0TEST", password: "test-only-password")
        XCTAssertTrue(directory.isLoggedIn, directory.error?.localizedDescription ?? "")
        XCTAssertEqual(directory.effectiveTransport?.configuration.mode, .direct)
        await directory.logout()
        XCTAssertNil(directory.effectiveTransport)
    }

    func testCancelledSelectionNeverRegistersOrFallsBackToProxy() async {
        let automatic = EchoLinkProxyConfiguration(mode: .automatic, host: "", port: 8100, password: "PUBLIC")
        let directory = EchoLinkDirectoryService(
            transportSelector: EchoLinkAutomaticTransportSelector(localAddresses: { [] }, discoverRelays: { throw CancellationError() }),
            configurationProvider: { automatic }, saveCredentials: { _, _, _ in XCTFail("Cancelled login must not persist credentials"); return true }
        )
        await directory.login(callsign: "N0TEST", password: "test-only-password")
        XCTAssertFalse(directory.isLoggedIn)
        XCTAssertNil(directory.effectiveTransport)
        XCTAssertTrue(directory.error is CancellationError)
    }
}

private final class DiscoveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private actor AutomaticFallbackResolverGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private final class LocalAutomaticDirectory: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "EchoLinkAutomaticDirectoryTests.server")
    let ready = XCTestExpectation(description: "local directory ready")
    private var addresses: [String] = []
    var relayAddresses: [String] { queue.sync { addresses } }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let bytes = buffered + data
            let request = String(decoding: bytes, as: UTF8.self)
            let response: String
            if request.hasPrefix("-LOGIN") {
                guard request.contains("\n\n") else { self.receive(connection, buffered: bytes); return }
                let address = request.components(separatedBy: "\n").first { $0.hasPrefix("client-addr:") }?
                    .replacingOccurrences(of: "client-addr:", with: "").trimmingCharacters(in: .whitespaces)
                if let address { self.addresses.append(address) }
                response = request.contains("hashed-password:") ? "LOGIN-RESULT\nresult:success\n\n" : "LOGIN-RESULT\nchallenge:local-test\n\n"
            } else if request.hasPrefix("z") {
                response = "OK\r\n"
            } else if request == "s" {
                response = "@@@\n0\n+++"
            } else {
                response = "OK\r\n"
            }
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
