// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

@MainActor
final class EchoLinkRelayConnectionTests: XCTestCase {
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
