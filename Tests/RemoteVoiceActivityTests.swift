// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class RemoteVoiceActivityTests: XCTestCase {
    func testAcceptedRemoteVoiceBlocksPTTUntilActivityExpires() async {
        let service = EchoLinkConnectionService(remoteVoiceActivityHold: .milliseconds(40))
        service.session = QSOSession(
            station: Station(callsign: "N0CALL", ipAddress: "127.0.0.1"),
            state: .connected
        )

        service.noteIncomingAudioActivity()

        XCTAssertTrue(service.isRemoteTransmitting)
        XCTAssertFalse(service.canTransmit)
        service.sendPTT(active: true)
        XCTAssertFalse(service.session?.isPTTActive ?? true)

        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(service.isRemoteTransmitting)
        XCTAssertTrue(service.canTransmit)
    }

    func testVoiceObservedDuringLocalPTTDoesNotLockNextTransmission() {
        let service = EchoLinkConnectionService(remoteVoiceActivityHold: .seconds(1))
        service.session = QSOSession(
            station: Station(callsign: "N0CALL", ipAddress: "127.0.0.1"),
            state: .connected,
            isPTTActive: true
        )

        service.noteIncomingAudioActivity()

        XCTAssertFalse(service.isRemoteTransmitting)
    }

    func testMutedIncomingVoiceStillBlocksPTT() async {
        let service = EchoLinkConnectionService(remoteVoiceActivityHold: .seconds(1))
        service.session = QSOSession(
            station: Station(callsign: "N0CALL", ipAddress: "127.0.0.1"),
            state: .connected,
            isMuted: true
        )
        let encoded = GSMCodec().encode(Array(repeating: 5_000, count: GSMCodec.samplesPerFrame))
        let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: Data(encoded.dropFirst(GSMCodec.packetHeader.count)),
            sequence: 1
        )

        await service.handleAudioData(packet)

        XCTAssertTrue(service.isRemoteTransmitting)
        XCTAssertFalse(service.canTransmit)
    }

    func testMutedSilentPacketsDoNotBlockPTT() async {
        let service = EchoLinkConnectionService(remoteVoiceActivityHold: .seconds(1))
        service.session = QSOSession(
            station: Station(callsign: "N0CALL", ipAddress: "127.0.0.1"),
            state: .connected,
            isMuted: true
        )
        var packet = Data([0x80, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(contentsOf: repeatElement(UInt8(0xFF), count: 160))

        await service.handleAudioData(packet)

        XCTAssertFalse(service.isRemoteTransmitting)
        XCTAssertTrue(service.canTransmit)
    }

    func testSilentIncomingPacketsDoNotHoldReceiveBusy() async {
        let service = EchoLinkConnectionService(remoteVoiceActivityHold: .milliseconds(40))
        service.session = QSOSession(
            station: Station(callsign: "N0CALL", ipAddress: "127.0.0.1"),
            state: .connected
        )

        for sequence in 1...4 {
            var packet = Data([0x80, 0x00, 0, UInt8(sequence), 0, 0, 0, 0, 0, 0, 0, 0])
            packet.append(contentsOf: repeatElement(UInt8(0xFF), count: 160))
            await service.handleAudioData(packet)
        }

        XCTAssertFalse(service.isRemoteTransmitting)
        XCTAssertTrue(service.canTransmit)
    }

    func testAudibleIncomingPacketBlocksPTT() async {
        let service = EchoLinkConnectionService(remoteVoiceActivityHold: .seconds(1))
        service.session = QSOSession(
            station: Station(callsign: "N0CALL", ipAddress: "127.0.0.1"),
            state: .connected
        )

        var packet = Data([0x80, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(contentsOf: repeatElement(UInt8(0x00), count: 160))
        await service.handleAudioData(packet)

        XCTAssertTrue(service.isRemoteTransmitting)
        XCTAssertFalse(service.canTransmit)
    }

    func testViewModelPublishesServiceTransmitAvailability() async {
        let service = EchoLinkConnectionService(remoteVoiceActivityHold: .seconds(1))
        let viewModel = QSOViewModel(connectionService: service)
        service.session = QSOSession(
            station: Station(callsign: "N0CALL", ipAddress: "127.0.0.1"),
            state: .connected
        )
        await drainMainQueue()

        XCTAssertTrue(viewModel.canTransmit)
        XCTAssertFalse(viewModel.isRemoteTransmitting)

        service.noteIncomingAudioActivity()
        await drainMainQueue()

        XCTAssertFalse(viewModel.canTransmit)
        XCTAssertTrue(viewModel.isRemoteTransmitting)
    }

    private func drainMainQueue() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}
