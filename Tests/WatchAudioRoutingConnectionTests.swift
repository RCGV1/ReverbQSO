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
}
