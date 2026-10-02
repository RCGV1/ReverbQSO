// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import XCTest
@testable import ReverbQSO

final class EchoLinkProxyProtocolTests: XCTestCase {
    func testCandidateExclusionsMatchEndpointAndOnlyRejectionsTriggerFailover() {
        let first = EchoLinkProxyConfiguration(mode: .publicProxy, host: "First.Example", port: 8100, password: "PUBLIC")
        let sameEndpoint = EchoLinkProxyConfiguration(mode: .publicProxy, host: "first.example", port: 8100, password: "old")
        let otherPort = EchoLinkProxyConfiguration(mode: .publicProxy, host: "first.example", port: 8101, password: "PUBLIC")
        let second = EchoLinkProxyConfiguration(mode: .publicProxy, host: "second.example", port: 8100, password: "PUBLIC")
        XCTAssertEqual(EchoLinkProxyClient.untriedCandidates([first, otherPort, second], excluding: [sameEndpoint]), [otherPort, second])
        XCTAssertTrue(EchoLinkProxyClient.ClientError.badPassword.isCandidateRejection)
        XCTAssertTrue(EchoLinkProxyClient.ClientError.accessDenied.isCandidateRejection)
        XCTAssertFalse(EchoLinkProxyClient.ClientError.connectionClosed.isCandidateRejection)
        XCTAssertFalse(EchoLinkProxyClient.ClientError.authenticationTimedOut.isCandidateRejection)
    }

    @MainActor
    func testObsoleteAccountAcquisitionDoesNotReplaceOrCloseNewerProxy() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        let firstAccepted = expectation(description: "first account accepted")
        let secondAccepted = expectation(description: "second account accepted")
        let queue = DispatchQueue(label: "EchoLinkProxyProtocolTests.account-switch")
        let connections = DeferredProxyConnection(queue: queue)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            if connections.accept(connection) == 1 { firstAccepted.fulfill() }
            else { secondAccepted.fulfill() }
        }
        listener.start(queue: queue)
        defer { listener.cancel(); connections.close() }
        await fulfillment(of: [ready], timeout: 2)
        let configuration = EchoLinkProxyConfiguration(
            mode: .customProxy, host: "127.0.0.1",
            port: try XCTUnwrap(listener.port?.rawValue), password: "test-only-password"
        )
        let store = EchoLinkProxySessionStore()
        let first = Task { try await store.session(callsign: "W1AW", configuration: configuration) }
        await fulfillment(of: [firstAccepted], timeout: 2)
        let second = Task { try await store.session(callsign: "K1BBB", configuration: configuration) }
        await fulfillment(of: [secondAccepted], timeout: 2)
        connections.issueChallenge(at: 1)
        let acquired = try await second.value
        let current = try XCTUnwrap(acquired)
        connections.issueChallenge(at: 0)
        do {
            _ = try await first.value
            XCTFail("The obsolete account connection must be discarded")
        } catch is CancellationError {}
        let retained = await store.currentSession(callsign: "K1BBB", configuration: configuration)
        XCTAssertTrue(retained === current)
        let isUsable = await current.isUsable()
        XCTAssertTrue(isUsable)
        let oldAccount = await store.currentSession(callsign: "W1AW", configuration: configuration)
        XCTAssertNil(oldAccount)
        await store.close()
    }

    @MainActor
    func testClosingStoreInvalidatesConnectionAwaitingChallenge() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        let accepted = expectation(description: "proxy accepted connection")
        let queue = DispatchQueue(label: "EchoLinkProxyProtocolTests.closed-store")
        let acceptedConnection = DeferredProxyConnection(queue: queue)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            acceptedConnection.accept(connection)
            accepted.fulfill()
        }
        listener.start(queue: queue)
        defer { listener.cancel(); acceptedConnection.close() }
        await fulfillment(of: [ready], timeout: 2)
        let configuration = EchoLinkProxyConfiguration(
            mode: .customProxy, host: "127.0.0.1",
            port: try XCTUnwrap(listener.port?.rawValue), password: "test-only-password"
        )
        let store = EchoLinkProxySessionStore()
        let connecting = Task { try await store.session(callsign: "W1AW", configuration: configuration) }
        await fulfillment(of: [accepted], timeout: 2)
        await store.close()
        acceptedConnection.issueChallenge()
        do {
            _ = try await connecting.value
            XCTFail("A closed store must discard its pending authenticated connection")
        } catch is CancellationError {
            // Closing or replacing the account invalidates the pending generation.
        }
        let current = await store.currentSession(callsign: "W1AW", configuration: configuration)
        XCTAssertNil(current)
        await store.close()
    }

    func testMaximumPayloadBoundaryAppliesToEveryMessageType() throws {
        let payload = Data(repeating: 0xA5, count: 5_000)
        for rawType in UInt8(1)...UInt8(7) {
            let type = try XCTUnwrap(EchoLinkProxyMessage.MessageType(rawValue: rawType))
            let frame = try EchoLinkProxyProtocol.encode(type: type, remoteHost: "0.0.0.0", payload: payload)
            XCTAssertEqual(frame.count, 5_009)
            XCTAssertEqual(Array(frame[5...8]), [0x88, 0x13, 0, 0])
            var buffer = frame
            XCTAssertEqual(try EchoLinkProxyProtocol.parseNextMessage(from: &buffer)?.payload, payload)
            XCTAssertTrue(buffer.isEmpty)
            XCTAssertThrowsError(try EchoLinkProxyProtocol.encode(
                type: type, remoteHost: "0.0.0.0", payload: payload + Data([0])
            )) { error in
                XCTAssertEqual(error as? EchoLinkProxyProtocol.ProtocolError, .payloadTooLarge(5_001))
            }
        }
    }

    func testOversizedHeaderRejectsImmediatelyWithoutConsumingBody() throws {
        let header = Data([5, 192, 0, 2, 1, 0x89, 0x13, 0, 0])
        var buffer = Data()
        for byte in header.prefix(8) {
            buffer.append(byte)
            XCTAssertNil(try EchoLinkProxyProtocol.parseNextMessage(from: &buffer))
        }
        buffer.append(header.last!)
        XCTAssertThrowsError(try EchoLinkProxyProtocol.parseNextMessage(from: &buffer)) { error in
            XCTAssertEqual(error as? EchoLinkProxyProtocol.ProtocolError, .payloadTooLarge(5_001))
        }
        XCTAssertEqual(buffer, header)
    }

    func testMaximumFrameDeliveredOnceAfterBytewiseFragmentation() throws {
        let payload = Data(repeating: 0xA5, count: 5_000)
        let frame = try EchoLinkProxyProtocol.encode(type: .udpData, remoteHost: "192.0.2.1", payload: payload)
        var buffer = Data()
        for byte in frame.dropLast() {
            buffer.append(byte)
            XCTAssertNil(try EchoLinkProxyProtocol.parseNextMessage(from: &buffer))
        }
        buffer.append(frame.last!)
        XCTAssertEqual(try EchoLinkProxyProtocol.parseNextMessage(from: &buffer)?.payload, payload)
        XCTAssertNil(try EchoLinkProxyProtocol.parseNextMessage(from: &buffer))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testConcatenatedMaximumFramesPreserveOrder() throws {
        let first = Data(repeating: 1, count: 5_000)
        let second = Data(repeating: 2, count: 5_000)
        var buffer = try EchoLinkProxyProtocol.encode(type: .tcpData, remoteHost: "0.0.0.0", payload: first)
        buffer.append(try EchoLinkProxyProtocol.encode(type: .udpControl, remoteHost: "192.0.2.1", payload: second))
        XCTAssertEqual(try EchoLinkProxyProtocol.parseAvailableMessages(from: &buffer).map(\.payload), [first, second])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testValidFrameDeliveredBeforeFollowingOversizedHeaderFails() throws {
        let payload = Data([1, 2, 3])
        let malformed = Data([6, 192, 0, 2, 1, 0x89, 0x13, 0, 0]) + Data([0xA5])
        var buffer = try EchoLinkProxyProtocol.encode(type: .udpData, remoteHost: "192.0.2.1", payload: payload)
        buffer.append(malformed)
        XCTAssertEqual(try EchoLinkProxyProtocol.parseNextMessage(from: &buffer)?.payload, payload)
        XCTAssertThrowsError(try EchoLinkProxyProtocol.parseNextMessage(from: &buffer)) { error in
            XCTAssertEqual(error as? EchoLinkProxyProtocol.ProtocolError, .payloadTooLarge(5_001))
        }
        XCTAssertEqual(buffer, malformed)
    }

    func testInvalidTypeRejectsCompleteHeaderWithoutConsumption() {
        for type: UInt8 in [0, 8, 255] {
            var buffer = Data([type, 0, 0, 0, 0, 0, 0, 0, 0])
            let original = buffer
            XCTAssertThrowsError(try EchoLinkProxyProtocol.parseNextMessage(from: &buffer)) { error in
                XCTAssertEqual(error as? EchoLinkProxyProtocol.ProtocolError, .invalidMessageType(type))
            }
            XCTAssertEqual(buffer, original)
        }
    }

    func testAuthenticationResponseUsesUppercasePasswordAndRawMD5Digest() throws {
        let response = try EchoLinkProxyProtocol.authenticationResponse(
            callsign: "w1aw",
            password: "secret",
            nonce: Data("12345678".utf8)
        )

        XCTAssertEqual(response.prefix(5), Data("W1AW\n".utf8))
        XCTAssertEqual(
            response.dropFirst(5).map { String(format: "%02x", $0) }.joined(),
            "ac16dbfd058ecdf2b2851f3d78bc3a36"
        )
    }

    func testAuthenticationRejectsNonceWithWrongLength() {
        XCTAssertThrowsError(
            try EchoLinkProxyProtocol.authenticationResponse(
                callsign: "W1AW",
                password: "SECRET",
                nonce: Data("short".utf8)
            )
        )
    }

    func testUDPDataFrameUsesNetworkOrderAddressAndLittleEndianLength() throws {
        let frame = try EchoLinkProxyProtocol.encode(
            type: .udpData,
            remoteHost: "192.0.2.17",
            payload: Data([0xAA, 0xBB, 0xCC])
        )

        XCTAssertEqual(
            Array(frame),
            [5, 192, 0, 2, 17, 3, 0, 0, 0, 0xAA, 0xBB, 0xCC]
        )
    }

    func testParserWaitsForCompleteFrameAndPreservesRemainder() throws {
        let first = try EchoLinkProxyProtocol.encode(
            type: .udpControl,
            remoteHost: "203.0.113.9",
            payload: Data([1, 2])
        )
        let second = try EchoLinkProxyProtocol.encode(
            type: .udpData,
            remoteHost: "198.51.100.4",
            payload: Data([3, 4, 5])
        )
        var buffer = first + second.prefix(6)

        let messages = try EchoLinkProxyProtocol.parseAvailableMessages(from: &buffer)

        XCTAssertEqual(messages, [
            EchoLinkProxyMessage(
                type: .udpControl,
                remoteHost: "203.0.113.9",
                payload: Data([1, 2])
            )
        ])
        XCTAssertEqual(buffer, second.prefix(6))

        buffer.append(second.dropFirst(6))
        let completed = try EchoLinkProxyProtocol.parseAvailableMessages(from: &buffer)
        XCTAssertEqual(completed, [
            EchoLinkProxyMessage(
                type: .udpData,
                remoteHost: "198.51.100.4",
                payload: Data([3, 4, 5])
            )
        ])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testParserHandlesTwoConcatenatedFramesWithoutAssumingZeroBasedDataIndices() throws {
        let first = try EchoLinkProxyProtocol.encode(
            type: .tcpClose, remoteHost: "127.0.0.1", payload: Data()
        )
        let second = try EchoLinkProxyProtocol.encode(
            type: .udpControl, remoteHost: "192.0.2.1", payload: Data([1, 2, 3])
        )
        var buffer = first + second

        let messages = try EchoLinkProxyProtocol.parseAvailableMessages(from: &buffer)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].type, .tcpClose)
        XCTAssertEqual(messages[1].type, .udpControl)
        XCTAssertEqual(messages[1].payload, Data([1, 2, 3]))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testParserRecognizesAuthenticationFailures() throws {
        var badPassword = try EchoLinkProxyProtocol.encode(
            type: .system,
            remoteHost: "0.0.0.0",
            payload: Data([1])
        )
        var accessDenied = try EchoLinkProxyProtocol.encode(
            type: .system,
            remoteHost: "0.0.0.0",
            payload: Data([2])
        )

        XCTAssertEqual(
            try EchoLinkProxyProtocol.parseAvailableMessages(from: &badPassword).first?.systemEvent,
            .badPassword
        )
        XCTAssertEqual(
            try EchoLinkProxyProtocol.parseAvailableMessages(from: &accessDenied).first?.systemEvent,
            .accessDenied
        )
    }

    func testClientAuthenticatesAndReceivesTunneledAudioFromLocalProxy() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        let authenticated = expectation(description: "proxy received authentication")
        let queue = DispatchQueue(label: "EchoLinkProxyProtocolTests.fake-proxy")
        let nonce = Data("12345678".utf8)
        let tunneledPayload = Data([0xBE, 0xEF, 0xBE, 0xEF])

        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.send(content: nonce.prefix(4), completion: .contentProcessed { error in
                XCTAssertNil(error)
                queue.asyncAfter(deadline: .now() + 0.1) {
                    connection.send(content: nonce.suffix(4), completion: .contentProcessed { error in
                        XCTAssertNil(error)
                        connection.receive(minimumIncompleteLength: 21, maximumLength: 21) { data, _, _, error in
                            XCTAssertNil(error)
                            XCTAssertEqual(data?.prefix(5), Data("W1AW\n".utf8))
                            authenticated.fulfill()
                            let frame = try! EchoLinkProxyProtocol.encode(
                                type: .udpData,
                                remoteHost: "192.0.2.44",
                                payload: tunneledPayload
                            )
                            connection.send(content: frame, completion: .idempotent)
                        }
                    })
                }
            })
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 2)

        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = try EchoLinkProxyClient(host: "127.0.0.1", port: port)
        defer { client.close() }
        try await client.connect(callsign: "w1aw", password: "secret")
        await fulfillment(of: [authenticated], timeout: 2)

        var iterator = client.messages().makeAsyncIterator()
        let message = try await iterator.next()
        XCTAssertEqual(message?.type, .udpData)
        XCTAssertEqual(message?.remoteHost, "192.0.2.44")
        XCTAssertEqual(message?.payload, tunneledPayload)
    }

    func testClientDeliversValidFrameBeforeOversizedHeaderClosesStream() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        let queue = DispatchQueue(label: "EchoLinkProxyProtocolTests.oversized-header")
        let payload = Data([0xAA, 0xBB])
        let valid = try EchoLinkProxyProtocol.encode(type: .udpData, remoteHost: "192.0.2.1", payload: payload)
        let oversizedHeader = Data([5, 192, 0, 2, 1, 0x89, 0x13, 0, 0])
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.send(content: Data("12345678".utf8), completion: .contentProcessed { error in
                XCTAssertNil(error)
                connection.receive(minimumIncompleteLength: 21, maximumLength: 21) { _, _, _, error in
                    XCTAssertNil(error)
                    // Send only the invalid header after a valid frame; rejection
                    // must not depend on the declared body ever arriving.
                    connection.send(content: valid + oversizedHeader, completion: .idempotent)
                }
            })
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 2)
        let client = try EchoLinkProxyClient(host: "127.0.0.1", port: XCTUnwrap(listener.port?.rawValue))
        defer { client.close() }
        try await client.connect(callsign: "W1AW", password: "SECRET")
        var iterator = client.messages().makeAsyncIterator()
        let delivered = try await iterator.next()
        XCTAssertEqual(delivered?.payload, payload)
        do {
            _ = try await iterator.next()
            XCTFail("Oversized header must terminate the stream")
        } catch {
            XCTAssertEqual(error as? EchoLinkProxyProtocol.ProtocolError, .payloadTooLarge(5_001))
        }
    }

    func testClientFallsBackToNextProxyCandidate() async throws {
        let rejectingListener = try NWListener(using: .tcp, on: .any)
        let acceptingListener = try NWListener(using: .tcp, on: .any)
        let listenersReady = expectation(description: "listeners ready")
        listenersReady.expectedFulfillmentCount = 2
        let authenticated = expectation(description: "fallback proxy authenticated")
        let queue = DispatchQueue(label: "EchoLinkProxyProtocolTests.failover")
        let nonce = Data("12345678".utf8)

        for listener in [rejectingListener, acceptingListener] {
            listener.stateUpdateHandler = { state in
                if case .ready = state { listenersReady.fulfill() }
            }
        }
        rejectingListener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.cancel()
        }
        acceptingListener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.send(content: nonce, completion: .contentProcessed { error in
                XCTAssertNil(error)
                connection.receive(minimumIncompleteLength: 21, maximumLength: 21) { data, _, _, error in
                    XCTAssertNil(error)
                    XCTAssertEqual(data?.prefix(5), Data("W1AW\n".utf8))
                    authenticated.fulfill()
                }
            })
        }
        rejectingListener.start(queue: queue)
        acceptingListener.start(queue: queue)
        defer {
            rejectingListener.cancel()
            acceptingListener.cancel()
        }
        await fulfillment(of: [listenersReady], timeout: 2)

        let rejectingPort = try XCTUnwrap(rejectingListener.port?.rawValue)
        let acceptingPort = try XCTUnwrap(acceptingListener.port?.rawValue)
        let candidates = [rejectingPort, acceptingPort].map { port in
            EchoLinkProxyConfiguration(
                mode: .publicProxy,
                host: "127.0.0.1",
                port: port,
                password: "PUBLIC"
            )
        }

        let connected = try await EchoLinkProxyClient.connectFirstAvailable(
            configurations: candidates,
            callsign: "W1AW"
        )
        defer { connected.client.close() }

        XCTAssertEqual(connected.configuration.port, acceptingPort)
        await fulfillment(of: [authenticated], timeout: 2)
    }

    func testClientTimesOutWhenProxyNeverSendsAuthenticationNonce() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        let accepted = expectation(description: "proxy accepted connection")
        let queue = DispatchQueue(label: "EchoLinkProxyProtocolTests.silent-proxy")

        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            accepted.fulfill()
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 2)

        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = try EchoLinkProxyClient(
            host: "127.0.0.1",
            port: port,
            authenticationTimeout: 1.0
        )
        defer { client.close() }

        do {
            try await client.connect(callsign: "W1AW", password: "PUBLIC")
            XCTFail("Expected authentication timeout")
        } catch EchoLinkProxyClient.ClientError.authenticationTimedOut {
            // Expected.
        }
        await fulfillment(of: [accepted], timeout: 5)
    }

    func testSharedSessionCarriesDirectoryAndUDPOverOneAuthenticatedConnection() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        let authenticated = expectation(description: "authenticated once")
        let directoryOpened = expectation(description: "directory opened through proxy")
        let directoryPayload = expectation(description: "directory payload tunneled")
        let udpPayload = expectation(description: "QSO payload used same proxy connection")
        let queue = DispatchQueue(label: "EchoLinkProxyProtocolTests.shared-session")
        let nonce = Data("12345678".utf8)

        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.send(content: nonce, completion: .contentProcessed { error in
                XCTAssertNil(error)
                connection.receive(minimumIncompleteLength: 21, maximumLength: 21) { auth, _, _, error in
                    XCTAssertNil(error)
                    XCTAssertEqual(auth?.prefix(5), Data("W1AW\n".utf8))
                    authenticated.fulfill()
                    connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { open, _, _, error in
                        XCTAssertNil(error)
                        var openBuffer = open ?? Data()
                        let openMessage = try? EchoLinkProxyProtocol.parseAvailableMessages(from: &openBuffer).first
                        XCTAssertEqual(openMessage?.type, .tcpOpen)
                        XCTAssertEqual(openMessage?.remoteHost, "127.0.0.1")
                        directoryOpened.fulfill()
                        let status = try! EchoLinkProxyProtocol.encode(
                            type: .tcpStatus, remoteHost: "0.0.0.0", payload: Data(repeating: 0, count: 4)
                        )
                        connection.send(content: status, completion: .contentProcessed { error in
                            XCTAssertNil(error)
                            connection.receive(minimumIncompleteLength: 10, maximumLength: 4096) { data, _, _, error in
                                XCTAssertNil(error)
                                var dataBuffer = data ?? Data()
                                let request = try? EchoLinkProxyProtocol.parseAvailableMessages(from: &dataBuffer).first
                                XCTAssertEqual(request?.type, .tcpData)
                                XCTAssertTrue(request?.payload.starts(with: Data("-LOGIN\n".utf8)) == true)
                                XCTAssertNotNil(request?.payload.range(of: Data("W1AW".utf8)))
                                XCTAssertNil(request?.payload.range(of: Data("SECRET".utf8)))
                                directoryPayload.fulfill()
                                let response = try! EchoLinkProxyProtocol.encode(
                                    type: .tcpData, remoteHost: "0.0.0.0", payload: Data("LOGIN-RESULT\nresult:success\n\n".utf8)
                                )
                                connection.send(content: response, completion: .contentProcessed { error in
                                    XCTAssertNil(error)
                                    connection.receive(minimumIncompleteLength: 9, maximumLength: 4096) { closeAndUDP, _, _, error in
                                        XCTAssertNil(error)
                                        var buffer = closeAndUDP ?? Data()
                                        let messages = try? EchoLinkProxyProtocol.parseAvailableMessages(from: &buffer)
                                        let close = messages?.first { $0.type == .tcpClose }
                                        XCTAssertEqual(close?.remoteHost, "0.0.0.0")
                                        XCTAssertEqual(close?.payload, Data())
                                        if messages?.contains(where: { $0.type == .udpControl && $0.payload == Data([1, 2, 3]) }) == true {
                                            udpPayload.fulfill()
                                        } else {
                                            connection.receive(minimumIncompleteLength: 9, maximumLength: 4096) { udp, _, _, error in
                                                XCTAssertNil(error)
                                                var udpBuffer = udp ?? Data()
                                                let message = try? EchoLinkProxyProtocol.parseAvailableMessages(from: &udpBuffer).first
                                                XCTAssertEqual(message?.type, .udpControl)
                                                XCTAssertEqual(message?.payload, Data([1, 2, 3]))
                                                udpPayload.fulfill()
                                            }
                                        }
                                    }
                                })
                            }
                        })
                    }
                }
            })
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 2)

        let port = try XCTUnwrap(listener.port?.rawValue)
        let configuration = EchoLinkProxyConfiguration(
            mode: .customProxy, host: "127.0.0.1", port: port, password: "secret"
        )
        let session = try await EchoLinkProxySession.connect(configurations: [configuration], callsign: "W1AW")
        defer { Task { await session.close() } }
        let directory = DirectoryClient()
        await directory.setProxySession(session)
        try await directory.login(
            callsign: "W1AW", password: "secret", host: "127.0.0.1"
        )
        try await session.sendControl(Data([1, 2, 3]), to: "192.0.2.1")

        await fulfillment(
            of: [authenticated, directoryOpened, directoryPayload, udpPayload], timeout: 3
        )
    }

    func testSharedSessionRejectsOverlappingDirectoryTransactionsWhileOpenIsPending() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        let openReceived = expectation(description: "first directory open received")
        let lateStatusAttempted = expectation(description: "late TCP status attempted")
        let queue = DispatchQueue(label: "EchoLinkProxyProtocolTests.overlap")

        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.send(content: Data("12345678".utf8), completion: .contentProcessed { error in
                XCTAssertNil(error)
                connection.receive(minimumIncompleteLength: 21, maximumLength: 21) { _, _, _, error in
                    XCTAssertNil(error)
                    connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { frame, _, _, error in
                        XCTAssertNil(error)
                        var buffer = frame ?? Data()
                        let message = try? EchoLinkProxyProtocol.parseAvailableMessages(from: &buffer).first
                        XCTAssertEqual(message?.type, .tcpOpen)
                        openReceived.fulfill()
                        // Deliver TCP_STATUS after the request timeout. The client
                        // must retire this socket so it cannot poison a later open.
                        queue.asyncAfter(deadline: .now() + 0.3) {
                            let status = try! EchoLinkProxyProtocol.encode(
                                type: .tcpStatus,
                                remoteHost: "0.0.0.0",
                                payload: Data(repeating: 0, count: 4)
                            )
                            connection.send(content: status, completion: .contentProcessed { _ in
                                lateStatusAttempted.fulfill()
                            })
                        }
                    }
                }
            })
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 2)

        let configuration = EchoLinkProxyConfiguration(
            mode: .customProxy,
            host: "127.0.0.1",
            port: try XCTUnwrap(listener.port?.rawValue),
            password: "secret"
        )
        let session = try await EchoLinkProxySession.connect(
            configurations: [configuration], callsign: "W1AW"
        )
        defer { Task { await session.close() } }
        let first = Task {
            try await session.directoryRequest(
                Data("first".utf8),
                host: "127.0.0.1",
                boundary: .line,
                timeout: .milliseconds(200)
            )
        }
        await fulfillment(of: [openReceived], timeout: 2)

        do {
            _ = try await session.directoryRequest(
                Data("second".utf8), host: "127.0.0.1", boundary: .line
            )
            XCTFail("Expected the overlapping directory transaction to be rejected")
        } catch EchoLinkProxySession.SessionError.directoryBusy {
            // Expected.
        }
        _ = try? await first.value
        await fulfillment(of: [lateStatusAttempted], timeout: 2)

        do {
            _ = try await session.directoryRequest(
                Data("third".utf8), host: "127.0.0.1", boundary: .line
            )
            XCTFail("Expected the timed-out proxy session to remain retired")
        } catch EchoLinkProxySession.SessionError.directoryClosed {
            // Expected. A fresh authenticated session is required.
        }
    }
}

private final class DeferredProxyConnection: @unchecked Sendable {
    private let queue: DispatchQueue
    private var connections: [NWConnection] = []

    init(queue: DispatchQueue) { self.queue = queue }

    // Called by the listener on this queue.
    @discardableResult
    func accept(_ connection: NWConnection) -> Int {
        connections.append(connection)
        connection.start(queue: queue)
        return connections.count
    }

    func issueChallenge(at index: Int = 0) {
        queue.sync {
            connections[index].send(content: Data("12345678".utf8), completion: .contentProcessed { _ in })
        }
    }

    func close() {
        queue.sync {
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }
}
