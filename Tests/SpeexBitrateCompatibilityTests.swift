// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

private struct SpeexRateFixture {
    let quality: Int
    let bitrate: Int
    let byteCount: Int
    let hex: String

    func payload() throws -> Data {
        var bytes = Data()
        var position = hex.startIndex
        while position < hex.endIndex {
            let end = hex.index(position, offsetBy: 2)
            bytes.append(try XCTUnwrap(UInt8(hex[position..<end], radix: 16)))
            position = end
        }
        return bytes
    }

    // Three independent, four-frame packets generated with vendored Speex 1.2.1
    // (portable floating point): fresh speex_nb_mode encoder per packet; set
    // BITRATE=25000, then QUALITY=8/9/10, COMPLEXITY=4; default VBR/VAD/DTX off.
    // Original mono 8 kHz PCM: Int16(10000 * sin(n * 0.1728)), n=0..<640.
    // Call speex_encode_int four times on 160 samples, insert one terminator,
    // then speex_bits_write. Effective modes 5/6/7 yield 150/182/246 bytes.
    // Decoder acceptance and nonzero PCM are not measures of perceived fidelity.
    static let all: [Self] = [
        .init(quality: 8, bitrate: 15_000, byteCount: 150,
              hex: "29ca6d3bf500007fffffffffff83a1dce8b2cb9a490a2bb138186b7eb7c4ebb4035bfc2dd6329ca6d3bf4275cd1557d8e5b9993ae1c40bdef66e71c3803096dfbd0e4972b8150837a0519c29ca6d3bf4b95c497ee5dc364e387020bf77dce5c39c3817ee5d6e5521772b8dcb664726fb729ca6d3bf4b95c3e5c8e556f5bdcae2fdb273fbf7eae570864e7386e58f72b891c920a0bea4"),
        .init(quality: 9, bitrate: 18_200, byteCount: 182,
              hex: "31ca6d3bf5000068e8e8e8e8e8e8e880a1e048a6b7e6a458704a4ea73c29934a322c37a4eba64656c71d16b698d31ca6d3bf426dc808de8f848a91294b870005042b7cb8f1f501c381bd2c215bae7a03d2e188303d9a5e6142ec3d31ca6d3bf470e0764862e2d96f60ef3870177777e6985037bc2e571bbbb35238382a2bb72b8bd3d32dec1615ac531ca6d3bf4b95c7ea485608f68ee9edcae0f5870707c37f777ee57123838306bbbbbf6572b8dec16190ddbd6b0a"),
        .init(quality: 10, bitrate: 24_600, byteCount: 246,
              hex: "39ca6d3bf500007fffffffffffffffffffffff83a1dce8b2cb9a491cde2c742eba8a4ea78d78692dff82e2977310b225189dfc9e7aa7c1ddc650a4ca26139ca6d3bf4275c1f157617d339661149fcc659dcae56466b70eb1e5ef26ecd60c4ae571239fdfbd153882330eed5166e1c07031f71ee91c7c68109f8f2639ca6d3bf4b95c737d99df539236778871f335dcae2f2f782491cfdb7eac27d8bb5c3805ef7a52396df888469b0ed3172b8def1e472b81f49faf91ca58139ca6d3bf4b95c6f048e49f97bb3dce3cf6bf55cae2f49c902bf72dbe7aa81c2aeee571348e577ef627f883950554b372b8ca41b52f71e442bb8c7ea9c1")
    ]
}

final class SpeexBitrateCompatibilityTests: XCTestCase {
    private func metadata(_ sequence: UInt16, ssrc: UInt32 = 0) -> EchoLinkVoicePacketMetadata {
        .init(payloadType: 0x96, sequenceNumber: sequence, timestamp: 0, ssrc: ssrc)
    }

    func testGoldenProfilesParseLegacyHeaderAndDecodeFourNarrowbandFrames() throws {
        XCTAssertEqual(SpeexRateFixture.all.count, 3)
        for fixture in SpeexRateFixture.all {
            let payload = try fixture.payload()
            XCTAssertEqual(payload.count, fixture.byteCount, "q\(fixture.quality)")
            XCTAssertEqual(payload.count * 100, fixture.bitrate) // 80 ms packets.
            // Literal peer header, independent of the production packet builder.
            let wire = Data([0xc0, 0x96, 0x12, 0x34, 0, 0, 0, 0, 0, 0, 0, 0]) + payload
            let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(wire))
            XCTAssertEqual(wire.count, fixture.byteCount + 12)
            XCTAssertEqual(parsed.packet, .speex(payload))
            XCTAssertEqual(parsed.metadata, metadata(0x1234))
            XCTAssertEqual(EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                gsmPayload: payload, sequence: 0x1234, codec: .speex), wire)
            let samples = try XCTUnwrap(SpeexCodec().decodePacket(payload))
            XCTAssertEqual(samples.count, 4 * 160)
            XCTAssertTrue(samples.contains { abs(Int($0)) > 10 })
        }
    }

    func testConsecutivePacketsPreserveDecoderHistoryAtEveryRate() throws {
        for fixture in SpeexRateFixture.all {
            let payload = try fixture.payload()
            let stream = SpeexReceiveStreamDecoder()
            let reference = SpeexCodec()
            for sequence: UInt16 in 1...4 {
                let audio = try XCTUnwrap(stream.decode(payload, metadata: metadata(sequence),
                    now: Double(sequence) * 0.08))
                XCTAssertEqual(audio.received.count, 640)
                XCTAssertEqual(audio.received, reference.decodePacket(payload))
                XCTAssertTrue(audio.concealed.isEmpty)
            }
        }
    }

    func testOneAndTwoPacketLossesUseNativeConcealmentAtEveryRate() throws {
        for fixture in SpeexRateFixture.all {
            let payload = try fixture.payload()
            for missing in 1...2 {
                let stream = SpeexReceiveStreamDecoder()
                let reference = SpeexCodec()
                _ = try XCTUnwrap(stream.decode(payload, metadata: metadata(10), now: 0))
                _ = try XCTUnwrap(reference.decodePacket(payload))
                let audio = try XCTUnwrap(stream.decode(payload,
                    metadata: metadata(UInt16(11 + missing)), now: Double(missing + 1) * 0.08))
                XCTAssertEqual(audio.concealed.count, missing * 640)
                XCTAssertEqual(audio.concealed, reference.concealMissingSamples(missing * 640))
                XCTAssertEqual(audio.received, reference.decodePacket(payload))
                XCTAssertEqual(audio.received.count, 640)
            }
        }
    }

    func testCodecResetRestoresFreshDecodeAfterLossAtEveryRate() throws {
        for fixture in SpeexRateFixture.all {
            let payload = try fixture.payload()
            let codec = SpeexCodec()
            let initial = try XCTUnwrap(codec.decodePacket(payload))
            XCTAssertEqual(try XCTUnwrap(codec.concealMissingSamples(640)).count, 640)
            _ = try XCTUnwrap(codec.decodePacket(payload))
            codec.reset()
            XCTAssertEqual(codec.decodePacket(payload), initial)
        }
    }

    func testEveryTruncatedPrefixAndMalformedPacketIsRejectedAtEveryRate() throws {
        for fixture in SpeexRateFixture.all {
            let payload = try fixture.payload()
            let codec = SpeexCodec()
            let initial = try XCTUnwrap(SpeexCodec().decodePacket(payload))
            // 149 + 181 + 245 = 575 nonempty truncated prefixes across profiles.
            var invalid: [Data] = (1..<payload.count).map { Data(payload.prefix($0)) }
            invalid += [
                Data(repeating: 0xff, count: payload.count), payload + payload,
                payload + Data([0xff])
            ]
            for packet in invalid {
                _ = try XCTUnwrap(codec.decodePacket(payload))
                XCTAssertNil(codec.decodePacket(packet), "q\(fixture.quality), \(packet.count) bytes")
                XCTAssertEqual(codec.decodePacket(payload), initial, "Failure must discard partial decoder state")
            }
            XCTAssertNil(codec.decodePacket(Data()))
            XCTAssertNil(codec.decodePacket(Data(repeating: 0, count: 513)))
        }
        XCTAssertNil(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(Data(
            [0xc0, 0x96, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])))
    }

    func testMalformedStreamPacketsDoNotConsumeSequenceOrPlaybackStateAtEveryRate() throws {
        for fixture in SpeexRateFixture.all {
            let payload = try fixture.payload()
            let stream = SpeexReceiveStreamDecoder()
            let reference = SpeexCodec()
            _ = try XCTUnwrap(stream.decode(payload, metadata: metadata(20), now: 0))
            _ = try XCTUnwrap(reference.decodePacket(payload))
            for invalid in [Data(payload.dropLast()), Data(payload.prefix(payload.count / 2)),
                            Data(repeating: 0xff, count: payload.count)] {
                let wire = Data([0xc0, 0x96, 0, 21, 0, 0, 0, 0, 0, 0, 0, 0]) + invalid
                // Header parsing classifies the payload; codec validation rejects corruption.
                let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(wire))
                XCTAssertEqual(parsed.packet, .speex(invalid))
                XCTAssertNil(stream.decode(invalid, metadata: parsed.metadata, now: 0.01))
            }
            let recovered = try XCTUnwrap(stream.decode(payload, metadata: metadata(21), now: 0.08))
            XCTAssertTrue(recovered.concealed.isEmpty)
            XCTAssertEqual(recovered.received, reference.decodePacket(payload))
            XCTAssertNil(stream.decode(payload, metadata: metadata(21), now: 0.09))
            XCTAssertNil(stream.decode(payload, metadata: metadata(20), now: 0.10))
            XCTAssertEqual(try XCTUnwrap(stream.decode(payload, metadata: metadata(22), now: 0.16)).received,
                           reference.decodePacket(payload))
        }
    }

    func testLongGapIdleNewTalkerAndExplicitResetStartFreshAtEveryRate() throws {
        for fixture in SpeexRateFixture.all {
            let payload = try fixture.payload()
            let stream = SpeexReceiveStreamDecoder()
            let fresh = try XCTUnwrap(SpeexCodec().decodePacket(payload))
            _ = try XCTUnwrap(stream.decode(payload, metadata: metadata(1), now: 0))
            for (sequence, ssrc, now): (UInt16, UInt32, Double) in [
                (5, 0, 0.32), (6, 0, 1.0), (7, 2, 1.08)
            ] {
                let audio = try XCTUnwrap(stream.decode(payload, metadata: metadata(sequence, ssrc: ssrc), now: now))
                XCTAssertEqual(audio.received, fresh)
                XCTAssertTrue(audio.concealed.isEmpty)
            }
            stream.reset()
            let reset = try XCTUnwrap(stream.decode(payload, metadata: metadata(1, ssrc: 2), now: 1.09))
            XCTAssertEqual(reset.received, fresh)
            XCTAssertTrue(reset.concealed.isEmpty)
        }
    }

    func testRateChangesAndSequenceWrapDoNotRequireDecoderReconfiguration() throws {
        let stream = SpeexReceiveStreamDecoder()
        let reference = SpeexCodec()
        let profiles = SpeexRateFixture.all + SpeexRateFixture.all.reversed()
        var sequence = UInt16.max - 1
        for (index, fixture) in profiles.enumerated() {
            let payload = try fixture.payload()
            let audio = try XCTUnwrap(stream.decode(payload, metadata: metadata(sequence), now: Double(index) * 0.08))
            XCTAssertEqual(audio.received, reference.decodePacket(payload))
            XCTAssertTrue(audio.concealed.isEmpty)
            sequence &+= 1
        }
    }
}

@MainActor
final class SpeexBitrateLocalPeerTests: XCTestCase {
    func testMutedLocalPeerReceives15kbpsAndRemoteBye() async throws {
        try await receive(SpeexRateFixture.all[0])
    }

    func testMutedLocalPeerReceives18Point2kbpsAndRemoteBye() async throws {
        try await receive(SpeexRateFixture.all[1])
    }

    func testMutedLocalPeerReceives24Point6kbpsAndRemoteBye() async throws {
        try await receive(SpeexRateFixture.all[2])
    }

    private func receive(_ fixture: SpeexRateFixture) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SpeexBitrateCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey())
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let relay = try BoundUDPSocket(localPort: 0)
        let audio = AudioEngine()
        let service = EchoLinkConnectionService(
            relayClientFactory: {
                EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort,
                                   resolvedIPv4Candidates: ["127.0.0.1"])
            },
            networkConfigurationProvider: {
                .init(mode: .relay, host: "", port: 8100, password: "")
            },
            audioEngine: audio, recordingDefaults: defaults, recordingFolder: folder,
            handshakeRetryIntervals: [.milliseconds(100), .milliseconds(200), .milliseconds(300)]
        )
        service.authenticatedCallsign = "N0TST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        service.setBackgroundMuted(true)

        let connected = expectation(description: "Local relay handshake")
        let accepted = expectation(description: "Four unique q\(fixture.quality) packets")
        var acceptedMetadata: [EchoLinkVoicePacketMetadata?] = []
        service.onAuditAcceptedPacket = { metadata in
            acceptedMetadata.append(metadata)
            if acceptedMetadata.count == 4 { accepted.fulfill() }
        }
        let server = Task {
            let registration = try await Self.receiveDatagram(from: relay)
            XCTAssertEqual(registration.sourceHost, "127.0.0.1")
            XCTAssertEqual(registration.data, try EchoLinkRelayProtocol.register(callsign: "N0TST"))
            try await relay.send(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]),
                to: "127.0.0.1", port: registration.sourcePort)
            let request = try await Self.receiveDatagram(from: relay)
            XCTAssertEqual(request.sourceHost, "127.0.0.1")
            XCTAssertEqual(Data(request.data.prefix(7)), try EchoLinkRelayProtocol.encodeRequest(
                type: .data, destinationHost: "127.0.0.1", destinationPort: 5199))
            XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: Data(request.data.dropFirst(7)))
                .contains { if case .sdes = $0 { return true }; return false })
            let sdes = EchoLinkControlPacketCodec.buildSDESPacket(
                callsign: "K1MOCK-R", tool: "SvxLink", advertiseSpeex: true)
            try await relay.send(Self.response(sdes, port: 5199),
                to: "127.0.0.1", port: registration.sourcePort)
            return registration.sourcePort
        }
        let connection = Task {
            await service.connect(to: Station(callsign: "K1MOCK-R", ipAddress: "127.0.0.1", type: .repeater))
            connected.fulfill()
        }
        defer {
            relay.close()
            server.cancel()
            connection.cancel()
            service.onAuditAcceptedPacket = nil
        }
        do {
            let endpointPort = try await server.value
            await fulfillment(of: [connected], timeout: 3)
            guard service.session?.state == .connected else { throw FixtureError.handshakeFailed }
            XCTAssertNil(service.error)
            XCTAssertTrue(service.isAutomaticallyRecording)
            XCTAssertFalse(audio.isRunning)
            XCTAssertEqual(service.session?.isPTTActive, false)

            let payload = try fixture.payload()
            let reference = SpeexCodec()
            var expectedPCM: [Int16] = []
            // Four accepted packets and one deliberate duplicate per profile.
            for sequence: UInt16 in [100, 100, 101, 102, 103] {
                let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                    gsmPayload: payload, sequence: sequence, timestamp: 0, codec: .speex)
                try await relay.send(Self.response(packet, port: 5198), to: "127.0.0.1", port: endpointPort)
                if sequence != 100 || expectedPCM.isEmpty {
                    expectedPCM += try XCTUnwrap(reference.decodePacket(payload))
                }
            }
            await fulfillment(of: [accepted], timeout: 3)
            XCTAssertEqual(acceptedMetadata.compactMap { $0?.sequenceNumber }, [100, 101, 102, 103])
            XCTAssertTrue(acceptedMetadata.allSatisfy {
                $0?.payloadType == 0x96 && $0?.timestamp == 0 && $0?.ssrc == 0
            })
            let diagnostics = await service.audioDiagnosticsSnapshot()
            XCTAssertEqual(service.auditTransportSnapshot["rxAccepted"], 4)
            XCTAssertEqual(service.auditTransportSnapshot["sent"], 0)
            XCTAssertEqual(diagnostics.rxCodec, "Speex")
            XCTAssertEqual(diagnostics.rxPackets, 4)
            XCTAssertEqual(diagnostics.rxPayloadBytes, fixture.byteCount * 4)
            XCTAssertEqual(diagnostics.sequencedRXPackets, 4)
            XCTAssertEqual(diagnostics.duplicateOrLateRXPackets, 1)
            XCTAssertEqual(diagnostics.missingRXPackets, 0)
            XCTAssertEqual(diagnostics.invalidRXPackets, 0)
            XCTAssertEqual(diagnostics.rxQueuedPackets, 0)
            XCTAssertEqual(diagnostics.transportRXDrops, 0)
            XCTAssertEqual(diagnostics.playbackRXDrops, 0)
            XCTAssertFalse(audio.isRunning)

            try await relay.send(Self.response(EchoLinkControlPacketCodec.buildBYEPacket(), port: 5199),
                to: "127.0.0.1", port: endpointPort)
            for _ in 0..<300 where service.session != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(service.session, "Remote BYE must tear down the receive session")
            XCTAssertFalse(service.isAutomaticallyRecording)
            XCTAssertFalse(audio.isRunning)

            let recordings = QSORecordingService(folder: folder).recordings
            XCTAssertEqual(recordings.count, 1)
            let recording = try XCTUnwrap(recordings.first)
            XCTAssertEqual(recording.duration, 2_560.0 / 8_000)
            let wav = try Data(contentsOf: recording.url)
            XCTAssertEqual(wav.count, 44 + 2_560 * 2)
            guard wav.count >= 44, wav.count.isMultiple(of: 2) else { throw FixtureError.invalidRecording }
            XCTAssertEqual(Array(wav[22..<28]), [1, 0, 0x40, 0x1f, 0, 0]) // Mono, 8 kHz.
            XCTAssertEqual(Array(wav[34..<36]), [16, 0])
            let pcm = stride(from: 44, to: wav.count, by: 2).map {
                Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)
            }
            XCTAssertEqual(pcm.count, 2_560)
            XCTAssertEqual(pcm, expectedPCM, "Muted service must record decoded samples once per unique packet")
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
        case invalidRecording
    }

    private nonisolated static func receiveDatagram(from socket: BoundUDPSocket) async throws -> BoundUDPSocket.Datagram {
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
        Data([1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 0xff),
              UInt8(port >> 8), UInt8(port & 0xff)]) + payload
    }
}
