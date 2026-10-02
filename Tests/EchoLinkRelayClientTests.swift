// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class EchoLinkRelayClientTests: XCTestCase {
    private let ack = Data([4, 0, 0, 0, 0, 0, 0, 0, 0])

    func testLocalRelayRegistrationDataAndClose() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let client = EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort)
        let acknowledgement = ack

        let server = Task { [relay, acknowledgement] in
            let registration = try await relay.receive()
            XCTAssertEqual(registration.data, try EchoLinkRelayProtocol.register(callsign: "N0CALL-L"))
            try await relay.send(acknowledgement, to: registration.sourceHost, port: registration.sourcePort)

            let voice = try await relay.receive()
            XCTAssertEqual(voice.data, Data([1, 198, 51, 100, 10, 0x14, 0x4E, 0xBE, 0xEF]))
            let reply = Data([1, 198, 51, 100, 10, 0x14, 0x4E, 0x14, 0x4E, 0x12, 0x34])
            try await relay.send(reply, to: registration.sourceHost, port: registration.sourcePort)

            let firstClose = try await relay.receive()
            let secondClose = try await relay.receive()
            return [firstClose.data.first, secondClose.data.first]
        }
        let stream = try await client.connect(callsign: "N0CALL-L")
        try await client.sendData(Data([0xBE, 0xEF]), to: "198.51.100.10", port: 5198)
        var iterator = stream.makeAsyncIterator()
        let response = try await iterator.next()
        XCTAssertEqual(response?.type, .data)
        XCTAssertEqual(response?.payload, Data([0x12, 0x34]))
        await client.close()
        let closeTypes = try await server.value
        XCTAssertEqual(closeTypes, [EchoLinkRelayRequestType.dropFlow.rawValue, EchoLinkRelayRequestType.unregister.rawValue])
    }

    func testRegistrationRetriesAfterTimeout() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let timing = EchoLinkRelayTiming(ackTimeout: .milliseconds(100), registrationAttempts: 2,
                                        keepaliveInterval: .seconds(20), registrationInterval: .seconds(300))
        let client = EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort, timing: timing)
        let acknowledgement = ack
        let server = Task { [relay, acknowledgement] in
            let first = try await relay.receive()
            let second = try await relay.receive()
            XCTAssertEqual(first.data, second.data)
            try await relay.send(acknowledgement, to: second.sourceHost, port: second.sourcePort)
        }
        _ = try await client.connect(callsign: "N0CALL-L")
        try await server.value
        await client.close()
    }

    func testRegistrationFallsBackToSecondIPv4CandidateOnSameSocket() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let timing = EchoLinkRelayTiming(ackTimeout: .milliseconds(100), registrationAttempts: 1,
                                        keepaliveInterval: .seconds(20), registrationInterval: .seconds(300))
        let client = EchoLinkRelayClient(
            host: "relay.test", port: relay.actualLocalPort, timing: timing,
            resolvedIPv4Candidates: ["127.0.0.2", "127.0.0.1"]
        )
        let acknowledgement = ack
        let server = Task { [relay, acknowledgement] in
            let registration = try await relay.receive()
            XCTAssertEqual(registration.data, try EchoLinkRelayProtocol.register(callsign: "N0CALL-L"))
            try await relay.send(acknowledgement, to: registration.sourceHost, port: registration.sourcePort)
        }
        _ = try await client.connect(callsign: "N0CALL-L")
        try await server.value
        try await client.sendData(Data([0x51]), to: "198.51.100.10", port: 5198)
        let forwarded = try await relay.receive()
        XCTAssertEqual(forwarded.data.first, EchoLinkRelayRequestType.data.rawValue)
        await client.close()
    }

    func testUnexpectedSourceCannotCompleteRegistration() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        let spoof = try BoundUDPSocket(localPort: 0)
        defer { relay.close(); spoof.close() }
        let timing = EchoLinkRelayTiming(ackTimeout: .milliseconds(150), registrationAttempts: 1,
                                        keepaliveInterval: .seconds(20), registrationInterval: .seconds(300))
        let client = EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort, timing: timing)
        let acknowledgement = ack
        let server = Task { [relay, spoof, acknowledgement] in
            let registration = try await relay.receive()
            try await spoof.send(acknowledgement, to: registration.sourceHost, port: registration.sourcePort)
        }
        do {
            _ = try await client.connect(callsign: "N0CALL-L")
            XCTFail("Spoofed ACK must not establish a relay session")
        } catch EchoLinkRelayClientError.registrationTimedOut {
            // Expected: only the configured relay endpoint may acknowledge registration.
        }
        try await server.value
        await client.close()
    }

    func testKeepaliveAndRegistrationRefreshUseLocalRelay() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let timing = EchoLinkRelayTiming(ackTimeout: .seconds(1), registrationAttempts: 1,
                                        keepaliveInterval: .milliseconds(80), registrationInterval: .milliseconds(120))
        let client = EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort, timing: timing)
        let acknowledgement = ack
        let server = Task { [relay, acknowledgement] in
            let registration = try await relay.receive()
            try await relay.send(acknowledgement, to: registration.sourceHost, port: registration.sourcePort)
            var sawKeepalive = false
            var sawRefresh = false
            for _ in 0..<8 {
                let packet = try await relay.receive()
                if packet.data.first == EchoLinkRelayRequestType.keepalive.rawValue {
                    XCTAssertEqual(Array(packet.data[1...6]), [198, 51, 100, 10, 0x14, 0x4F])
                    sawKeepalive = true
                }
                if packet.data.first == EchoLinkRelayRequestType.register.rawValue {
                    sawRefresh = true
                }
                if sawKeepalive && sawRefresh { break }
            }
            return (sawKeepalive, sawRefresh)
        }
        _ = try await client.connect(callsign: "N0CALL-L")
        try await client.sendData(Data([1]), to: "198.51.100.10", port: 5199)
        let seen = try await server.value
        XCTAssertTrue(seen.0)
        XCTAssertTrue(seen.1)
        await client.close()
    }

    func testAudioAndControlFlowsBothReceiveKeepalivesAndDrops() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let timing = EchoLinkRelayTiming(
            ackTimeout: .seconds(1), registrationAttempts: 1,
            keepaliveInterval: .milliseconds(80), registrationInterval: .seconds(300)
        )
        let client = EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort, timing: timing)
        let acknowledgement = ack
        let registration = Task { [relay, acknowledgement] in
            let request = try await relay.receive()
            try await relay.send(acknowledgement, to: request.sourceHost, port: request.sourcePort)
        }
        _ = try await client.connect(callsign: "N0CALL-L")
        try await registration.value
        try await client.sendData(Data([0xA1]), to: "198.51.100.10", port: 5198)
        try await client.sendData(Data([0xA2]), to: "198.51.100.10", port: 5199)

        var keepalivePorts: Set<UInt16> = []
        for _ in 0..<12 where keepalivePorts.count < 2 {
            let packet = try await receiveWithin(relay, duration: .seconds(2))
            if packet.data.first == EchoLinkRelayRequestType.keepalive.rawValue {
                keepalivePorts.insert((UInt16(packet.data[5]) << 8) | UInt16(packet.data[6]))
            }
        }
        XCTAssertEqual(keepalivePorts, [5198, 5199])

        await client.close()
        var droppedPorts: Set<UInt16> = []
        var sawUnregister = false
        for _ in 0..<12 where droppedPorts.count < 2 || !sawUnregister {
            let packet = try await receiveWithin(relay, duration: .seconds(2))
            if packet.data.first == EchoLinkRelayRequestType.dropFlow.rawValue {
                droppedPorts.insert((UInt16(packet.data[5]) << 8) | UInt16(packet.data[6]))
            } else if packet.data.first == EchoLinkRelayRequestType.unregister.rawValue {
                sawUnregister = true
            }
        }
        XCTAssertEqual(droppedPorts, [5198, 5199])
        XCTAssertTrue(sawUnregister)
    }

    func testCancelledRegistrationReleasesSocketForReconnect() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let timing = EchoLinkRelayTiming(ackTimeout: .seconds(3), registrationAttempts: 1,
                                        keepaliveInterval: .seconds(20), registrationInterval: .seconds(300))
        let client = EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort, timing: timing)
        let firstAttempt = Task { try await client.connect(callsign: "N0CALL-L") }
        _ = try await relay.receive()
        firstAttempt.cancel()
        do {
            _ = try await firstAttempt.value
            XCTFail("Cancelled registration must not establish a relay session")
        } catch is CancellationError {
            // Expected; connect must release its UDP socket.
        }

        let acknowledgement = ack
        let server = Task { [relay, acknowledgement] in
            let registration = try await relay.receive()
            try await relay.send(acknowledgement, to: registration.sourceHost, port: registration.sourcePort)
        }
        _ = try await client.connect(callsign: "N0CALL-L")
        try await server.value
        await client.close()
    }

    func testCloseStopsShortIntervalTimers() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let timing = EchoLinkRelayTiming(ackTimeout: .seconds(1), registrationAttempts: 1,
                                        keepaliveInterval: .milliseconds(60), registrationInterval: .milliseconds(90))
        let client = EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort, timing: timing)
        let acknowledgement = ack
        let server = Task { [relay, acknowledgement] in
            let registration = try await relay.receive()
            try await relay.send(acknowledgement, to: registration.sourceHost, port: registration.sourcePort)
        }
        _ = try await client.connect(callsign: "N0CALL-L")
        try await server.value
        try await client.sendData(Data([1]), to: "198.51.100.10", port: 5198)
        await client.close()

        var closeTypes: [UInt8] = []
        for _ in 0..<3 {
            let datagram = try await relay.receive()
            closeTypes.append(datagram.data[0])
        }
        XCTAssertEqual(closeTypes, [EchoLinkRelayRequestType.data.rawValue,
                                    EchoLinkRelayRequestType.dropFlow.rawValue,
                                    EchoLinkRelayRequestType.unregister.rawValue])
        do {
            _ = try await receiveWithin(relay, duration: .milliseconds(250))
            XCTFail("No timer should send after close")
        } catch is RelayTestTimeout {
            // Expected; both timer intervals elapsed without traffic.
        }
    }

    func testClientErrorsHaveActionableDescriptions() {
        let errors: [EchoLinkRelayClientError] = [.resolutionFailed, .registrationTimedOut,
                                                   .registrationRejected, .notConnected]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }
}

private struct RelayTestTimeout: Error {}

private func receiveWithin(_ relay: BoundUDPSocket, duration: Duration) async throws -> BoundUDPSocket.Datagram {
    try await withThrowingTaskGroup(of: BoundUDPSocket.Datagram.self) { group in
        group.addTask { try await relay.receive() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw RelayTestTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
