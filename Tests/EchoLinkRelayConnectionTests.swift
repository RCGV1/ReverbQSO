// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

@MainActor
final class EchoLinkRelayConnectionTests: XCTestCase {
    func testCurrentDirectoryRelayMarkerRejectsSavedStationBeforeTransportSetup() async {
        var transportLookups = 0
        let service = EchoLinkConnectionService(networkConfigurationProvider: {
            transportLookups += 1
            // Regression failures also stop locally, before opening any sockets.
            return .init(mode: .automatic, host: "", port: 8100, password: "")
        })
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        let saved = Station(callsign: "K1MOCK", ipAddress: "192.0.2.1", nodeNumber: 123)
        let current = Station(callsign: "K1MOCK", description: "Mobile [r] [ON 12:34]", ipAddress: "192.0.2.2", nodeNumber: 123)
        service.resolveStation = { StationEndpointResolver.resolve($0, from: [current]) }
        await service.connect(to: saved)
        XCTAssertEqual(transportLookups, 0)
        XCTAssertNil(service.session)
        XCTAssertNil(service.reconnectCandidate)
        XCTAssertEqual(service.error?.localizedDescription, "Connection failed: This station cannot receive calls.")
    }

    func testDirectPeerAdvertisedAudioPortAndControlSourceAreHonored() async throws {
        let peerControl = try BoundUDPSocket(localPort: 0)
        defer { peerControl.close() }
        let peerAudio = try BoundUDPSocket(localPort: 0)
        defer { peerAudio.close() }
        let peerReplyControl = try BoundUDPSocket(localPort: 0)
        defer { peerReplyControl.close() }
        let service = EchoLinkConnectionService(
            networkConfigurationProvider: { .init(mode: .direct, host: "", port: 8100, password: "") })
        service.authenticatedCallsign = "N0TST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        service.setBackgroundMuted(true)
        let chatReceived = expectation(description: "Chat reached advertised audio endpoint")
        let byeReceived = expectation(description: "BYE reached learned control source")
        let server = Task {
            let handshake = try await peerControl.receive()
            let reply = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "K1MOCK-R",
                audioPort: peerAudio.actualLocalPort, advertiseSpeex: false)
            try await peerReplyControl.send(reply, to: handshake.sourceHost, port: handshake.sourcePort)
            while true {
                let chat = try await peerAudio.receive()
                if EchoLinkControlPacketCodec.parseEvents(from: chat.data).contains(where: {
                    if case .chat = $0 { return true }; return false
                }) { break }
            }
            chatReceived.fulfill()
            while true {
                let control = try await peerReplyControl.receive()
                if EchoLinkControlPacketCodec.parseEvents(from: control.data).contains(where: {
                    if case .bye = $0 { return true }; return false
                }) { byeReceived.fulfill(); break }
            }
        }
        defer { server.cancel() }
        await service.connect(to: Station(callsign: "K1MOCK-R", ipAddress: "127.0.0.1",
            port: Int(peerControl.actualLocalPort) - 1, type: .repeater))
        XCTAssertEqual(service.session?.state, .connected)
        await service.sendChat(message: "Local endpoint regression")
        await fulfillment(of: [chatReceived], timeout: 3)
        await service.disconnect()
        await fulfillment(of: [byeReceived], timeout: 3)
        // Close sockets before awaiting the fixture so a failed expectation
        // cannot strand it in a receive indefinitely.
        peerControl.close()
        peerAudio.close()
        peerReplyControl.close()
        try await server.value
    }

    func testReceptionReportsKeepConnectedPeerAliveButDoNotAcknowledgeHandshake() async throws {
        let service = EchoLinkConnectionService()
        service.setBackgroundMuted(true)
        service.session = QSOSession(station: Station(callsign: "K1MOCK", ipAddress: "127.0.0.1"),
                                     state: .connecting)
        let rr = Data([0xC0, 201, 0, 1, 0, 0, 0, 1])
        await service.handleAudioData(rr)
        XCTAssertEqual(service.session?.state, .connecting)
        await service.handleAudioData(EchoLinkControlPacketCodec.buildSDESPacket(callsign: "K1MOCK"))
        try await Task.sleep(for: .seconds(25))
        await service.handleAudioData(rr)
        try await Task.sleep(for: .seconds(30))
        XCTAssertEqual(service.session?.state, .connected)
        await service.disconnect()
    }

    func testImmediateRetryKeepsItsOwnCancellableAttempt() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let service = EchoLinkConnectionService(
            relayClientFactory: { EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort) },
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") }
        )
        service.authenticatedCallsign = "N0TST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        service.setBackgroundMuted(true)
        let firstRegistered = expectation(description: "First attempt sent")
        let secondRegistered = expectation(description: "Retry sent")
        let firstEnded = expectation(description: "First attempt cancelled")
        let secondEnded = expectation(description: "Retry cancelled")
        let server = Task {
            _ = try await relay.receive()
            firstRegistered.fulfill()
            _ = try await relay.receive()
            secondRegistered.fulfill()
        }
        let first = Task {
            await service.connect(to: Station(callsign: "K1MOCK", ipAddress: "198.51.100.10"))
            firstEnded.fulfill()
        }
        defer { first.cancel(); server.cancel() }
        await fulfillment(of: [firstRegistered], timeout: 3)
        let firstSessionID = service.session?.id
        service.cancelPendingConnection()
        let second = Task {
            await service.connect(to: Station(callsign: "K2MOCK", ipAddress: "198.51.100.11"))
            secondEnded.fulfill()
        }
        defer { second.cancel() }
        await fulfillment(of: [firstEnded, secondRegistered], timeout: 3)
        XCTAssertNotEqual(service.session?.id, firstSessionID)
        XCTAssertEqual(service.session?.station.callsign, "K2MOCK")
        XCTAssertEqual(service.session?.state, .connecting)
        service.cancelPendingConnection()
        await fulfillment(of: [secondEnded], timeout: 1)
        second.cancel()
        await first.value
        await second.value
        try await server.value
        XCTAssertNil(service.session)
        XCTAssertNil(service.error)
        XCTAssertNil(service.reconnectCandidate)
    }

    func testCancelDuringRelayRegistrationStopsAttemptWithoutWaitingForTimeout() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let service = EchoLinkConnectionService(
            relayClientFactory: { EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort) },
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") }
        )
        service.authenticatedCallsign = "N0TST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        service.setBackgroundMuted(true)
        let registrationSent = expectation(description: "Relay registration sent")
        let attemptEnded = expectation(description: "Cancelled attempt returned promptly")
        let server = Task {
            _ = try await relay.receive()
            registrationSent.fulfill()
            // A stalled relay never acknowledges the registration.
        }
        let operation = Task {
            await service.connect(to: Station(callsign: "K1MOCK", ipAddress: "198.51.100.10"))
            attemptEnded.fulfill()
        }
        defer { operation.cancel(); server.cancel() }
        await fulfillment(of: [registrationSent], timeout: 3)
        XCTAssertEqual(service.session?.state, .connecting)
        service.cancelPendingConnection()
        await fulfillment(of: [attemptEnded], timeout: 1)
        operation.cancel()
        await operation.value
        try await server.value
        XCTAssertNil(service.session)
        XCTAssertNil(service.error)
        XCTAssertNil(service.reconnectCandidate)
    }

    func testExpiringPendingHandshakeTearsDownWithoutConnectionErrorOrReconnect() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let audio = AudioEngine()
        let service = EchoLinkConnectionService(
            relayClientFactory: { EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort) },
            networkConfigurationProvider: { EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "") },
            audioEngine: audio
        )
        service.authenticatedCallsign = "W1AW"
        let handshakeSent = expectation(description: "Unacknowledged peer handshake was sent")
        let server = Task {
            let registration = try await relay.receive()
            try await relay.send(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]),
                to: registration.sourceHost, port: registration.sourcePort)
            let request = try await relay.receive()
            XCTAssertEqual(request.data.first, EchoLinkRelayRequestType.data.rawValue)
            handshakeSent.fulfill()
            // Do not return peer SDES: the outgoing attempt must stay connecting.
        }
        let operation = Task { await service.connect(to: Station(callsign: "TEST", ipAddress: "198.51.100.10")) }
        defer { operation.cancel(); server.cancel() }
        await fulfillment(of: [handshakeSent], timeout: 3)
        XCTAssertEqual(service.session?.state, .connecting)
        service.cancelPendingConnection()
        operation.cancel()
        await operation.value
        try await server.value
        XCTAssertNil(service.session)
        XCTAssertNil(service.error)
        XCTAssertNil(service.reconnectCandidate)
        XCTAssertFalse(audio.isRunning)
        service.cancelPendingConnection() // Cleanup remains safe after completion.
    }

    func testCallerCancellationReleasesDirectPortsWithoutReconnect() async throws {
        let audio = AudioEngine()
        let service = EchoLinkConnectionService(
            networkConfigurationProvider: { EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "") },
            audioEngine: audio
        )
        service.authenticatedCallsign = "W1AW"
        let operation = Task { await service.connect(to: Station(callsign: "TEST", ipAddress: "127.0.0.1")) }
        defer { operation.cancel() }
        // Let the service bind its sockets and enter the handshake polling wait.
        for _ in 0..<100 where service.session == nil { await Task.yield() }
        XCTAssertEqual(service.session?.state, .connecting)
        operation.cancel()
        await operation.value
        XCTAssertNil(service.session)
        XCTAssertNil(service.error)
        XCTAssertNil(service.reconnectCandidate)
        XCTAssertFalse(audio.isRunning)
        let audioPort = try BoundUDPSocket(localPort: 5198)
        defer { audioPort.close() }
        let controlPort = try BoundUDPSocket(localPort: 5199)
        defer { controlPort.close() }
    }

    func testAutomaticRelayPinsQSOAndReconnectToSelectedEndpoint() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let preference = EchoLinkProxyConfiguration(mode: .automatic, host: "", port: 8100, password: "PUBLIC")
        let effective = EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
        let selection = EchoLinkEffectiveTransport(preference: preference, configuration: effective, relayAddress: "127.0.0.1")
        var selectedEndpoints: [String] = []
        var advertisedEndpoints: [String] = []
        let service = EchoLinkConnectionService(
            relayClientFactory: { XCTFail("Automatic must not resolve a new relay"); return EchoLinkRelayClient() },
            selectedRelayClientFactory: { address in
                selectedEndpoints.append(address)
                return EchoLinkRelayClient(host: address, port: relay.actualLocalPort, resolvedIPv4Candidates: [address])
            },
            networkConfigurationProvider: { preference }
        )
        service.effectiveTransportProvider = { selection }
        service.authenticatedCallsign = "W1AW"
        service.prepareRelayDirectory = { _, address in advertisedEndpoints.append(address) }
        let station = Station(callsign: "TEST", ipAddress: "198.51.100.10")
        let server = Task {
            var completed = 0
            var awaitingHandshake = false
            while completed < 2 {
                let request = try await relay.receive()
                if request.data.first == EchoLinkRelayRequestType.register.rawValue {
                    awaitingHandshake = true
                    try await relay.send(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]), to: request.sourceHost, port: request.sourcePort)
                } else if awaitingHandshake, request.data.first == EchoLinkRelayRequestType.data.rawValue {
                    awaitingHandshake = false
                    let sdes = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "TEST")
                    try await relay.send(Data([1, 198, 51, 100, 10, 0, 0, 0x14, 0x4F]) + sdes,
                        to: request.sourceHost, port: request.sourcePort)
                    completed += 1
                }
            }
        }
        await service.connect(to: station)
        XCTAssertEqual(service.session?.state, .connected)
        await service.disconnect()
        await service.connect(to: station)
        XCTAssertEqual(service.session?.state, .connected)
        try await server.value
        XCTAssertEqual(selectedEndpoints, ["127.0.0.1", "127.0.0.1"])
        XCTAssertEqual(advertisedEndpoints, selectedEndpoints)
        await service.disconnect()
    }

    func testQSOHandshakeOverLocalRelay() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let client = EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort)
        let service = EchoLinkConnectionService(
            relayClientFactory: { client },
            networkConfigurationProvider: {
                EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
            }
        )
        service.authenticatedCallsign = "W1AW"
        let station = Station(
            callsign: "*ECHOTEST*",
            ipAddress: "198.51.100.10",
            type: .conference,
            nodeNumber: 9999
        )

        let server = Task { [relay] in
            let registration = try await relay.receive()
            XCTAssertEqual(registration.data, try EchoLinkRelayProtocol.register(callsign: "W1AW"))
            try await relay.send(
                Data([EchoLinkRelayResponseType.ack.rawValue, 0, 0, 0, 0, 0, 0, 0, 0]),
                to: registration.sourceHost,
                port: registration.sourcePort
            )

            let request = try await relay.receive()
            XCTAssertEqual(request.data.first, EchoLinkRelayRequestType.data.rawValue)
            XCTAssertEqual(Array(request.data[1...6]), [198, 51, 100, 10, 0x14, 0x4F])
            let remoteSDES = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "*ECHOTEST*")
            let response = Data([1, 198, 51, 100, 10, 0xC3, 0x50, 0x14, 0x4F]) + remoteSDES
            try await relay.send(response, to: registration.sourceHost, port: registration.sourcePort)
        }

        await service.connect(to: station)
        try await server.value
        XCTAssertEqual(service.session?.state, .connected)
        XCTAssertNil(service.error)
        await service.disconnect()
        XCTAssertNil(service.session)
    }

    func testAllocationErrorRefreshesRegistrationDuringConnectedQSO() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let client = EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort)
        let service = EchoLinkConnectionService(
            relayClientFactory: { client },
            networkConfigurationProvider: {
                EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
            }
        )
        service.authenticatedCallsign = "W1AW"
        let station = Station(callsign: "*ECHOTEST*", ipAddress: "198.51.100.10", type: .conference)

        let server = Task { [relay] in
            let registration = try await relay.receive()
            try await relay.send(
                Data([EchoLinkRelayResponseType.ack.rawValue, 0, 0, 0, 0, 0, 0, 0, 0]),
                to: registration.sourceHost, port: registration.sourcePort
            )
            _ = try await relay.receive() // Outbound SDES.
            let sdes = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "*ECHOTEST*")
            try await relay.send(
                Data([1, 198, 51, 100, 10, 0xC3, 0x50, 0x14, 0x4F]) + sdes,
                to: registration.sourceHost, port: registration.sourcePort
            )
            return (registration.sourceHost, registration.sourcePort)
        }

        await service.connect(to: station)
        let (host, port) = try await server.value
        XCTAssertEqual(service.session?.state, .connected)

        let refreshed = expectation(description: "Relay callsign registration refreshed")
        let receive = Task { [relay] in
            while !Task.isCancelled {
                let datagram = try await relay.receive()
                if datagram.data.first == EchoLinkRelayRequestType.register.rawValue {
                    XCTAssertEqual(datagram.data, try EchoLinkRelayProtocol.register(callsign: "W1AW"))
                    refreshed.fulfill()
                    break
                }
            }
        }
        try await relay.send(
            Data([EchoLinkRelayResponseType.error.rawValue, 198, 51, 100, 10, 0x14, 0x4F, 0x14, 0x4F, 1]),
            to: host, port: port
        )
        await fulfillment(of: [refreshed], timeout: 3)
        XCTAssertEqual(service.session?.state, .connected)
        receive.cancel()
        await service.disconnect()
    }
}
