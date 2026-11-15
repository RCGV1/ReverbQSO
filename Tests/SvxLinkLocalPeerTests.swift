// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

@MainActor
final class SvxLinkLocalPeerTests: XCTestCase {
    func testLocalSvxLinkPeerAcceptsReorderedGSMAndDisconnectsOnBye() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        let audio = AudioEngine()
        let service = EchoLinkConnectionService(
            relayClientFactory: {
                EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort)
            },
            networkConfigurationProvider: {
                .init(mode: .relay, host: "", port: 8100, password: "")
            },
            audioEngine: audio
        )
        service.authenticatedCallsign = "N0TST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        service.setBackgroundMuted(true)

        let connected = expectation(description: "Local relay handshake completed")
        let accepted = expectation(description: "Four unique voice packets accepted")
        var acceptedMetadata: [EchoLinkVoicePacketMetadata?] = []
        service.onAuditAcceptedPacket = { metadata in
            acceptedMetadata.append(metadata)
            if acceptedMetadata.count == 4 { accepted.fulfill() }
        }

        // Both the transport and the simulated peer identity are localhost-only.
        let server = Task {
            let registration = try await Self.receive(from: relay)
            XCTAssertEqual(registration.sourceHost, "127.0.0.1")
            XCTAssertEqual(registration.data, try EchoLinkRelayProtocol.register(callsign: "N0TST"))
            try await relay.send(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]),
                to: registration.sourceHost, port: registration.sourcePort)

            let request = try await Self.receive(from: relay)
            let envelope = try EchoLinkRelayProtocol.encodeRequest(type: .data,
                destinationHost: "127.0.0.1", destinationPort: 5199)
            XCTAssertEqual(Data(request.data.prefix(7)), envelope)
            XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: Data(request.data.dropFirst(7)))
                .contains { if case .sdes = $0 { return true }; return false })
            let sdes = EchoLinkControlPacketCodec.buildSDESPacket(
                callsign: "K1MOCK-R", tool: "SvxLink", advertiseSpeex: true)
            try await relay.send(Self.response(sdes, port: 5199),
                to: registration.sourceHost, port: registration.sourcePort)
            return registration
        }
        let connection = Task {
            await service.connect(to: Station(callsign: "K1MOCK-R",
                ipAddress: "127.0.0.1", type: .repeater))
            connected.fulfill()
        }
        defer {
            relay.close()
            server.cancel()
            connection.cancel()
            service.onAuditAcceptedPacket = nil
        }

        do {
            let endpoint = try await server.value
            await fulfillment(of: [connected], timeout: 3)
            guard service.session?.state == .connected else {
                XCTFail("Local peer did not connect: \(String(describing: service.error))")
                throw FixtureError.handshakeFailed
            }
            XCTAssertNil(service.error)
            XCTAssertEqual(service.transmitCodec, .speex)
            XCTAssertFalse(audio.isRunning)

            let encoder = GSMCodec()
            let pcm = (0..<(4 * GSMCodec.samplesPerFrame)).map {
                Int16($0 % 40 < 20 ? 8_000 : -8_000)
            }
            let payload = try XCTUnwrap(GSMCodec.stripHeader(encoder.encode(pcm)))
            XCTAssertEqual(payload.count, 4 * GSMCodec.encodedFrameSize)
            // SvxLink legacy packets keep timestamp and SSRC at zero.
            for sequence: UInt16 in [100, 100, 102, 101, 103] {
                let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                    gsmPayload: payload, sequence: sequence, timestamp: 0)
                try await relay.send(Self.response(packet, port: 5198),
                    to: endpoint.sourceHost, port: endpoint.sourcePort)
            }
            await fulfillment(of: [accepted], timeout: 3)
            XCTAssertEqual(acceptedMetadata.compactMap { $0?.sequenceNumber }, [100, 101, 102, 103])
            XCTAssertTrue(acceptedMetadata.allSatisfy {
                $0?.ssrc == 0 && $0?.timestamp == 0 && $0?.payloadType == 3
            })
            let diagnostics = await service.audioDiagnosticsSnapshot()
            XCTAssertEqual(service.auditTransportSnapshot["rxAccepted"], 4)
            XCTAssertEqual(diagnostics.rxPackets, 4)
            XCTAssertEqual(diagnostics.sequencedRXPackets, 4)
            XCTAssertEqual(diagnostics.duplicateOrLateRXPackets, 1)
            XCTAssertEqual(diagnostics.missingRXPackets, 0)
            XCTAssertEqual(diagnostics.invalidRXPackets, 0)
            XCTAssertEqual(diagnostics.rxQueuedPackets, 0)
            XCTAssertFalse(audio.isRunning)

            try await relay.send(Self.response(EchoLinkControlPacketCodec.buildBYEPacket(), port: 5199),
                to: endpoint.sourceHost, port: endpoint.sourcePort)
            for _ in 0..<300 where service.session != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(service.session, "Remote BYE must disconnect the QSO")
            XCTAssertFalse(audio.isRunning)
            await service.disconnect()
        } catch {
            relay.close()
            server.cancel()
            connection.cancel()
            await service.disconnect()
            throw error
        }
    }

    private enum FixtureError: Error {
        case receiveTimedOut
        case handshakeFailed
    }

    private nonisolated static func receive(from socket: BoundUDPSocket) async throws -> BoundUDPSocket.Datagram {
        try await withThrowingTaskGroup(of: BoundUDPSocket.Datagram.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                socket.close()
                throw FixtureError.receiveTimedOut
            }
            defer { group.cancelAll() }
            guard let datagram = try await group.next() else { throw FixtureError.receiveTimedOut }
            return datagram
        }
    }

    private static func response(_ payload: Data, port: UInt16) -> Data {
        Data([1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 0xFF),
              UInt8(port >> 8), UInt8(port & 0xFF)]) + payload
    }
}
