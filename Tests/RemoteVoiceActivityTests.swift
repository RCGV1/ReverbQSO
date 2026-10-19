// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class RemoteVoiceActivityTests: XCTestCase {
    func testSvxLinkRemoteOperatorRemainsTheTalkerWhenAudioArrives() async {
        let service = EchoLinkConnectionService()
        service.session = QSOSession(
            station: Station(callsign: "W6SLG-R", ipAddress: "127.0.0.1", type: .repeater),
            state: .connected
        )
        await service.handleAudioData(EchoLinkControlPacketCodec.buildNDATAInfoPacket(message: """
        SvxLink 26.05.1 - W6SLG-R (1)

        > K1ABC         Alex

        W6SLG-R         UCSC repeater
        """))
        service.noteIncomingAudioActivity()

        XCTAssertEqual(service.activeNodeParticipants.filter(\.isTransmitting).map(\.callsign), ["K1ABC"])
        await service.disconnect()
    }

    func testSvxLinkRosterSwitchesOperatorAndThenClearsOnIdle() async {
        let service = EchoLinkConnectionService()
        service.session = QSOSession(
            station: Station(callsign: "W6SLG-R", ipAddress: "127.0.0.1", type: .repeater),
            state: .connected
        )
        for callsign in ["K1ABC", "K2XYZ"] {
            await service.handleAudioData(EchoLinkControlPacketCodec.buildNDATAInfoPacket(message: """
            SvxLink 26.05.1 - W6SLG-R (2)

            > \(callsign)         Operator

            W6SLG-R         UCSC repeater
            """))
            service.noteIncomingAudioActivity()
            XCTAssertEqual(service.activeNodeParticipants.filter(\.isTransmitting).map(\.callsign), [callsign])
        }
        await service.handleAudioData(EchoLinkControlPacketCodec.buildNDATAInfoPacket(message: """
        SvxLink 26.05.1 - W6SLG-R (2)

        W6SLG-R         UCSC repeater
        K1ABC         Alex
        K2XYZ         Taylor
        """))
        XCTAssertFalse(service.activeNodeParticipants.contains { $0.isTransmitting })
        await service.disconnect()
    }

    func testParticipantTalkingClearsWhenReceiveActivityExpires() async throws {
        let service = EchoLinkConnectionService(remoteVoiceActivityHold: .milliseconds(40))
        service.session = QSOSession(
            station: Station(callsign: "N0CALL-R", ipAddress: "127.0.0.1"),
            state: .connected
        )
        service.noteIncomingAudioActivity()
        XCTAssertTrue(service.activeNodeParticipants.contains { $0.isTransmitting })

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(service.isRemoteTransmitting)
        XCTAssertFalse(service.activeNodeParticipants.contains { $0.isTransmitting })
        XCTAssertEqual(service.activeNodeParticipants.map(\.callsign), ["N0CALL-R"])
        await service.disconnect()
    }

    func testRosterRefreshDoesNotKeepStatusOnlyTalkerStuck() async throws {
        let service = EchoLinkConnectionService()
        service.session = QSOSession(
            station: Station(callsign: "N0CALL-R", ipAddress: "127.0.0.1"),
            state: .connected
        )
        await service.handleAudioData(EchoLinkControlPacketCodec.buildNDATAInfoPacket(
            message: "K1ABC is transmitting"))
        XCTAssertTrue(service.activeNodeParticipants.contains { $0.callsign == "K1ABC" && $0.isTransmitting })

        try await Task.sleep(for: .milliseconds(1500))
        await service.handleAudioData(EchoLinkControlPacketCodec.buildNDATAInfoPacket(
            message: "K1ABC online"))
        try await Task.sleep(for: .milliseconds(750))

        XCTAssertFalse(service.activeNodeParticipants.contains { $0.isTransmitting })
        XCTAssertTrue(service.activeNodeParticipants.contains { $0.callsign == "K1ABC" })
        await service.disconnect()
    }

    func testContinuedVoiceKeepsTalkingUntilTheLatestBurstExpires() async throws {
        let service = EchoLinkConnectionService(remoteVoiceActivityHold: .milliseconds(200))
        service.session = QSOSession(
            station: Station(callsign: "N0CALL-R", ipAddress: "127.0.0.1"),
            state: .connected
        )
        service.noteIncomingAudioActivity()
        try await Task.sleep(for: .milliseconds(120))
        service.noteIncomingAudioActivity()
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(service.isRemoteTransmitting)
        XCTAssertTrue(service.activeNodeParticipants.contains { $0.isTransmitting })
        try await Task.sleep(for: .milliseconds(160))

        XCTAssertFalse(service.isRemoteTransmitting)
        XCTAssertFalse(service.activeNodeParticipants.contains { $0.isTransmitting })
        await service.disconnect()
    }

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
