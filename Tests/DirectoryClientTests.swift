// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import CryptoKit
import Foundation
import Network
@testable import ReverbQSO

/// Tests for DirectoryClient login parsing and error handling.
///
/// These tests validate the client's response parsing logic. Since NWConnection
/// cannot be easily mocked, we test the parsing helpers and error types directly.
/// Full integration tests require a live EchoLink server connection.
final class DirectoryClientTests: XCTestCase {

    // MARK: - Error Type Tests

    func testLoginDeniedErrorDescription() {
        let error = DirectoryClientError.loginDenied
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("denied"))
    }

    func testConnectionFailedErrorDescription() {
        let error = DirectoryClientError.connectionFailed("timeout")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("timeout"))
    }

    func testTimeoutErrorDescription() {
        let error = DirectoryClientError.timeout
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("timed out"))
    }

    func testNotConnectedErrorDescription() {
        let error = DirectoryClientError.notConnected
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("not connected"))
    }

    func testUnexpectedResponseErrorDescription() {
        let error = DirectoryClientError.unexpectedResponse("GARBAGE")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("GARBAGE"))
    }

    // MARK: - Station Parser Integration

    /// Simulates parsing a successful directory server response.
    func testParseDirectoryResponse() {
        // Simulated server response after login
        let serverResponse = """
        L W6ABC 192.168.1.1 5200
        R W6DEF-R 192.168.1.2 5200
        C *BAYNET* 192.168.1.3 5200
        X W6BUSY 192.168.1.4 5200

        """

        let stations = StationParser.parseDirectory(raw: Data(serverResponse.utf8))
        XCTAssertEqual(stations.count, 4)

        // Verify first station
        XCTAssertEqual(stations[0].callsign, "W6ABC")
        XCTAssertEqual(stations[0].type, .link)
        XCTAssertFalse(stations[0].isBusy)

        // Verify busy station
        XCTAssertEqual(stations[3].callsign, "W6BUSY")
        XCTAssertTrue(stations[3].isBusy)
    }

    // MARK: - Login Response Validation

    func testLoginResponseAcceptsEchoLinkOKResponses() throws {
        XCTAssertNoThrow(try DirectoryLoginResponseValidator.validate("OK"))
        XCTAssertNoThrow(try DirectoryLoginResponseValidator.validate("  ok\r\n"))
        XCTAssertNoThrow(try DirectoryLoginResponseValidator.validate("OK2.5"))
        XCTAssertNoThrow(try DirectoryLoginResponseValidator.validate("ok3.38\r\n"))
    }

    func testLoginResponseRejectsEmptyAndNonOKResponses() {
        assertUnexpectedLoginResponse("")
        assertUnexpectedLoginResponse(" \r\n")
        assertUnexpectedLoginResponse("ON")
        assertUnexpectedLoginResponse("OKAY")
        assertUnexpectedLoginResponse("OK.2")
        assertUnexpectedLoginResponse("NOT OK")
        assertUnexpectedLoginResponse("WELCOME")
    }

    func testLoginResponseClassifiesDeniedResponse() {
        XCTAssertThrowsError(try DirectoryLoginResponseValidator.validate("INCORRECT PASSWORD\r\n")) { error in
            guard case DirectoryClientError.loginDenied = error else {
                return XCTFail("Expected loginDenied, got \(error)")
            }
        }

        XCTAssertThrowsError(try DirectoryLoginResponseValidator.validate("DENIED")) { error in
            guard case DirectoryClientError.loginDenied = error else {
                return XCTFail("Expected loginDenied, got \(error)")
            }
        }
    }

    func testLoginResponseClassifiesInUseResponse() {
        XCTAssertThrowsError(try DirectoryLoginResponseValidator.validate("CALLSIGN IN-USE")) { error in
            guard case DirectoryClientError.loginInUse = error else {
                return XCTFail("Expected loginInUse, got \(error)")
            }
        }
    }

    func testEnhancedLoginResponseClassifiesKnownDirectoryRejections() {
        let cases: [(String, (DirectoryClientError) -> Bool)] = [
            ("bad-password", { if case .loginDenied = $0 { return true }; return false }),
            ("not-validated", { if case .accountNotValidated = $0 { return true }; return false }),
            ("notfound", { if case .accountNotFound = $0 { return true }; return false }),
            ("barred", { if case .callsignBarred = $0 { return true }; return false })
        ]

        for (reason, matches) in cases {
            XCTAssertThrowsError(
                try DirectoryEnhancedLoginResponseValidator.validateFinal(
                    "LOGIN-RESULT\nresult:failure\nreason:\(reason)\n\n"
                )
            ) { error in
                guard let directoryError = error as? DirectoryClientError,
                      matches(directoryError) else {
                    return XCTFail("Unexpected classification for \(reason): \(error)")
                }
            }
        }
    }

    func testDirectLoginUsesChallengeHashWithoutSendingPlaintextPassword() async throws {
        let server = try LocalEnhancedDirectory(password: "MIXEDCASESECRET")
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let client = DirectoryClient(host: "127.0.0.1", port: port)

        try await client.login(
            callsign: "n0test",
            password: "MixedCaseSecret",
            description: "Test Location"
        )

        let requests = server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], "-LOGIN\ncallsign: N0TEST\nstatus: BUSY\nrtp-port: 0\nrtcp-port: 0\nclient-version: 1.0\nlocation: Test Location\nlocal-time: \(server.localTime(in: requests[0]))\ncode-page: none\nsw-tag: ReverbQSO\n\n")
        XCTAssertFalse(requests[0].contains("client-addr:"))
        XCTAssertFalse(requests[0].contains("hashed-password:"))
        XCTAssertTrue(requests[1].contains("hashed-password: 2DCAD91C03B025313A6C5AE47274FF8E\n"))
        XCTAssertFalse(requests.joined().uppercased().contains("MIXEDCASESECRET"))
    }

    func testLogoutUsesCallsignOnlyWireCommand() async throws {
        let server = try LocalEnhancedDirectory(password: "SECRET")
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let client = DirectoryClient(host: "127.0.0.1", port: port)

        try await client.login(callsign: "n0test", password: "SECRET")
        await client.logout()

        XCTAssertEqual(server.requests.last, "zN0TEST\r")
        XCTAssertFalse(server.requests.last?.contains("SECRET") ?? true)
    }

    func testStationDescriptionsContainingAuthWordsRemainDirectoryData() async throws {
        for description in ["DENIED access road", "INCORRECT PASSWORD help desk", "IN-USE repeater"] {
            for text in ["@@@\n1\nK6SAFE-R\n\(description)\n123\n192.0.2.1\n+++",
                         "K6SAFE-R\t192.0.2.1\t\(description)\n+++"] {
                let server = try LocalEnhancedDirectory(password: "SECRET", directoryChunks: [Data(text.utf8)])
                server.listener.start(queue: server.queue)
                defer { server.listener.cancel() }
                await fulfillment(of: [server.ready], timeout: 2)
                let client = DirectoryClient(host: "127.0.0.1", port: try XCTUnwrap(server.listener.port?.rawValue))
                try await client.login(callsign: "N0TEST", password: "SECRET")
                let stations = try await client.fetchStations()
                XCTAssertEqual(stations.map(\.callsign), ["K6SAFE-R"])
                XCTAssertEqual(stations.first?.description, description)
            }
        }
    }

    func testDirectCountedDirectoryWaitsPastDescriptionMarkersAndSplitTerminator() async throws {
        let chunks = ["@@@\r\n2\r\nK6FIRST-R\r\nCaf", "é +++ road\r\n123\r\n192.0.2.1\r\n",
                      "K6LAST-L\r\n+++\r\n456\r\n192.0.2.2\r\n+", "+", "+"]
            .map { $0.data(using: .isoLatin1)! }
        let server = try LocalEnhancedDirectory(password: "SECRET", directoryChunks: chunks)
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let client = DirectoryClient(host: "127.0.0.1", port: try XCTUnwrap(server.listener.port?.rawValue))
        try await client.login(callsign: "N0TEST", password: "SECRET")

        let stations = try await client.fetchStations()

        XCTAssertEqual(stations.map(\.callsign), ["K6FIRST-R", "K6LAST-L"])
        XCTAssertEqual(stations.first?.description, "Café +++ road")
        XCTAssertEqual(stations.last?.description, "+++")
    }

    func testDirectCountedDirectoryRejectsTruncatedAdvertisedCount() async throws {
        let server = try LocalEnhancedDirectory(password: "SECRET", directoryChunks: [
            Data("@@@\n2\nK6PART-R\nOne station only\n123\n192.0.2.1\n+++".utf8)
        ])
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let client = DirectoryClient(host: "127.0.0.1", port: try XCTUnwrap(server.listener.port?.rawValue))
        try await client.login(callsign: "N0TEST", password: "SECRET")
        do {
            _ = try await client.fetchStations()
            XCTFail("An incomplete counted response must never publish a partial directory")
        } catch DirectoryClientError.unexpectedResponse { }
    }

    func testDirectCountedDirectoryRejectsOversizedIncompleteResponse() async throws {
        let prefix = Data("@@@\n2\nK6PART-R\nL K6LEAK 192.0.2.1 5198\n123\n192.0.2.1\nK6NEXT-R\n".utf8)
        let server = try LocalEnhancedDirectory(password: "SECRET", directoryChunks: [
            prefix + Data(repeating: 65, count: 4_000_000)
        ])
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [server.ready], timeout: 2)
        let client = DirectoryClient(host: "127.0.0.1", port: try XCTUnwrap(server.listener.port?.rawValue))
        try await client.login(callsign: "N0TEST", password: "SECRET")
        do {
            _ = try await client.fetchStations()
            XCTFail("The response limit must fail without publishing the completed prefix")
        } catch DirectoryClientError.unexpectedResponse { }
    }

    func testDirectDirectoryStillClassifiesStandaloneAuthenticationErrors() async throws {
        for text in ["DENIED\r\n", "INCORRECT PASSWORD\r\n", "CALLSIGN IN-USE\r\n"] {
            let server = try LocalEnhancedDirectory(password: "SECRET", directoryChunks: [Data(text.utf8)])
            server.listener.start(queue: server.queue)
            defer { server.listener.cancel() }
            await fulfillment(of: [server.ready], timeout: 2)
            let client = DirectoryClient(host: "127.0.0.1", port: try XCTUnwrap(server.listener.port?.rawValue))
            try await client.login(callsign: "N0TEST", password: "SECRET")
            do {
                _ = try await client.fetchStations()
                XCTFail("Standalone authentication errors must remain errors")
            } catch {
                if text.contains("IN-USE") {
                    guard case DirectoryClientError.loginInUse = error else { return XCTFail("\(error)") }
                } else {
                    guard case DirectoryClientError.loginDenied = error else { return XCTFail("\(error)") }
                }
            }
        }
    }

    // MARK: - Registration Payloads

    func testEnhancedRegistrationPayloadOmitsPasswordAndClientAddressForDirectMode() {
        let payload = DirectoryEnhancedLoginPayloadBuilder.build(
            callsign: "N0CALL",
            status: "BUSY",
            clientAddress: nil,
            location: "ReverbQSO",
            timeHHMM: "12:34",
            passwordHash: nil
        )
        let request = String(decoding: payload, as: UTF8.self)
        XCTAssertEqual(
            request,
            "-LOGIN\ncallsign: N0CALL\nstatus: BUSY\nrtp-port: 0\nrtcp-port: 0\nclient-version: 1.0\nlocation: ReverbQSO\nlocal-time: 12:34\ncode-page: none\nsw-tag: ReverbQSO\n\n"
        )
        XCTAssertFalse(request.contains("SECRET"))
        XCTAssertFalse(request.contains("client-addr:"))
    }

    func testEnhancedRegistrationPayloadIncludesOnlyChallengeHash() {
        let payload = DirectoryEnhancedLoginPayloadBuilder.build(
            callsign: "N0CALL",
            status: "ONLINE",
            clientAddress: nil,
            location: "ReverbQSO",
            timeHHMM: "12:34",
            passwordHash: "ABCDEF0123456789"
        )
        let request = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(request.contains("status: ONLINE\n"))
        XCTAssertTrue(request.contains("hashed-password: ABCDEF0123456789\n"))
        XCTAssertFalse(request.contains("SECRET"))
    }

    func testEnhancedRelayRegistrationPayloadIncludesAdvertisedAddress() {
        let payload = DirectoryEnhancedLoginPayloadBuilder.build(
            callsign: "N0CALL",
            status: "BUSY",
            clientAddress: "198.51.100.7",
            location: "ReverbQSO",
            timeHHMM: "12:34",
            passwordHash: nil
        )
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("client-addr: 198.51.100.7\n"))
    }

    // MARK: - Lifecycle Policy

    func testLifecycleGenerationRejectsOlderOperations() {
        var generation = DirectoryLifecycleGeneration()
        let first = generation.advance()
        let second = generation.advance()

        XCTAssertFalse(generation.matches(first))
        XCTAssertTrue(generation.matches(second))
    }

    func testKeepAliveFailureTrackerRetiresAfterThreeConsecutiveFailures() {
        var tracker = DirectoryKeepAliveFailureTracker()

        XCTAssertFalse(tracker.recordFailure())
        XCTAssertFalse(tracker.recordFailure())
        XCTAssertTrue(tracker.recordFailure())
        XCTAssertEqual(tracker.consecutiveFailures, 3)
    }

    func testKeepAliveSuccessResetsConsecutiveFailures() {
        var tracker = DirectoryKeepAliveFailureTracker()

        XCTAssertFalse(tracker.recordFailure())
        XCTAssertFalse(tracker.recordFailure())
        tracker.recordSuccess()

        XCTAssertEqual(tracker.consecutiveFailures, 0)
        XCTAssertFalse(tracker.recordFailure())
    }

    func testRegistrationFailurePolicyImmediatelyRetiresProtocolRejections() {
        XCTAssertTrue(DirectoryRegistrationFailurePolicy.shouldRetireImmediately(DirectoryClientError.loginDenied))
        XCTAssertTrue(DirectoryRegistrationFailurePolicy.shouldRetireImmediately(DirectoryClientError.loginInUse))
        XCTAssertTrue(DirectoryRegistrationFailurePolicy.shouldRetireImmediately(DirectoryClientError.unexpectedResponse("NO")))
        XCTAssertTrue(DirectoryRegistrationFailurePolicy.shouldRetireImmediately(DirectoryClientError.notConnected))
    }

    func testRegistrationFailurePolicyRetriesTransportFailures() {
        XCTAssertFalse(DirectoryRegistrationFailurePolicy.shouldRetireImmediately(DirectoryClientError.timeout))
        XCTAssertFalse(DirectoryRegistrationFailurePolicy.shouldRetireImmediately(DirectoryClientError.connectionFailed("reset")))
    }

    func testOnlyCredentialOrAccountRejectionsRequireUserSignIn() {
        for error: DirectoryClientError in [.loginDenied, .accountNotValidated, .accountNotFound, .callsignBarred] {
            XCTAssertTrue(DirectoryRegistrationFailurePolicy.requiresUserSignIn(error))
        }
        for error: DirectoryClientError in [.loginInUse, .timeout, .connectionFailed("reset"), .notConnected, .unexpectedResponse("EOF")] {
            XCTAssertFalse(DirectoryRegistrationFailurePolicy.requiresUserSignIn(error))
        }
        XCTAssertFalse(DirectoryRegistrationFailurePolicy.requiresUserSignIn(URLError(.notConnectedToInternet)))
        XCTAssertFalse(DirectoryRegistrationFailurePolicy.requiresUserSignIn(nil))
    }

    // MARK: - MD5 Hash Verification

    /// Verify that our MD5 implementation produces correct hashes.
    func testMD5HashFormat() {
        // MD5("test") = 098f6bcd4621d373cade4e832627b4f6
        // We test via CryptoKit directly since the hash method is private
        let digest = Insecure.MD5.hash(data: Data("test".utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "098f6bcd4621d373cade4e832627b4f6")
    }

    // MARK: - GSM Codec Header Tests

    func testGSMPacketHeaderFormat() {
        let header = GSMCodec.packetHeader
        XCTAssertEqual(header.count, 4)
        XCTAssertEqual(header[0], 0xBE)
        XCTAssertEqual(header[1], 0xEF)
        XCTAssertEqual(header[2], 0xBE)
        XCTAssertEqual(header[3], 0xEF)
    }

    func testGSMCodecEncodeProducesCorrectSize() {
        let codec = GSMCodec()
        let samples = [Int16](repeating: 0, count: 320) // Two frames
        let encoded = codec.encode(samples)

        // 4-byte header + 2 frames * 33 bytes = 70 bytes
        XCTAssertEqual(encoded.count, 4 + 2 * GSMCodec.encodedFrameSize)
    }

    func testGSMCodecDecodeProducesCorrectSamples() {
        let codec = GSMCodec()
        let source = [Int16](repeating: 500, count: GSMCodec.samplesPerFrame)
        let packet = codec.encode(source)
        let decoded = codec.decode(packet)
        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame)
    }

    func testGSMCodecIsNotStub() {
        XCTAssertFalse(GSMCodec.isStubImplementation)
    }

    func testGSMCodecRoundTripProducesAudibleData() {
        let codec = GSMCodec()
        let source = (0..<GSMCodec.samplesPerFrame).map { i in
            Int16(((i % 32) - 16) * 1500)
        }

        let encoded = codec.encode(source)
        let decoded = codec.decode(encoded)

        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame)
        XCTAssertTrue(decoded.contains(where: { $0 != 0 }))
    }

    func testGSMStripHeader() {
        var packet = Data(GSMCodec.packetHeader)
        let payload = Data([0x01, 0x02, 0x03])
        packet.append(payload)

        let stripped = GSMCodec.stripHeader(packet)
        XCTAssertNotNil(stripped)
        XCTAssertEqual(stripped, payload)
    }

    func testGSMStripHeaderInvalidPacket() {
        let packet = Data([0x00, 0x00, 0x00, 0x00, 0x01])
        XCTAssertNil(GSMCodec.stripHeader(packet))
    }

    private func assertUnexpectedLoginResponse(
        _ response: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DirectoryLoginResponseValidator.validate(response),
            file: file,
            line: line
        ) { error in
            guard case DirectoryClientError.unexpectedResponse = error else {
                return XCTFail("Expected unexpectedResponse, got \(error)", file: file, line: line)
            }
        }
    }
}

private final class LocalEnhancedDirectory: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "DirectoryClientTests.enhanced-server")
    let ready = XCTestExpectation(description: "local enhanced directory ready")
    private let password: String
    private let directoryChunks: [Data]?
    private var recordedRequests: [String] = []
    var requests: [String] { queue.sync { recordedRequests } }

    init(password: String, directoryChunks: [Data]? = nil) throws {
        self.password = password.uppercased()
        self.directoryChunks = directoryChunks
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

    func localTime(in request: String) -> String {
        request.split(separator: "\n").first { $0.hasPrefix("local-time: ") }
            .map { String($0.dropFirst("local-time: ".count)) } ?? ""
    }

    private func sendDirectory(_ chunks: [Data], index: Int, on connection: NWConnection) {
        guard index < chunks.count else { connection.cancel(); return }
        let final = index == chunks.count - 1
        connection.send(content: chunks[index], contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if final { connection.cancel() }
            else {
                self.queue.asyncAfter(deadline: .now() + 0.04) {
                    self.sendDirectory(chunks, index: index + 1, on: connection)
                }
            }
        })
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let bytes = buffered + data
            let request = String(decoding: bytes, as: UTF8.self)
            guard request.hasSuffix("\n\n") || request.hasPrefix("z") || request == "s" else {
                self.receive(connection, buffered: bytes)
                return
            }
            self.recordedRequests.append(request)
            if request == "s", let chunks = self.directoryChunks {
                self.sendDirectory(chunks, index: 0, on: connection)
                return
            }
            let response: String
            if request.hasPrefix("-LOGIN") {
                if let hash = request.split(separator: "\n").first(where: { $0.hasPrefix("hashed-password: ") }) {
                    let actual = String(hash.dropFirst("hashed-password: ".count))
                    let expected = Insecure.MD5.hash(data: Data((self.password + "local-test").utf8))
                        .map { String(format: "%02X", $0) }.joined()
                    response = actual == expected
                        ? "LOGIN-RESULT\nresult:success\n\n"
                        : "LOGIN-RESULT\nresult:failure\nreason:bad-password\n\n"
                } else {
                    response = "LOGIN-RESULT\nchallenge:local-test\n\n"
                }
            } else {
                response = "OK\r\n"
            }
            connection.send(
                content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }
}
