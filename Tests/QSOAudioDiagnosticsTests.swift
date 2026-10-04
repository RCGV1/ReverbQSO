// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class QSOAudioDiagnosticsTests: XCTestCase {
    @MainActor
    func testMalformedGSMDoesNotConsumeSequenceOrCountAsReceivedAudio() async throws {
        let service = EchoLinkConnectionService()
        service.session = QSOSession(station: Station(callsign: "N0TEST", ipAddress: "127.0.0.1"),
                                     state: .connected, isMuted: true)
        let valid = try XCTUnwrap(GSMCodec.stripHeader(GSMCodec().encode(Array(repeating: 0, count: 640))))
        var wrongHeader = valid
        wrongHeader[33] = 0
        for malformed in [Data([0]), Data(valid.dropLast()), wrongHeader, valid + valid] {
            await service.handleAudioData(EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                gsmPayload: malformed, sequence: 1))
        }
        let rejected = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(rejected.rxPackets, 0)
        XCTAssertEqual(rejected.sequencedRXPackets, 0)
        XCTAssertEqual(rejected.invalidRXPackets, 4)
        await service.handleAudioData(EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: valid, sequence: 1))
        let admitted = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(admitted.rxPackets, 1)
        XCTAssertEqual(admitted.rxPayloadBytes, valid.count)
        XCTAssertEqual(admitted.duplicateOrLateRXPackets, 0)
        await service.disconnect()
    }

    @MainActor
    func testG711FramingRejectsMalformedPayloadBeforeSequenceAdmission() async {
        let service = EchoLinkConnectionService()
        service.session = QSOSession(station: Station(callsign: "N0TEST", ipAddress: "127.0.0.1"),
                                     state: .connected, isMuted: true)
        for count in [1, 79, 161, 720] {
            var packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                gsmPayload: Data(repeating: 0xFF, count: count), sequence: 1)
            packet[1] = 8
            await service.handleAudioData(packet)
        }
        let rejected = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(rejected.invalidRXPackets, 4)
        XCTAssertEqual(rejected.rxPackets, 0)
        XCTAssertEqual(rejected.sequencedRXPackets, 0)
        for (index, count) in [80, 160, 240, 640].enumerated() {
            var packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                gsmPayload: Data(repeating: 0xFF, count: count), sequence: UInt16(index + 1))
            packet[1] = 8
            await service.handleAudioData(packet)
        }
        let admitted = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(admitted.rxPackets, 4)
        XCTAssertEqual(admitted.rxPayloadBytes, 1_120)
        XCTAssertEqual(admitted.duplicateOrLateRXPackets, 0)
        await service.disconnect()
    }

    @MainActor
    func testReceivePreservesOneThroughFourGSMFramePackets() async throws {
        let service = EchoLinkConnectionService()
        service.session = QSOSession(station: Station(callsign: "N0TEST", ipAddress: "127.0.0.1"),
                                     state: .connected, isMuted: true)
        for frames in 1...4 {
            let payload = try XCTUnwrap(GSMCodec.stripHeader(GSMCodec().encode(
                Array(repeating: 0, count: 160 * frames))))
            await service.handleAudioData(EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                gsmPayload: payload, sequence: UInt16(frames)))
        }
        let admitted = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(admitted.rxPackets, 4)
        XCTAssertEqual(admitted.rxPayloadBytes, 330)
        XCTAssertEqual(admitted.invalidRXPackets, 0)
        await service.disconnect()
    }

    @MainActor
    func testGSMAndSpeexReceiveTotalsUseAcceptedEncodedPayloads() async throws {
        let gsm = try XCTUnwrap(GSMCodec.stripHeader(GSMCodec().encode(Array(repeating: 0, count: 640))))
        let speex = SpeexCodecTests.fixture
        let service = EchoLinkConnectionService()
        service.session = QSOSession(station: Station(callsign: "N0TEST", ipAddress: "127.0.0.1"),
                                     state: .connected, isMuted: true)
        await service.handleAudioData(EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: gsm, sequence: 1))
        let first = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(first.rxCodec, "GSM")
        await service.handleAudioData(EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: speex, sequence: 2, codec: .speex))
        let second = await service.audioDiagnosticsSnapshot()
        XCTAssertEqual(second.rxCodec, "Speex")
        XCTAssertEqual(second.rxPayloadBytes, gsm.count + speex.count)
        XCTAssertEqual(second.rxPackets, 2)
        await service.disconnect()
    }

    @MainActor
    func testG711ReportsWireCodecAndEncodedByteCounts() async {
        let service = EchoLinkConnectionService()
        service.session = QSOSession(station: Station(callsign: "N0TEST", ipAddress: "127.0.0.1"),
                                     state: .connected, isMuted: true)
        for (sequence, payloadType, name) in [(UInt16(1), UInt8(0), "G.711 µ-law"), (2, 8, "G.711 A-law")] {
            var packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                gsmPayload: Data(repeating: 0xFF, count: 160), sequence: sequence)
            packet[1] = payloadType
            await service.handleAudioData(packet)
            let snapshot = await service.audioDiagnosticsSnapshot()
            XCTAssertEqual(snapshot.rxCodec, name)
            XCTAssertEqual(snapshot.rxPayloadBytes, Int(sequence) * 160)
            XCTAssertEqual(snapshot.rxPackets, Int(sequence))
        }
        await service.disconnect()
    }

    func testPayloadRatesUseElapsedTimeAndBecomeZeroWhenIdle() {
        var sampler = QSOAudioBitrateSampler()
        var snapshot = QSOAudioDiagnosticsSnapshot(sessionID: UUID())
        XCTAssertNil(sampler.sample(snapshot, now: 10).rxKilobitsPerSecond)
        snapshot.txPayloadBytes = 1650
        snapshot.rxPayloadBytes = 3300
        let rates = sampler.sample(snapshot, now: 11)
        XCTAssertEqual(rates.txKilobitsPerSecond!, 13.2, accuracy: 0.001)
        XCTAssertEqual(rates.rxKilobitsPerSecond!, 26.4, accuracy: 0.001)
        XCTAssertEqual(sampler.sample(snapshot, now: 12).rxKilobitsPerSecond, 0)
    }

    func testRatesRestartForANewSessionOrResetCounters() {
        var sampler = QSOAudioBitrateSampler()
        var snapshot = QSOAudioDiagnosticsSnapshot(sessionID: UUID(), rxPayloadBytes: 1000)
        _ = sampler.sample(snapshot, now: 0)
        snapshot.sessionID = UUID()
        XCTAssertNil(sampler.sample(snapshot, now: 1).rxKilobitsPerSecond)
        snapshot.rxPayloadBytes = 0
        XCTAssertNil(sampler.sample(snapshot, now: 2).rxKilobitsPerSecond)
        XCTAssertNil(sampler.sample(snapshot, now: 2).rxKilobitsPerSecond)
        XCTAssertNil(sampler.sample(snapshot, now: .nan).rxKilobitsPerSecond)
    }

    func testLossIsUnavailableBeforeSequencedAudioAndExcludesDuplicates() {
        var snapshot = QSOAudioDiagnosticsSnapshot()
        XCTAssertNil(snapshot.estimatedRXLossPercent)
        snapshot.sequencedRXPackets = 95
        snapshot.missingRXPackets = 5
        snapshot.duplicateOrLateRXPackets = 10
        XCTAssertEqual(snapshot.estimatedRXLossPercent!, 5, accuracy: 0.001)
    }
}
