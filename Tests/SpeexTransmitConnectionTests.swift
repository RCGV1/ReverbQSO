// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ReverbQSO

@MainActor
final class SpeexTransmitConnectionTests: XCTestCase {
    private enum Timeout: Error { case expired }

    func testSpeexPTTOverLocalRelayPreservesPacketsAndFlushesTail() async throws {
        try await exerciseTransmission(speexPeer: true)
    }

    func testGSMOnlyPeerStillReceivesGSMOverLocalRelay() async throws {
        try await exerciseTransmission(speexPeer: false)
    }

    func testRemoteDTMFSendsOrderedTonePacketsToGSMAndSpeexPeers() async throws {
        for speexPeer in [false, true] {
            let relay = try BoundUDPSocket(localPort: 0)
            defer { relay.close() }
            let service = EchoLinkConnectionService(
                relayClientFactory: { EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort) },
                networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") })
            service.authenticatedCallsign = "N0TST"
            service.callAccessPolicyProvider = { CallAccessPolicy() }
            let server = Task {
                let registration = try await relay.receive()
                try await relay.send(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]),
                                     to: registration.sourceHost, port: registration.sourcePort)
                _ = try await relay.receive()
                var response = EchoLinkControlPacketCodec.buildSDESPacket(
                    callsign: "K1MOCK-R", advertiseSpeex: speexPeer)
                let capability = try XCTUnwrap(response.range(of: Data("D0".utf8)))
                response.replaceSubrange(capability, with: Data("D1".utf8))
                try await relay.send(Data([1, 198, 51, 100, 10, 0xC3, 0x50, 0x14, 0x4F]) + response,
                                     to: registration.sourceHost, port: registration.sourcePort)
                var packets: [Data] = []
                while packets.count < 4 {
                    let datagram = try await relay.receive()
                    guard datagram.data.count >= 19,
                          datagram.data[5] == 0x14, datagram.data[6] == 0x4E else { continue }
                    let packet = Data(datagram.data.dropFirst(7))
                    guard EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet) != nil else { continue }
                    packets.append(packet)
                }
                return packets
            }
            defer { server.cancel() }
            await service.connect(to: Station(callsign: "K1MOCK-R", ipAddress: "198.51.100.10", type: .repeater))
            XCTAssertEqual(service.session?.state, .connected)
            XCTAssertTrue(service.canSendRemoteDTMF)
            service.sendRemoteDTMF("5#")
            let packets = try await withThrowingTaskGroup(of: [Data].self) { group in
                group.addTask { try await server.value }
                group.addTask { try await Task.sleep(for: .seconds(5)); throw Timeout.expired }
                defer { group.cancelAll(); server.cancel() }
                let received = try await group.next()
                return try XCTUnwrap(received)
            }
            let tones = try EchoLinkDTMFToneGenerator.generate("5#")
            let reference = GSMCodec()
            var previous: EchoLinkVoicePacketMetadata?
            for (index, packet) in packets.enumerated() {
                let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet))
                guard case .gsm(let payload) = parsed.packet else { return XCTFail("Remote keypad must use GSM") }
                let offset = index * 640
                XCTAssertEqual(payload, GSMCodec.stripHeader(reference.encode(Array(tones[offset..<(offset + 640)]))))
                let metadata = try XCTUnwrap(parsed.metadata)
                if let previous {
                    XCTAssertEqual(metadata.sequenceNumber, previous.sequenceNumber &+ 1)
                    XCTAssertEqual(metadata.timestamp, previous.timestamp &+ 640)
                }
                previous = metadata
            }
            for _ in 0..<100 where service.isSendingDTMF { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(service.isSendingDTMF)
            await service.disconnect()
        }
    }

    func testOldSendCompletionCannotChangeReplacementSessionCounters() async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let engine = AudioEngine()
        let service = EchoLinkConnectionService(
            relayClientFactory: { EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort) },
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            audioEngine: engine)
        service.authenticatedCallsign = "N0TST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        let server = Task {
            let registration = try await relay.receive()
            try await relay.send(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]),
                                 to: registration.sourceHost, port: registration.sourcePort)
            _ = try await relay.receive()
            let response = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "K1MOCK", advertiseSpeex: false)
            try await relay.send(Data([1, 198, 51, 100, 10, 0xC3, 0x50, 0x14, 0x4F]) + response,
                                 to: registration.sourceHost, port: registration.sourcePort)
        }
        defer { server.cancel() }
        await service.connect(to: Station(callsign: "K1MOCK", ipAddress: "198.51.100.10"))
        XCTAssertEqual(service.session?.state, .connected)
        let paused = expectation(description: "Actual voice datagram sent before completion")
        let gate = SendCompletionPause()
        defer { gate.resume() }
        service.onAuditOutgoingDatagramSent = {
            paused.fulfill()
            await gate.pause()
        }
        service.sendPTT(active: true)
        engine.encodeTransmitPCM(Array(repeating: Int16(1_000), count: 640))
        await fulfillment(of: [paused], timeout: 3)
        let oldDrain = try XCTUnwrap(service.auditAudioSendDrainTask)
        await service.disconnect()
        service.installSimulatorDemoSession(station: Station(callsign: "NEXT", ipAddress: "192.0.2.2"))
        let replacementID = service.session?.id
        service.onAuditOutgoingDatagramSent = nil
        gate.resume()
        await oldDrain.value
        let diagnostics = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(service.session?.id, replacementID)
        XCTAssertEqual(diagnostics.txPackets, 0)
        XCTAssertEqual(diagnostics.txPayloadBytes, 0)
        await service.disconnect()
    }

    func testCapabilityIsStickyButResetsOnDisconnectAndMediaDoesNotEnableIt() async throws {
        let engine = AudioEngine()
        let service = EchoLinkConnectionService(audioEngine: engine)
        service.session = QSOSession(station: Station(callsign: "N0TST", ipAddress: "127.0.0.1"), state: .connected)
        XCTAssertEqual(service.transmitCodec, .gsm)
        await service.handleAudioData(EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: SpeexCodecTests.fixture, sequence: 1, codec: .speex))
        XCTAssertEqual(service.transmitCodec, .gsm, "Receive support alone must not authorize Speex TX")
        await service.handleAudioData(EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0TST"))
        XCTAssertEqual(service.transmitCodec, .speex)
        await service.handleAudioData(EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0TST", advertiseSpeex: false))
        XCTAssertEqual(service.transmitCodec, .speex)
        await service.disconnect()
        XCTAssertEqual(service.transmitCodec, .gsm)
    }

    private func exerciseTransmission(speexPeer: Bool) async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let engine = AudioEngine()
        let service = EchoLinkConnectionService(
            relayClientFactory: { EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort) },
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
            audioEngine: engine)
        service.authenticatedCallsign = "N0TST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        let server = Task {
            let registration = try await relay.receive()
            try await relay.send(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]),
                                 to: registration.sourceHost, port: registration.sourcePort)
            let request = try await relay.receive()
            let advertised = EchoLinkControlPacketCodec.parseEvents(from: Data(request.data.dropFirst(7)))
            guard case .sdes(let info) = advertised.first else { throw Timeout.expired }
            XCTAssertEqual(info.privateItems.first, "SPEEX")
            let response = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "K1MOCK", advertiseSpeex: speexPeer)
            try await relay.send(Data([1, 198, 51, 100, 10, 0xC3, 0x50, 0x14, 0x4F]) + response,
                                 to: registration.sourceHost, port: registration.sourcePort)
            var packets: [Data] = []
            while packets.count < 3 {
                let datagram = try await relay.receive()
                guard datagram.data.count >= 19, datagram.data[5] == 0x14, datagram.data[6] == 0x4E else { continue }
                let packet = Data(datagram.data.dropFirst(7))
                guard packet[0] == 0xC0, packet[1] == 0x96 || packet[1] == 3 else { continue }
                packets.append(packet)
            }
            return packets
        }
        defer { server.cancel() }
        await service.connect(to: Station(callsign: "K1MOCK", ipAddress: "198.51.100.10"))
        XCTAssertEqual(service.session?.state, .connected)
        XCTAssertEqual(service.transmitCodec, speexPeer ? .speex : .gsm)
        service.sendPTT(active: true)
        XCTAssertEqual(engine.transmitCodec, speexPeer ? .speex : .gsm)
        let speech = (0..<1_341).map { Int16(10_000 * sin(Double($0) * 0.1728)) }
        engine.encodeTransmitPCM(speech)
        service.sendPTT(active: false)
        let packets = try await withThrowingTaskGroup(of: [Data].self) { group in
            group.addTask { try await server.value }
            group.addTask { try await Task.sleep(for: .seconds(5)); throw Timeout.expired }
            defer { group.cancelAll(); server.cancel() }
            return try await group.next()!
        }
        let decoder = SpeexCodec()
        let diagnostics = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(diagnostics.txCodec, speexPeer ? "Speex" : "GSM")
        XCTAssertEqual(diagnostics.txPackets, packets.count)
        XCTAssertEqual(diagnostics.txPayloadBytes, packets.reduce(0) { $0 + $1.count - 12 })
        var previous: EchoLinkVoicePacketMetadata?
        for packet in packets {
            XCTAssertEqual(packet[1], speexPeer ? 0x96 : 3)
            XCTAssertEqual(packet.count, speexPeer ? 162 : 144)
            let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet))
            let metadata = try XCTUnwrap(parsed.metadata)
            if let previous {
                XCTAssertEqual(metadata.sequenceNumber, previous.sequenceNumber &+ 1)
                XCTAssertEqual(metadata.timestamp, previous.timestamp &+ 640)
            }
            previous = metadata
            if speexPeer {
                guard case .speex(let payload) = parsed.packet else { return XCTFail("Expected Speex") }
                XCTAssertEqual(try XCTUnwrap(decoder.decodePacket(payload)).count, 640)
            } else {
                guard case .gsm(let payload) = parsed.packet else { return XCTFail("Expected GSM fallback") }
                XCTAssertEqual(GSMCodec().decodePacket(payload).count, 640)
            }
        }
        await service.disconnect()
        XCTAssertEqual(service.transmitCodec, .gsm)
    }
}

@MainActor
private final class SendCompletionPause {
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
