// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import XCTest
@testable import ReverbQSO

@MainActor
final class EchoLinkAutomaticDirectoryTests: XCTestCase {
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
