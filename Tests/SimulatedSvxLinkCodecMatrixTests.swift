// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

@MainActor
final class SimulatedSvxLinkCodecMatrixTests: XCTestCase {
    func testNativeTransmitMatrixReconnectsAndRecordsLoopedBackAudio() async throws {
        let peer = try SimulatedSvxLinkMatrixPeer()
        do {
            // Reuse the actual service across four sessions, changing negotiation
            // each time. G.711 is deliberately absent from this native TX matrix.
            for (cycle, codec) in [EchoLinkVoiceCodec.gsm, .speex, .gsm, .speex].enumerated() {
                try await peer.connect(advertiseSpeex: codec == .speex)
                var previous: EchoLinkVoicePacketMetadata?
                var packets: [Data] = []
                for (turn, chunks) in [[1, 159, 17, 463, 701], [319, 1, 81, 376]].enumerated() {
                    let pcm = SimulatedSvxLinkMatrixPCM.voiced(count: chunks.reduce(0, +), offset: turn * 2_000)
                    let oracle = try SimulatedSvxLinkMatrixPCM.transmitPayloads(pcm, codec: codec)
                    XCTAssertEqual(oracle.count, turn == 0 ? 3 : 2)
                    // Keep synthetic submission and release synchronous: headless
                    // capture must never start or request microphone permission.
                    peer.service.sendPTT(active: true)
                    XCTAssertEqual(peer.service.session?.isPTTActive, true)
                    XCTAssertEqual(peer.audio.transmitCodec, codec)
                    XCTAssertFalse(peer.audio.isRunning)
                    XCTAssertFalse(peer.audio.isCapturing)
                    var cursor = 0
                    for count in chunks {
                        peer.audio.encodeTransmitPCM(Array(pcm[cursor..<(cursor + count)]))
                        cursor += count
                    }
                    peer.service.sendPTT(active: false)
                    for payload in oracle {
                        let packet = try await peer.outbound(port: 5198) {
                            EchoLinkAudioPacketCodec.parseIncomingAudioDatagram($0) != nil
                        }
                        let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet))
                        let metadata = try XCTUnwrap(parsed.metadata)
                        XCTAssertEqual(metadata.payloadType, codec == .speex ? 0x96 : 3)
                        XCTAssertEqual(packet.count, codec == .speex ? 162 : 144)
                        XCTAssertEqual(Data(packet.dropFirst(12)), payload,
                                       "cycle \(cycle), turn \(turn): sequential fresh encoder + zero-padded tail")
                        if let previous {
                            XCTAssertEqual(metadata.sequenceNumber, previous.sequenceNumber &+ 1)
                            XCTAssertEqual(metadata.timestamp, previous.timestamp &+ 640)
                        }
                        previous = metadata
                        packets.append(packet)
                    }
                    try await peer.eventually("PTT release and send drain") {
                        peer.service.session?.isPTTActive == false
                            && !peer.audio.isCapturing && peer.service.auditAudioSendDrainTask == nil
                    }
                    let diagnostics = await peer.service.audioDiagnosticsSnapshot()
                    XCTAssertEqual(diagnostics.txPackets, packets.count)
                    XCTAssertEqual(diagnostics.txPayloadBytes, packets.count * (codec == .speex ? 150 : 132))
                    XCTAssertEqual(diagnostics.txCodec, codec == .speex ? "Speex" : "GSM")
                    XCTAssertEqual(diagnostics.txQueueDrops, 0)
                    XCTAssertEqual(diagnostics.txQueuedPackets, 0)
                    let redundantFlush = await peer.audio.stopCaptureAndFlushPendingBuffers()
                    XCTAssertTrue(redundantFlush.isEmpty, "Stopping twice cannot emit another padded tail")
                }
                let decoder = SimulatedSvxLinkMatrixDecodeOracle()
                let expected = try packets.flatMap { try decoder.decode($0) }
                for packet in packets { try await peer.send(packet) }
                try await peer.eventually("looped-back native audio") { peer.accepted.count == packets.count }
                await assertCounters(peer, packets: packets, duplicates: 0, missing: 0)
                XCTAssertEqual(peer.accepted.map(\.sequenceNumber), try packets.map {
                    try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram($0)?.metadata).sequenceNumber
                })
                try await peer.finish(remoteBye: cycle >= 2)
                try peer.assertRecording(expected, label: "native-\(codec)-cycle-\(cycle)")
            }
            await peer.shutdown()
        } catch {
            await peer.shutdown()
            throw error
        }
    }

    func testReceiveProfileMatrixCountsDuplicatesExpiredReorderingAndLoss() async throws {
        for profile in SimulatedSvxLinkMatrixProfile.allCases {
            for timestamped in [false, true] {
                let peer = try SimulatedSvxLinkMatrixPeer()
                do {
                    // PCMU/PCMA receive support must not enable native Speex TX.
                    try await peer.connect(advertiseSpeex: profile.payloadType == 0x96)
                    let payloads = try profile.payloads(count: 10)
                    let packets = payloads.enumerated().map { index, payload in
                        profile.packet(payload, sequence: UInt16(100 + index),
                                       timestamp: timestamped ? UInt32(index * 640) : 0)
                    }
                    // Three genuinely missing packets force a bounded gap drain.
                    // Await admission before the late arrival: no race with the
                    // production 40 ms reorder deadline or Speex PLC timing.
                    for index in [0, 0, 1, 5] { try await peer.send(packets[index]) }
                    try await peer.eventually("expired receive gap") { peer.accepted.count == 3 }
                    try await peer.send(packets[2])
                    for index in 6...9 { try await peer.send(packets[index]) }
                    try await peer.eventually("receive clean tail") {
                        peer.accepted.count == 7 && peer.incoming.count == 9
                    }
                    let admittedIndices = [0, 1, 5, 6, 7, 8, 9]
                    let admitted = admittedIndices.map { packets[$0] }
                    XCTAssertEqual(peer.accepted.map(\.sequenceNumber), admittedIndices.map { UInt16(100 + $0) })
                    XCTAssertEqual(peer.accepted.map(\.timestamp), admittedIndices.map { timestamped ? UInt32($0 * 640) : 0 })
                    XCTAssertTrue(peer.accepted.allSatisfy { $0.payloadType == profile.payloadType && $0.ssrc == 0 })
                    await assertCounters(peer, packets: admitted, duplicates: 2, missing: 3)
                    let diagnostics = await peer.service.audioDiagnosticsSnapshot()
                    XCTAssertEqual(diagnostics.rxCodec, profile.diagnosticName)
                    XCTAssertEqual(diagnostics.rxPayloadBytes, 7 * profile.payloadBytes)
                    XCTAssertEqual(peer.service.transmitCodec, profile.payloadType == 0x96 ? .speex : .gsm)
                    let oracle = SimulatedSvxLinkMatrixDecodeOracle()
                    let expected = try admitted.flatMap { try oracle.decode($0) }
                    XCTAssertEqual(oracle.concealedSamples, 0, "A three-packet Speex gap resets the stream")
                    try await peer.finish(remoteBye: true)
                    try peer.assertRecording(expected, label: "\(profile.rawValue)-timestamped-\(timestamped)")
                    await peer.shutdown()
                } catch {
                    await peer.shutdown()
                    throw error
                }
            }
        }
    }

    func testReceiveRateAndCodecSwitchesKeepOneOrderedRecording() async throws {
        for timestamped in [false, true] {
            let peer = try SimulatedSvxLinkMatrixPeer()
            do {
                try await peer.connect(advertiseSpeex: true)
                let profiles: [SimulatedSvxLinkMatrixProfile] = [
                    .gsm, .speex15, .speex18Point2, .speex24Point6, .speex15,
                    .pcmuExtension, .pcmaExtension, .gsm, .speex24Point6, .speex18Point2, .speex15
                ]
                var packets: [Data] = []
                for (index, profile) in profiles.enumerated() {
                    let payload = try XCTUnwrap(profile.payloads(count: 1).first)
                    packets.append(profile.packet(payload, sequence: UInt16.max &- 3 &+ UInt16(index),
                                                  timestamp: timestamped ? UInt32(index * 640) : 0))
                }
                let oracle = SimulatedSvxLinkMatrixDecodeOracle()
                let expected = try packets.flatMap { try oracle.decode($0) }
                for packet in packets { try await peer.send(packet) }
                try await peer.eventually("mixed codec/rate recording") { peer.accepted.count == packets.count }
                XCTAssertEqual(peer.accepted.map(\.payloadType), profiles.map(\.payloadType))
                XCTAssertEqual(peer.accepted.map(\.sequenceNumber), profiles.indices.map { UInt16.max &- 3 &+ UInt16($0) })
                await assertCounters(peer, packets: packets, duplicates: 0, missing: 0)
                XCTAssertEqual(peer.service.transmitCodec, .speex, "Receive codec switches cannot replace negotiated TX")
                try await peer.finish(remoteBye: true)
                try peer.assertRecording(expected, label: "codec-rate-switches-timestamped-\(timestamped)")
                await peer.shutdown()
            } catch {
                await peer.shutdown()
                throw error
            }
        }
    }

    func testVirtualTimeReceiveMatrixRecoversReorderingLossAndCleanTail() throws {
        for profile in SimulatedSvxLinkMatrixProfile.allCases {
            for timestamped in [false, true] {
                let label = "\(profile.rawValue)-timestamped-\(timestamped)"
                let payloads = try profile.payloads(count: 12)
                let packets = payloads.enumerated().map { index, payload in
                    profile.packet(payload, sequence: UInt16.max &- 3 &+ UInt16(index),
                                   timestamp: timestamped ? UInt32(index * 640) : 0)
                }
                var reorder = EchoLinkAudioReorderBuffer()
                var admitted: [Data] = []
                func insert(_ index: Int, at now: Double) throws {
                    let metadata = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packets[index])?.metadata)
                    admitted += reorder.insert(packets[index], metadata: metadata, now: now)
                }
                try insert(0, at: 0)
                try insert(0, at: 0.001)
                try insert(2, at: 0.010)
                try insert(2, at: 0.011) // Duplicate while pending, not just after delivery.
                XCTAssertEqual(reorder.pendingPacketCount, 1, label)
                try insert(1, at: 0.020) // Recover before the virtual 40 ms deadline.
                XCTAssertEqual(admitted, Array(packets.prefix(3)), label)
                XCTAssertNil(reorder.nextDeadline, label)
                // Omit packet 3, release packet 4 after the exact virtual deadline.
                try insert(4, at: 0.030)
                XCTAssertTrue(reorder.drain(now: 0.069).isEmpty, label)
                admitted += reorder.drain(now: 0.071)
                try insert(3, at: 0.072) // Expired reordered packet is late, never decoded.
                for index in 5..<12 { try insert(index, at: 0.080 + Double(index - 5) * 0.080) }
                let indices = [0, 1, 2] + Array(4..<12)
                XCTAssertEqual(admitted, indices.map { packets[$0] }, label)
                XCTAssertEqual(reorder.deliveredSequencedPacketCount, 11, label)
                XCTAssertEqual(reorder.duplicateOrLatePacketCount, 3, label)
                XCTAssertEqual(reorder.missingPacketCount, 1, label)
                XCTAssertEqual(reorder.pendingPacketCount, 0, label)
                XCTAssertNil(reorder.nextDeadline, label)

                let gsm = GSMCodec()
                let speex = SpeexReceiveStreamDecoder()
                let oracle = SimulatedSvxLinkMatrixDecodeOracle()
                var actual: [Int16] = []
                var expected: [Int16] = []
                var concealed = 0
                for (ordinal, packet) in admitted.enumerated() {
                    let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet))
                    let decoded: [Int16]
                    switch parsed.packet {
                    case .gsm(let payload): decoded = gsm.decodePacket(payload)
                    case .speex(let payload):
                        let audio = try XCTUnwrap(speex.decode(payload, metadata: parsed.metadata, now: Double(ordinal) * 0.080))
                        decoded = audio.received
                        concealed += audio.concealed.count
                    case .pcm(let pcm): decoded = pcm
                    case .unsupportedPayloadType: throw SimulatedSvxLinkMatrixPeer.Failure.unexpectedPacket
                    }
                    XCTAssertEqual(decoded.count, 640, label)
                    actual += decoded
                    expected += try oracle.decode(packet)
                }
                XCTAssertEqual(actual, expected, "\(label): decode each unique packet once in sequence")
                XCTAssertEqual(concealed, profile.payloadType == 0x96 ? 640 : 0, label)
                XCTAssertEqual(oracle.concealedSamples, concealed, label)
                XCTAssertEqual(Array(actual.suffix(4 * 640)), Array(expected.suffix(4 * 640)), "\(label): clean tail")
                reorder.reset()
                XCTAssertEqual(reorder.deliveredSequencedPacketCount, 0)
                XCTAssertEqual(reorder.duplicateOrLatePacketCount, 0)
                XCTAssertEqual(reorder.missingPacketCount, 0)
            }
        }
    }

    private func assertCounters(_ peer: SimulatedSvxLinkMatrixPeer, packets: [Data], duplicates: Int, missing: Int) async {
        let diagnostics = await peer.service.audioDiagnosticsSnapshot()
        XCTAssertEqual(diagnostics.rxPackets, packets.count)
        XCTAssertEqual(diagnostics.sequencedRXPackets, packets.count)
        XCTAssertEqual(diagnostics.rxPayloadBytes, packets.reduce(0) { $0 + $1.count - 12 })
        XCTAssertEqual(diagnostics.duplicateOrLateRXPackets, duplicates)
        XCTAssertEqual(diagnostics.missingRXPackets, missing)
        XCTAssertEqual(diagnostics.invalidRXPackets, 0)
        XCTAssertEqual(diagnostics.rxQueuedPackets, 0)
        XCTAssertEqual(diagnostics.transportRXDrops, 0)
        XCTAssertEqual(diagnostics.playbackRXDrops, 0)
        XCTAssertEqual(peer.service.auditTransportSnapshot["rxAccepted"], peer.acceptedBaseline + packets.count)
        XCTAssertFalse(peer.audio.isRunning)
        XCTAssertFalse(peer.audio.isCapturing)
    }
}
