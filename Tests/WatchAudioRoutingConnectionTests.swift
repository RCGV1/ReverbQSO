// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class WatchAudioRoutingConnectionTests: XCTestCase {
    private func pcmPacket(sequence: UInt16, byte: UInt8 = 0) -> Data {
        var packet = Data([
            0x80, 100,
            UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence),
            0, 0, 0, 0, // timestamp
            0, 0, 0, 1, // SSRC
        ])
        packet.append(Data(repeating: byte, count: 160))
        return packet
    }

    private func speexPacket(sequence: UInt16, payload: Data) -> Data {
        EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: payload,
            sequence: sequence,
            codec: .speex
        )
    }

    private func connectedService(
        defaults: UserDefaults = .standard,
        folder: URL? = nil
    ) -> EchoLinkConnectionService {
        let service = EchoLinkConnectionService(
            audioEngine: AudioEngine(),
            recordingDefaults: defaults,
            recordingFolder: folder
        )
        service.session = QSOSession(
            station: Station(callsign: "K6WATCH", ipAddress: "192.0.2.1"),
            state: .connected
        )
        return service
    }

    func testWatchOutputSelectionRequiresAvailabilityAndFallsBackWhenUnavailable() {
        let suite = "WatchAudioRoutingConnectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let service = connectedService(defaults: defaults, folder: folder)
        service.onReceivedVoicePacket = { _ in }

        service.setWatchAudioOutput(true)
        XCTAssertFalse(service.usesWatchAudioOutput)

        service.setWatchAudioAvailability(true)
        service.setWatchAudioOutput(true)
        XCTAssertTrue(service.usesWatchAudioOutput)

        service.setWatchAudioAvailability(false)
        XCTAssertFalse(service.watchAudioOutputAvailable)
        XCTAssertFalse(service.usesWatchAudioOutput)
    }

    func testAcceptedNetworkPCMForwardsAndRecordsOnceWhileDuplicateIsDropped() async throws {
        let suite = "WatchAudioRoutingConnectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey())
        let service = connectedService(defaults: defaults, folder: folder)
        var forwarded: [Data] = []
        service.onReceivedVoicePacket = { forwarded.append($0) }
        service.setWatchAudioAvailability(true)
        service.setWatchAudioOutput(true)
        let packet = pcmPacket(sequence: 7)

        await service.handleAudioData(packet)
        await service.handleAudioData(packet)
        service.session = nil

        XCTAssertEqual(forwarded, [packet])
        let recording = try XCTUnwrap(
            QSORecordingService(folder: folder).recordings.first(where: { $0.kind == .qso })
        )
        XCTAssertEqual(recording.duration, 160.0 / 8_000)
        XCTAssertEqual(try Data(contentsOf: recording.url).count, 44 + (160 * 2))
    }

    func testOutOfOrderPCMForwardsAndRecordsInSequenceOrder() async throws {
        let suite = "WatchAudioRoutingConnectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        defaults.set(true, forKey: RecordingPreferences.alwaysRecordKey())
        let service = connectedService(defaults: defaults, folder: folder)
        var forwarded: [Data] = []
        service.onReceivedVoicePacket = { forwarded.append($0) }
        service.setWatchAudioAvailability(true)
        service.setWatchAudioOutput(true)
        let ten = pcmPacket(sequence: 10, byte: 0x10)
        let eleven = pcmPacket(sequence: 11, byte: 0x20)
        let twelve = pcmPacket(sequence: 12, byte: 0x30)

        await service.handleAudioData(ten)
        await service.handleAudioData(twelve)
        XCTAssertEqual(forwarded, [ten])
        await service.handleAudioData(eleven)
        service.session = nil

        XCTAssertEqual(forwarded, [ten, eleven, twelve])
        let recording = try XCTUnwrap(
            QSORecordingService(folder: folder).recordings.first(where: { $0.kind == .qso })
        )
        let wav = try Data(contentsOf: recording.url)
        XCTAssertEqual(recording.duration, 480.0 / 8_000)
        XCTAssertEqual(wavSample(at: 0, in: wav), EchoLinkAudioPacketCodec.decodeMuLaw(0x10))
        XCTAssertEqual(wavSample(at: 160, in: wav), EchoLinkAudioPacketCodec.decodeMuLaw(0x20))
        XCTAssertEqual(wavSample(at: 320, in: wav), EchoLinkAudioPacketCodec.decodeMuLaw(0x30))
    }

    func testPendingGapDoesNotForwardAfterDisconnect() async throws {
        let service = connectedService()
        var forwarded: [Data] = []
        service.onReceivedVoicePacket = { forwarded.append($0) }
        service.setWatchAudioAvailability(true)
        service.setWatchAudioOutput(true)
        let ten = pcmPacket(sequence: 10)
        let twelve = pcmPacket(sequence: 12)

        await service.handleAudioData(ten)
        await service.handleAudioData(twelve)
        XCTAssertEqual(forwarded, [ten])

        await service.disconnect()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(forwarded, [ten])
    }

    func testValidSpeexRetransmissionAfterMalformedPacketWithSameSequenceForwards() async {
        let service = connectedService()
        var forwarded: [Data] = []
        service.onReceivedVoicePacket = { forwarded.append($0) }
        service.setWatchAudioAvailability(true)
        service.setWatchAudioOutput(true)
        let malformed = speexPacket(
            sequence: 10,
            payload: Data(SpeexCodecTests.fixture.prefix(SpeexCodecTests.fixture.count / 2))
        )
        let valid = speexPacket(sequence: 10, payload: SpeexCodecTests.fixture)

        await service.handleAudioData(malformed)
        await service.handleAudioData(valid)

        XCTAssertEqual(forwarded, [valid])
    }

    func testMutedAndBackgroundMutedReceiveAudioIsNotForwarded() async {
        let suite = "WatchAudioRoutingConnectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let service = connectedService(defaults: defaults, folder: folder)
        var forwarded: [Data] = []
        service.onReceivedVoicePacket = { forwarded.append($0) }
        service.setWatchAudioAvailability(true)
        service.setWatchAudioOutput(true)

        service.session?.isMuted = true
        await service.handleAudioData(pcmPacket(sequence: 1))

        service.session?.isMuted = false
        service.setBackgroundMuted(true)
        await service.handleAudioData(pcmPacket(sequence: 2))

        XCTAssertTrue(forwarded.isEmpty)
    }

    private func wavSample(at sampleIndex: Int, in data: Data) -> Int16 {
        let offset = 44 + sampleIndex * 2
        let bits = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        return Int16(bitPattern: bits)
    }
}
