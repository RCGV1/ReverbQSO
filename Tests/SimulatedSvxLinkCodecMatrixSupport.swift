// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

enum SimulatedSvxLinkMatrixProfile: String, CaseIterable {
    case gsm, speex15, speex18Point2, speex24Point6, pcmuExtension, pcmaExtension

    var payloadType: UInt8 {
        switch self {
        case .gsm: return 3
        case .speex15, .speex18Point2, .speex24Point6: return 0x96
        case .pcmuExtension: return 0
        case .pcmaExtension: return 8
        }
    }

    var payloadBytes: Int {
        switch self {
        case .gsm: return 132
        case .speex15: return 150
        case .speex18Point2: return 182
        case .speex24Point6: return 246
        case .pcmuExtension, .pcmaExtension: return 640
        }
    }

    var diagnosticName: String {
        switch self {
        case .gsm: return "GSM"
        case .speex15, .speex18Point2, .speex24Point6: return "Speex"
        case .pcmuExtension: return "G.711 \u{00b5}-law"
        case .pcmaExtension: return "G.711 A-law"
        }
    }

    func payloads(count: Int) throws -> [Data] {
        switch self {
        case .gsm:
            let bytes = try XCTUnwrap(GSMCodec.stripHeader(
                GSMCodec().encode(SimulatedSvxLinkMatrixPCM.voiced(count: count * 640))))
            return stride(from: 0, to: bytes.count, by: 132).map { Data(bytes[$0..<($0 + 132)]) }
        case .speex15, .speex18Point2, .speex24Point6:
            let hex: String
            switch self {
            case .speex15:
                hex = "29ca6d3bf500007fffffffffff83a1dce8b2cb9a490a2bb138186b7eb7c4ebb4035bfc2dd6329ca6d3bf4275cd1557d8e5b9993ae1c40bdef66e71c3803096dfbd0e4972b8150837a0519c29ca6d3bf4b95c497ee5dc364e387020bf77dce5c39c3817ee5d6e5521772b8dcb664726fb729ca6d3bf4b95c3e5c8e556f5bdcae2fdb273fbf7eae570864e7386e58f72b891c920a0bea4"
            case .speex18Point2:
                hex = "31ca6d3bf5000068e8e8e8e8e8e8e880a1e048a6b7e6a458704a4ea73c29934a322c37a4eba64656c71d16b698d31ca6d3bf426dc808de8f848a91294b870005042b7cb8f1f501c381bd2c215bae7a03d2e188303d9a5e6142ec3d31ca6d3bf470e0764862e2d96f60ef3870177777e6985037bc2e571bbbb35238382a2bb72b8bd3d32dec1615ac531ca6d3bf4b95c7ea485608f68ee9edcae0f5870707c37f777ee57123838306bbbbbf6572b8dec16190ddbd6b0a"
            default:
                hex = "39ca6d3bf500007fffffffffffffffffffffff83a1dce8b2cb9a491cde2c742eba8a4ea78d78692dff82e2977310b225189dfc9e7aa7c1ddc650a4ca26139ca6d3bf4275c1f157617d339661149fcc659dcae56466b70eb1e5ef26ecd60c4ae571239fdfbd153882330eed5166e1c07031f71ee91c7c68109f8f2639ca6d3bf4b95c737d99df539236778871f335dcae2f2f782491cfdb7eac27d8bb5c3805ef7a52396df888469b0ed3172b8def1e472b81f49faf91ca58139ca6d3bf4b95c6f048e49f97bb3dce3cf6bf55cae2f49c902bf72dbe7aa81c2aeee571348e577ef627f883950554b372b8ca41b52f71e442bb8c7ea9c1"
            }
            // Independent golden fixtures copied from SpeexBitrateCompatibilityTests:
            // Speex 1.2.1 floating point, BITRATE=25000 then QUALITY=8/9/10,
            // COMPLEXITY=4, VBR/VAD/DTX off; four 160-sample frames + terminator.
            // Source: Int16(10000 * sin(n * 0.1728)), n=0..<640, fresh encoder.
            let pairs = stride(from: 0, to: hex.count, by: 2)
            let payload = try Data(pairs.map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return try XCTUnwrap(UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16))
            })
            XCTAssertEqual(payload.count, payloadBytes, rawValue)
            return Array(repeating: payload, count: count)
        case .pcmuExtension, .pcmaExtension:
            // G.711 is an RX extension, never a negotiated native SvxLink TX codec.
            let codebook = (0...255).map { UInt8($0) }
            let levels = codebook.map { Int(Self.referenceG711($0, aLaw: self == .pcmaExtension)) }
            let bytes = SimulatedSvxLinkMatrixPCM.voiced(count: count * 640).map { sample in
                let index = levels.indices.min { abs(levels[$0] - Int(sample)) < abs(levels[$1] - Int(sample)) }!
                return codebook[index]
            }
            return stride(from: 0, to: bytes.count, by: 640).map { Data(bytes[$0..<($0 + 640)]) }
        }
    }

    // Scalar G.711 oracle, independent of the production packet parser/decoders.
    static func referenceG711(_ byte: UInt8, aLaw: Bool) -> Int16 {
        let value = Int(byte) ^ (aLaw ? 0x55 : 0xff)
        let segment = (value / 16) % 8
        let step = value % 16
        let magnitude: Int
        if aLaw {
            magnitude = segment == 0 ? step * 16 + 8 : (step * 16 + 264) * (1 << (segment - 1))
        } else {
            magnitude = (step * 8 + 132) * (1 << segment) - 132
        }
        let positive = aLaw ? value >= 128 : value < 128
        return Int16(positive ? magnitude : -magnitude)
    }

    // Literal peer RTP header avoids using the outgoing packet builder as its own oracle.
    func packet(_ payload: Data, sequence: UInt16, timestamp: UInt32) -> Data {
        Data([0xc0, payloadType, UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence),
              UInt8(timestamp >> 24), UInt8(truncatingIfNeeded: timestamp >> 16),
              UInt8(truncatingIfNeeded: timestamp >> 8), UInt8(truncatingIfNeeded: timestamp),
              0, 0, 0, 0]) + payload
    }
}

enum SimulatedSvxLinkMatrixPCM {
    static func voiced(count: Int, offset: Int = 0) -> [Int16] {
        (offset..<(offset + count)).map { index in
            let time = Double(index) / 8_000
            let envelope = 0.4 + 0.6 * pow(sin(.pi * time / 0.32), 2)
            let fundamental = 7_000 * sin(2 * .pi * 125 * time)
            let harmonics = 2_600 * sin(2 * .pi * 375 * time) + 1_100 * sin(2 * .pi * 725 * time)
            return Int16((envelope * (fundamental + harmonics)).rounded())
        }
    }

    static func transmitPayloads(_ pcm: [Int16], codec: EchoLinkVoiceCodec) throws -> [Data] {
        let padding = (640 - pcm.count % 640) % 640
        let padded = pcm + Array(repeating: Int16(0), count: padding)
        switch codec {
        case .gsm:
            let bytes = try XCTUnwrap(GSMCodec.stripHeader(GSMCodec().encode(padded)))
            return stride(from: 0, to: bytes.count, by: 132).map { Data(bytes[$0..<($0 + 132)]) }
        case .speex:
            return try XCTUnwrap(SpeexCodec().encode(padded))
        }
    }
}

final class SimulatedSvxLinkMatrixDecodeOracle {
    private let gsm = GSMCodec()
    private let speex = SpeexCodec()
    private var previousSpeexSequence: UInt16?
    private(set) var concealedSamples = 0

    func decode(_ packet: Data) throws -> [Int16] {
        let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet))
        let metadata = try XCTUnwrap(parsed.metadata)
        let payload = Data(packet.dropFirst(12))
        switch metadata.payloadType {
        case 3:
            let pcm = gsm.decodePacket(payload)
            XCTAssertEqual(pcm.count, 640)
            return pcm
        case 0x96:
            if let previous = previousSpeexSequence {
                let distance = Int(metadata.sequenceNumber &- previous)
                if (2...3).contains(distance) {
                    let concealed = try XCTUnwrap(speex.concealMissingSamples((distance - 1) * 640))
                    concealedSamples += concealed.count
                } else if distance != 1 {
                    speex.reset()
                }
            }
            previousSpeexSequence = metadata.sequenceNumber
            return try XCTUnwrap(speex.decodePacket(payload))
        case 0, 8:
            return payload.map { SimulatedSvxLinkMatrixProfile.referenceG711($0, aLaw: metadata.payloadType == 8) }
        default:
            throw SimulatedSvxLinkMatrixPeer.Failure.unexpectedPacket
        }
    }
}

@MainActor
final class SimulatedSvxLinkMatrixPeer {
    enum Failure: Error { case timedOut(String), unexpectedPacket, invalidRecording }

    let relay: BoundUDPSocket
    let audio: AudioEngine
    let service: EchoLinkConnectionService
    private let suite: String
    private let defaults: UserDefaults
    private let folder: URL
    private var connection: Task<Void, Never>?
    private var endpointPort: UInt16?
    private var knownRecordingIDs: Set<UUID> = []
    private(set) var accepted: [EchoLinkVoicePacketMetadata] = []
    private(set) var incoming: [Data] = []
    private(set) var acceptedBaseline = 0

    init() throws {
        let socket = try BoundUDPSocket(localPort: 0)
        relay = socket
        audio = AudioEngine(hardwareEnabled: false)
        suite = "SimulatedSvxLinkCodecMatrix.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey())
        service = EchoLinkConnectionService(
            relayClientFactory: {
                EchoLinkRelayClient(host: "127.0.0.1", port: socket.actualLocalPort,
                                   resolvedIPv4Candidates: ["127.0.0.1"])
            },
            networkConfigurationProvider: {
                .init(mode: .relay, host: "127.0.0.1", port: socket.actualLocalPort, password: "")
            },
            audioEngine: audio, recordingDefaults: defaults, recordingFolder: folder,
            handshakeRetryIntervals: [.milliseconds(100), .milliseconds(200), .milliseconds(300)]
        )
        service.authenticatedCallsign = "N0TST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        service.onAuditAcceptedPacket = { [weak self] metadata in
            if let metadata { self?.accepted.append(metadata) }
        }
        service.onAuditIncomingDatagram = { [weak self] packet in self?.incoming.append(packet) }
    }

    func connect(advertiseSpeex: Bool) async throws {
        XCTAssertNil(service.session)
        accepted.removeAll()
        incoming.removeAll()
        acceptedBaseline = service.auditTransportSnapshot["rxAccepted"] ?? 0
        var finished = false
        connection = Task {
            await service.connect(to: Station(callsign: "K1MOCK-R", ipAddress: "127.0.0.1", type: .repeater))
            finished = true
        }
        let registration = try await receive()
        XCTAssertEqual(registration.data, try EchoLinkRelayProtocol.register(callsign: "N0TST"))
        endpointPort = registration.sourcePort
        try await relay.send(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]), to: "127.0.0.1", port: registration.sourcePort)
        let request = try await outbound(port: 5199) { packet in
            EchoLinkControlPacketCodec.parseEvents(from: packet).contains {
                if case .sdes = $0 { return true }; return false
            }
        }
        let advertised = EchoLinkControlPacketCodec.parseEvents(from: request).compactMap { event -> [String]? in
            if case .sdes(let info) = event { return info.privateItems }; return nil
        }.flatMap { $0 }
        XCTAssertTrue(advertised.contains("SPEEX"))
        let response = EchoLinkControlPacketCodec.buildSDESPacket(
            callsign: "K1MOCK-R", tool: "SvxLink", advertiseSpeex: advertiseSpeex)
        try await send(response, port: 5199)
        try await eventually("handshake") { finished && self.service.session?.state == .connected }
        XCTAssertNil(service.error)
        XCTAssertTrue(service.isAutomaticallyRecording)
        XCTAssertFalse(audio.isRunning)
        XCTAssertFalse(audio.isCapturing)
        XCTAssertEqual(service.transmitCodec, advertiseSpeex ? .speex : .gsm)
        let diagnostics = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(diagnostics.txPackets, 0)
        XCTAssertEqual(diagnostics.rxPackets, 0)
        XCTAssertEqual(diagnostics.sequencedRXPackets, 0)
        XCTAssertEqual(diagnostics.duplicateOrLateRXPackets, 0)
        XCTAssertEqual(diagnostics.missingRXPackets, 0)
        connection = nil
    }

    func send(_ payload: Data, port: UInt16 = 5198) async throws {
        let endpoint = try XCTUnwrap(endpointPort)
        let high = UInt8(port >> 8), low = UInt8(truncatingIfNeeded: port)
        let response = Data([1, 127, 0, 0, 1, high, low, high, low]) + payload
        try await relay.send(response, to: "127.0.0.1", port: endpoint)
    }

    func outbound(port: UInt16, matching: (Data) -> Bool) async throws -> Data {
        let deadline = ContinuousClock.now + .seconds(3)
        let header = try EchoLinkRelayProtocol.encodeRequest(
            type: .data, destinationHost: "127.0.0.1", destinationPort: port)
        while ContinuousClock.now < deadline {
            let datagram = try await receive(until: deadline)
            guard datagram.data.count >= 7 else { continue }
            let packet = Data(datagram.data.dropFirst(7))
            if Data(datagram.data.prefix(7)) == header, matching(packet) { return packet }
        }
        relay.close()
        throw Failure.timedOut("outbound port \(port)")
    }

    func eventually(_ label: String, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            try Task.checkCancellation()
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        relay.close()
        connection?.cancel()
        throw Failure.timedOut(label)
    }

    func finish(remoteBye: Bool) async throws {
        if remoteBye {
            try await send(EchoLinkControlPacketCodec.buildBYEPacket(), port: 5199)
            try await eventually("remote BYE cleanup") { self.service.session == nil }
        } else {
            await service.disconnect()
            _ = try await outbound(port: 5199) { packet in
                EchoLinkControlPacketCodec.parseEvents(from: packet).contains {
                    if case .bye = $0 { return true }; return false
                }
            }
        }
        XCTAssertNil(service.session)
        XCTAssertFalse(service.isAutomaticallyRecording)
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.isRemoteTransmitting)
        XCTAssertFalse(audio.isRunning)
        XCTAssertFalse(audio.isCapturing)
        XCTAssertEqual(service.transmitCodec, .gsm)
        XCTAssertNil(service.auditAudioSendDrainTask)
        let diagnostics = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(diagnostics.txQueuedPackets, 0)
        XCTAssertEqual(diagnostics.rxQueuedPackets, 0)
        endpointPort = nil
    }

    func assertRecording(_ expected: [Int16], label: String) throws {
        let recordings = QSORecordingService(folder: folder).recordings
        let added = recordings.filter { !knownRecordingIDs.contains($0.id) }
        XCTAssertEqual(added.count, 1, label)
        let recording = try XCTUnwrap(added.first)
        knownRecordingIDs.insert(recording.id)
        XCTAssertEqual(recording.callsign, "K1MOCK-R")
        XCTAssertEqual(recording.kind, .qso)
        XCTAssertEqual(recording.duration, Double(expected.count) / 8_000, accuracy: 0.000_000_1, label)
        let wav = try Data(contentsOf: recording.url)
        XCTAssertEqual(wav.count, 44 + expected.count * 2, label)
        guard wav.count >= 44, wav.count.isMultiple(of: 2) else { throw Failure.invalidRecording }
        XCTAssertEqual(Data(wav[0..<4]), Data("RIFF".utf8))
        XCTAssertEqual(Data(wav[8..<16]), Data("WAVEfmt ".utf8))
        XCTAssertEqual(Array(wav[20..<36]), [1, 0, 1, 0, 0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0])
        XCTAssertEqual(Data(wav[36..<40]), Data("data".utf8))
        let pcm = stride(from: 44, to: wav.count, by: 2).map {
            Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)
        }
        XCTAssertEqual(pcm, expected, "\(label): record unique decoded network PCM, without synthetic PLC")
        XCTAssertTrue(pcm.contains { abs(Int($0)) > 100 }, label)
    }

    func shutdown() async {
        relay.close()
        connection?.cancel()
        connection = nil
        service.onAuditAcceptedPacket = nil
        service.onAuditIncomingDatagram = nil
        await service.disconnect()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func receive(until deadline: ContinuousClock.Instant = .now + .seconds(3)) async throws -> BoundUDPSocket.Datagram {
        let socket = relay
        // Closing the socket resumes a suspended receive; cancelling a sibling
        // task alone is not a timeout policy. No task-group scope waits on I/O.
        let watchdog = Task {
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            socket.close()
        }
        defer { watchdog.cancel() }
        let datagram = try await socket.receive()
        guard datagram.sourceHost == "127.0.0.1" else { throw Failure.unexpectedPacket }
        return datagram
    }
}
