// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Network
import XCTest
@testable import ReverbQSO

@MainActor
final class DirectoryLoginFallbackTests: XCTestCase {
    func testAutomaticRelayListRejectionRegistersSuppliedAccountThroughPublicProxy() async throws {
        let fixture = try await DirectoryLoginFallbackFixture()
        defer { fixture.stop() }
        await fixture.service.login(callsign: "N0TEST", password: "loopback-password", persistAsActive: false)

        XCTAssertTrue(fixture.service.isLoggedIn, fixture.service.error?.localizedDescription ?? "")
        XCTAssertTrue(fixture.service.registeredThroughProxy)
        XCTAssertEqual(fixture.service.stations.map(\.callsign), ["N0LOOP-R"])
        XCTAssertEqual(fixture.service.effectiveTransport?.preference, fixture.preference)
        XCTAssertEqual(fixture.service.effectiveTransport?.configuration.mode, .publicProxy)
        XCTAssertNil(fixture.service.effectiveTransport?.relayAddress)
        XCTAssertEqual(fixture.trace.resolutions.count, 1)
        XCTAssertEqual(fixture.trace.resolutions.first?.host, fixture.preference.host)
        XCTAssertEqual(fixture.trace.resolutions.first?.port, fixture.preference.port)
        XCTAssertEqual(fixture.trace.saves.map(\.callsign), ["N0TEST"])
        XCTAssertEqual(fixture.trace.saves.map(\.password), ["loopback-password"])
        XCTAssertEqual(fixture.trace.saves.map(\.active), [false])
        XCTAssertEqual(fixture.server.requests.filter { $0 == "s" }.count, 1)
        XCTAssertEqual(fixture.server.requests.filter { $0.hasPrefix("-LOGIN") }.count, 2)
        XCTAssertTrue(fixture.server.requests.filter { $0.hasPrefix("-LOGIN") }
            .allSatisfy { $0.contains("client-addr: 198.51.100.7\n") })
        XCTAssertEqual(fixture.proxies[0].requests.filter { $0.hasPrefix("-LOGIN") }.count, 2)
        XCTAssertTrue(fixture.proxies[0].requests.allSatisfy { !$0.contains("client-addr:") })
        XCTAssertTrue((fixture.server.requests + fixture.proxies[0].requests)
            .allSatisfy { !$0.contains("loopback-password") })
        let events = fixture.events.values
        let retirement = try XCTUnwrap(events.firstIndex(of: "direct:zN0TEST\r"))
        let replacement = try XCTUnwrap(events.firstIndex { $0.hasPrefix("proxy0:-LOGIN") })
        XCTAssertLessThan(retirement, replacement)
        await fixture.close()
    }

    func testRepeatedAutomaticDirectLoginRetiresOldAccountBeforeRegisteringNewAccount() async throws {
        let fixture = try await DirectoryLoginFallbackFixture(relay: false)
        defer { fixture.stop() }
        await fixture.service.login(callsign: "N0TEST", password: "loopback-password")
        await fixture.service.login(callsign: "N0NEW", password: "new-loopback-password")

        XCTAssertTrue(fixture.service.isLoggedIn, fixture.service.error?.localizedDescription ?? "")
        XCTAssertEqual(fixture.trace.resolutions.count, 2, "One fallback per login, not one per service lifetime")
        XCTAssertEqual(fixture.trace.saves.map(\.callsign), ["N0TEST", "N0NEW"])
        XCTAssertEqual(fixture.trace.saves.map(\.password), ["loopback-password", "new-loopback-password"])
        XCTAssertEqual(fixture.server.requests.filter { $0.hasPrefix("z") }, ["zN0TEST\r", "zN0NEW\r"])
        XCTAssertEqual(fixture.proxies[0].requests.filter { $0.hasPrefix("z") }, ["zN0TEST\r"])
        XCTAssertTrue(fixture.server.requests.allSatisfy { !$0.contains("client-addr:") })
        let events = fixture.events.values
        let retirement = try XCTUnwrap(events.firstIndex(of: "proxy0:zN0TEST\r"))
        let replacement = try XCTUnwrap(events.firstIndex { $0.hasPrefix("direct:-LOGIN\ncallsign: N0NEW\n") })
        XCTAssertLessThan(retirement, replacement)
        XCTAssertEqual(fixture.service.effectiveTransport?.preference, fixture.preference)
        await fixture.close()
    }

    func testExplicitDirectAndRelayNeverUseAutomaticLoginFallback() async throws {
        for mode in [EchoLinkNetworkMode.direct, .relay] {
            let fixture = try await DirectoryLoginFallbackFixture(mode: mode)
            defer { fixture.stop() }
            await fixture.service.login(callsign: "N0TEST", password: "loopback-password")
            assertUnpublished(fixture)
            XCTAssertTrue(fixture.trace.resolutions.isEmpty)
            XCTAssertTrue(fixture.proxies[0].requests.isEmpty)
            XCTAssertNotNil(fixture.service.error)
            await fixture.close()
        }
    }

    func testRegistrationDenialsNeverFallback() async throws {
        for reason in ["bad-password", "in-use", "barred", "not-validated", "notfound", "unrelated-failure"] {
            let fixture = try await DirectoryLoginFallbackFixture(registrationFailure: reason)
            defer { fixture.stop() }
            await fixture.service.login(callsign: "N0TEST", password: "loopback-password")
            assertUnpublished(fixture)
            XCTAssertTrue(fixture.trace.resolutions.isEmpty, reason)
            XCTAssertFalse(fixture.server.requests.contains("s"))
            XCTAssertNotNil(fixture.service.error)
            await fixture.close()
        }
    }

    func testMalformedAndDeniedInitialListsNeverFallback() async throws {
        for response in ["", "@@@\n1\n\nUnrelated malformed row\n\n\n+++\n", "DENIED\n+++\n", "IN-USE\n+++\n"] {
            let fixture = try await DirectoryLoginFallbackFixture(directoryResponse: response)
            defer { fixture.stop() }
            await fixture.service.login(callsign: "N0TEST", password: "loopback-password")
            assertUnpublished(fixture)
            XCTAssertTrue(fixture.trace.resolutions.isEmpty)
            XCTAssertNotNil(fixture.service.error)
            await fixture.close()
        }
    }

    func testCancellationDuringInitialListNeverStartsFallback() async throws {
        let fixture = try await DirectoryLoginFallbackFixture(holdDirectList: true)
        defer { fixture.stop() }
        let login = Task { await fixture.service.login(callsign: "N0TEST", password: "loopback-password") }
        await fulfillment(of: [fixture.server.listReceived], timeout: 2)
        login.cancel()
        fixture.server.releaseList()
        await login.value

        assertUnpublished(fixture)
        XCTAssertTrue(fixture.trace.resolutions.isEmpty)
        XCTAssertTrue(fixture.service.error is CancellationError)
        let clientLoggedIn = await fixture.client.isLoggedIn
        XCTAssertFalse(clientLoggedIn)
        await fixture.close()
    }

    func testCancellationAndStaleLoginDuringFallbackCannotPublishOrSave() async throws {
        for cancel in [true, false] {
            let gate = DirectoryLoginFallbackGate()
            let resolving = expectation(description: "fallback resolution entered")
            let fixture = try await DirectoryLoginFallbackFixture(gate: gate, resolving: resolving)
            defer { fixture.stop() }
            let login = Task { await fixture.service.login(callsign: "N0TEST", password: "loopback-password") }
            await fulfillment(of: [resolving], timeout: 2)
            assertUnpublished(fixture, loading: true)
            if cancel { login.cancel() }
            else {
                // A newer lifecycle owns this error; the old fallback must not clear it.
                await fixture.service.login(callsign: "", password: "")
            }
            await gate.open()
            await login.value

            assertUnpublished(fixture)
            XCTAssertTrue(fixture.proxies[0].requests.isEmpty)
            if cancel { XCTAssertTrue(fixture.service.error is CancellationError) }
            else {
                guard case .connectionFailed(let reason) = fixture.service.error as? DirectoryClientError else {
                    return XCTFail("Newer login error must survive stale fallback")
                }
                XCTAssertEqual(reason, "Callsign and password are required.")
            }
            await fixture.close()
        }
    }

    func testCancellationAfterProxyRegistrationCannotPublishOrSave() async throws {
        let fixture = try await DirectoryLoginFallbackFixture(holdProxyList: true)
        defer { fixture.stop() }
        let login = Task { await fixture.service.login(callsign: "N0TEST", password: "loopback-password") }
        await fulfillment(of: [fixture.proxies[0].listReceived], timeout: 2)
        assertUnpublished(fixture, loading: true)
        login.cancel()
        fixture.proxies[0].releaseList()
        await login.value

        assertUnpublished(fixture)
        XCTAssertTrue(fixture.service.error is CancellationError)
        let clientLoggedIn = await fixture.client.isLoggedIn
        XCTAssertFalse(clientLoggedIn)
        await fixture.close()
    }

    func testFallbackUsesExistingBoundedProxyRetryAndLeavesNoPartialLogin() async throws {
        let limit = EchoLinkPublicProxyListClient.defaultCandidateLimit
        let fixture = try await DirectoryLoginFallbackFixture(rejectedProxyCount: limit + 1)
        defer { fixture.stop() }
        await fixture.service.login(callsign: "N0TEST", password: "loopback-password")

        assertUnpublished(fixture)
        XCTAssertNotNil(fixture.service.error)
        XCTAssertEqual(fixture.trace.resolutions.count, limit)
        XCTAssertEqual(fixture.proxies.filter { $0.openCount > 0 }.count, limit)
        XCTAssertEqual(fixture.proxies.last?.openCount, 0)
        XCTAssertEqual(fixture.server.requests.filter { $0 == "s" }.count, 1)
        let clientLoggedIn = await fixture.client.isLoggedIn
        XCTAssertFalse(clientLoggedIn)
        await fixture.close()
    }

    func testProxyAuthSentinelDoesNotRestartAutomaticFallback() async throws {
        let fixture = try await DirectoryLoginFallbackFixture(proxyRejectsList: true)
        defer { fixture.stop() }
        await fixture.service.login(callsign: "N0TEST", password: "loopback-password")

        assertUnpublished(fixture)
        XCTAssertEqual(fixture.trace.resolutions.count, 1)
        XCTAssertEqual(fixture.proxies[0].requests.filter { $0 == "s" }.count, 1)
        guard case .notConnected = fixture.service.error as? DirectoryClientError else {
            return XCTFail("Preserve the proxy's typed registration rejection")
        }
        await fixture.close()
    }

    private func assertUnpublished(_ fixture: DirectoryLoginFallbackFixture, loading: Bool = false,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fixture.service.isLoggedIn, file: file, line: line)
        XCTAssertFalse(fixture.service.registeredThroughProxy, file: file, line: line)
        XCTAssertNil(fixture.service.effectiveTransport, file: file, line: line)
        XCTAssertTrue(fixture.service.stations.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.service.filteredStations.isEmpty, file: file, line: line)
        XCTAssertNil(fixture.service.lastSuccessfulSnapshotAt, file: file, line: line)
        XCTAssertEqual(fixture.service.isLoading, loading, file: file, line: line)
        XCTAssertTrue(fixture.trace.saves.isEmpty, file: file, line: line)
    }
}

@MainActor
private final class DirectoryLoginFallbackTrace {
    var resolutions: [EchoLinkProxyConfiguration] = []
    var saves: [(callsign: String, password: String, active: Bool)] = []
}

@MainActor
private final class DirectoryLoginFallbackFixture {
    // The directory encodes this notice as seven display-only loopback rows.
    static let rejectedList = (["@@@", "7"] + [
        "NOT LOGGED IN", "", "You are not currently logged", "in.",
        "If this message persists,", "check to ensure your software", "configuration is correct."
    ].flatMap { [" ", $0, "    ", "127.0.0.1"] } + ["+++"]).joined(separator: "\r\n")
    static let validList = "@@@\n1\nN0LOOP-R\nLoopback fixture\n12345\n192.0.2.25\n+++\n"
    let preference: EchoLinkProxyConfiguration
    let events = DirectoryLoginFallbackEvents()
    let server: DirectoryLoginFallbackEndpoint
    let proxies: [DirectoryLoginFallbackEndpoint]
    let trace = DirectoryLoginFallbackTrace()
    let client: DirectoryClient
    let service: EchoLinkDirectoryService

    init(mode: EchoLinkNetworkMode = .automatic, relay: Bool = true, registrationFailure: String? = nil,
         directoryResponse: String = rejectedList, holdDirectList: Bool = false, holdProxyList: Bool = false,
         rejectedProxyCount: Int = 0, proxyRejectsList: Bool = false,
         gate: DirectoryLoginFallbackGate? = nil, resolving: XCTestExpectation? = nil) async throws {
        preference = EchoLinkProxyConfiguration(mode: mode, host: "preferred.invalid", port: 8123, password: "PUBLIC")
        server = try DirectoryLoginFallbackEndpoint(name: "direct", events: events,
            directoryResponse: directoryResponse, registrationFailure: registrationFailure, holdList: holdDirectList)
        proxies = try (0..<max(1, rejectedProxyCount)).map { index in
            try DirectoryLoginFallbackEndpoint(name: "proxy\(index)", events: events, isProxy: true,
                directoryResponse: proxyRejectsList ? Self.rejectedList : Self.validList,
                rejectOpen: rejectedProxyCount > 0, holdList: holdProxyList)
        }
        try await server.start()
        for proxy in proxies { try await proxy.start() }
        let candidates = proxies.map {
            EchoLinkProxyConfiguration(mode: .publicProxy, host: "127.0.0.1", port: $0.port, password: "PUBLIC")
        }
        let trace = trace
        let preference = preference
        let store = EchoLinkProxySessionStore(configurationProvider: { preference }, resolveCandidates: {
            trace.resolutions.append($0)
            resolving?.fulfill()
            await gate?.wait()
            return candidates
        })
        client = DirectoryClient(host: "127.0.0.1", port: server.port,
            relayDirectoryHosts: ["127.0.0.1"], relayDirectoryPort: server.port)
        service = EchoLinkDirectoryService(proxySessionStore: store,
            transportSelector: EchoLinkAutomaticTransportSelector(localAddresses: { relay ? [] : ["8.8.8.8"] },
                discoverRelays: { ["198.51.100.7"] }),
            configurationProvider: { preference }, client: client, saveCredentials: {
                trace.saves.append(($0, $1, $2))
                return true
            })
    }

    func close() async {
        await service.logout()
        await service.closeProxySession()
    }

    func stop() {
        server.stop()
        proxies.forEach { $0.stop() }
    }
}

private actor DirectoryLoginFallbackGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if !isOpen { await withCheckedContinuation { continuation = $0 } }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class DirectoryLoginFallbackEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
}

/// Only loopback sockets are opened; proxy directory frames are answered locally,
/// never forwarded. Both paths exercise the real challenge-based -LOGIN protocol.
private final class DirectoryLoginFallbackEndpoint: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DirectoryLoginFallbackTests.endpoint")
    private let ready = XCTestExpectation(description: "loopback endpoint ready")
    let listReceived = XCTestExpectation(description: "initial list received")
    private let name: String
    private let events: DirectoryLoginFallbackEvents
    private let isProxy: Bool
    private let directoryResponse: String
    private let registrationFailure: String?
    private let rejectOpen: Bool
    private let holdList: Bool
    private var connections: [NWConnection] = []
    private var recordedRequests: [String] = []
    private var opens = 0
    private var heldList: NWConnection?
    private var receivedList = false
    private let nonce = Data("12345678".utf8)
    private let challenge = "directory-fallback-loopback"

    var port: UInt16 { listener.port!.rawValue }
    var requests: [String] { queue.sync { recordedRequests } }
    var openCount: Int { queue.sync { opens } }

    init(name: String, events: DirectoryLoginFallbackEvents, isProxy: Bool = false,
         directoryResponse: String, registrationFailure: String? = nil,
         rejectOpen: Bool = false, holdList: Bool = false) throws {
        self.name = name
        self.events = events
        self.isProxy = isProxy
        self.directoryResponse = directoryResponse
        self.registrationFailure = registrationFailure
        self.rejectOpen = rejectOpen
        self.holdList = holdList
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            if self.isProxy {
                connection.send(content: self.nonce, completion: .idempotent)
                self.receiveAuthentication(connection, buffered: Data())
            } else { self.receiveRequest(connection, buffered: Data()) }
        }
    }

    func start() async throws {
        listener.start(queue: queue)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 2)
        guard result == .completed else { throw URLError(.timedOut) }
        _ = try XCTUnwrap(listener.port)
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    func releaseList() {
        queue.async {
            guard let connection = self.heldList else { return }
            self.heldList = nil
            self.respond(self.directoryResponse, on: connection)
        }
    }

    private func receiveAuthentication(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let bytes = buffered + data
            guard let newline = bytes.firstIndex(of: 10), bytes.count >= newline + 17 else {
                if complete { connection.cancel() }
                else { self.receiveAuthentication(connection, buffered: bytes) }
                return
            }
            let callsign = String(decoding: bytes.prefix(upTo: newline), as: UTF8.self)
            let expected = try! EchoLinkProxyProtocol.authenticationResponse(callsign: callsign, password: "PUBLIC", nonce: self.nonce)
            guard bytes.starts(with: expected) else { connection.cancel(); return }
            self.receiveFrames(connection, buffered: Data(bytes.dropFirst(expected.count)))
        }
    }

    private func receiveFrames(_ connection: NWConnection, buffered: Data) {
        var pending = buffered
        do {
            while let message = try EchoLinkProxyProtocol.parseNextMessage(from: &pending) {
                switch message.type {
                case .tcpOpen:
                    opens += 1
                    sendFrame(.tcpStatus, payload: rejectOpen ? Data([1, 0, 0, 0]) : Data(repeating: 0, count: 4), on: connection)
                case .tcpData: handle(String(decoding: message.payload, as: UTF8.self), on: connection)
                default: break
                }
            }
        } catch { connection.cancel(); return }
        let remainder = pending
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            self.receiveFrames(connection, buffered: remainder + data)
            if complete { connection.cancel() }
        }
    }

    private func receiveRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let bytes = buffered + data
            let request = String(decoding: bytes, as: UTF8.self)
            if (request.hasPrefix("-LOGIN") && !request.hasSuffix("\n\n"))
                || (request.hasPrefix("z") && !request.hasSuffix("\r")) {
                self.receiveRequest(connection, buffered: bytes)
                return
            }
            self.handle(request, on: connection)
        }
    }

    private func handle(_ request: String, on connection: NWConnection) {
        recordedRequests.append(request)
        events.append("\(name):\(request)")
        if request.hasPrefix("-LOGIN\n") {
            if let registrationFailure {
                respond("LOGIN-RESULT\nresult:failure\nreason:\(registrationFailure)\n\n", on: connection)
                return
            }
            let fields = Dictionary(uniqueKeysWithValues: request.split(separator: "\n").dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            })
            guard let hash = fields["hashed-password"] else {
                respond("LOGIN-RESULT\nchallenge:\(challenge)\n\n", on: connection)
                return
            }
            let password = fields["callsign"] == "N0NEW" ? "new-loopback-password" : "loopback-password"
            let expected = Insecure.MD5.hash(data: Data((password.uppercased() + challenge).utf8))
                .map { String(format: "%02X", $0) }.joined()
            let response = hash == expected ? "LOGIN-RESULT\nresult:success\n\n"
                : "LOGIN-RESULT\nresult:failure\nreason:bad-password\n\n"
            respond(response, on: connection)
        } else if request == "s" {
            if !receivedList { receivedList = true; listReceived.fulfill() }
            if holdList { heldList = connection }
            else { respond(directoryResponse, on: connection) }
        } else if request.hasPrefix("z") { respond("OK\r\n", on: connection) }
        else { connection.cancel() }
    }

    private func respond(_ response: String, on connection: NWConnection) {
        if isProxy { sendFrame(.tcpData, payload: Data(response.utf8), on: connection) }
        else {
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func sendFrame(_ type: EchoLinkProxyMessage.MessageType, payload: Data, on connection: NWConnection) {
        let frame = try! EchoLinkProxyProtocol.encode(type: type, remoteHost: "0.0.0.0", payload: payload)
        connection.send(content: frame, completion: .idempotent)
    }
}
