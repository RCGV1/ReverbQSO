// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ReverbQSO

final class SpeexTransmitNegotiationTests: XCTestCase {
    func testHandshakeAdvertisesSpeexAlongsideLegacyPortAndDTMFFields() throws {
        let packet = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0TST")
        let info = try XCTUnwrap(EchoLinkControlPacketCodec.parseEvents(from: packet).compactMap {
            if case .sdes(let info) = $0 { return info }; return nil
        }.first)
        XCTAssertTrue(info.privateItems.contains("SPEEX"))
        XCTAssertEqual(info.privateItems.first, "SPEEX", "EchoLib peers inspect only the first PRIV item")
        XCTAssertTrue(packet.range(of: Data([8, 5] + Array("SPEEX".utf8))) != nil,
                      "Legacy Speex capability is a raw PRIV item, without an RFC prefix-length byte")
        XCTAssertTrue(info.privateItems.contains("P5198"))
        XCTAssertTrue(info.privateItems.contains("D0"))
    }

    func testUnknownAndPadPermissionsDoNotSelectSpeex() {
        for items in [[], ["P5198", "D0"], ["D1"], ["NOSPEEX"], ["SPEEXISH"], ["speex"]] {
            var info = EchoLinkSDESInfo()
            info.privateItems = items
            XCTAssertFalse(info.supportsSpeex)
        }
        for items in [["SPEEX"], ["P5198", "SPEEX", "D1"], ["GSM,SPEEX"]] {
            var info = EchoLinkSDESInfo()
            info.privateItems = items
            XCTAssertTrue(info.supportsSpeex)
        }
    }

    func testDisabledSpeexAdvertisementPreservesGSMHandshake() throws {
        let packet = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0TST", advertiseSpeex: false)
        let info = try XCTUnwrap(EchoLinkControlPacketCodec.parseEvents(from: packet).compactMap {
            if case .sdes(let info) = $0 { return info }; return nil
        }.first)
        XCTAssertFalse(info.supportsSpeex)
        XCTAssertEqual(info.privateItems, ["P5198", "D0"])
    }

    func testSpeexPacketPreservesPayloadAndClockWithoutGSMSlicing() throws {
        let payload = SpeexCodecTests.fixture
        let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: payload, sequence: 0x1234, timestamp: 0x12345678, codec: .speex)
        XCTAssertEqual(Array(packet.prefix(12)), [0xC0, 0x96, 0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0])
        XCTAssertEqual(packet.count, 162)
        let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet))
        XCTAssertEqual(parsed.packet, .speex(payload))
        XCTAssertEqual(try XCTUnwrap(SpeexCodec().decodePacket(payload)).count, 640)
    }
}

@MainActor
final class SpeexTransmitCaptureTests: XCTestCase {
    func testPartialCaptureFlushesOneSpeexPacketAndNextBurstStartsClean() throws {
        let engine = AudioEngine()
        XCTAssertTrue(engine.setTransmitCodec(.speex))
        var emitted: [Data] = []
        var recordedPCM: [Int16] = []
        engine.onCapturedAudio = { emitted.append($0) }
        engine.onCapturedPCM = { recordedPCM += $0 }
        let speech = (0..<701).map { Int16(10_000 * sin(Double($0) * 0.1728)) }
        engine.encodeTransmitPCM(Array(speech.prefix(137)))
        XCTAssertTrue(emitted.isEmpty)
        engine.encodeTransmitPCM(Array(speech.dropFirst(137)))
        XCTAssertEqual(emitted.count, 1)
        _ = engine.stopCaptureAndFlush()
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(recordedPCM, speech, "Padding must not be reported as microphone samples")
        let decoder = SpeexCodec()
        for packet in emitted { XCTAssertEqual(try XCTUnwrap(decoder.decodePacket(packet)).count, 640) }
        _ = engine.stopCaptureAndFlush()
        XCTAssertEqual(emitted.count, 2, "No silent packet after the tail was consumed")
        engine.encodeTransmitPCM(Array(speech.prefix(640)))
        XCTAssertEqual(emitted[2], emitted[0], "Each PTT burst resets encoding history")
    }

    func testSwitchingBackToGSMDoesNotRetainSpeexTail() throws {
        let engine = AudioEngine()
        var emitted: [Data] = []
        engine.onCapturedAudio = { emitted.append($0) }
        XCTAssertTrue(engine.setTransmitCodec(.speex))
        engine.encodeTransmitPCM([100, -100, 20])
        XCTAssertTrue(engine.setTransmitCodec(.gsm))
        engine.encodeTransmitPCM([Int16](repeating: 500, count: 137))
        _ = engine.stopCaptureAndFlush()
        XCTAssertEqual(emitted.count, 1)
        let gsm = try XCTUnwrap(GSMCodec.stripHeader(emitted[0]))
        XCTAssertEqual(gsm.count, 132)
        XCTAssertEqual(GSMCodec().decodePacket(gsm).count, 640)
    }
}
