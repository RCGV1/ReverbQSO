// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class LocalDemoConnectionTests: XCTestCase {
    func testRelayOnlyStationRejectedBeforeSessionOrPlayback() async {
        var playbackCount = 0
        let service = makeService(localDemoPlayback: { _ in playbackCount += 1 })
        service.enableLocalDemo(callsign: "DEMO")
        var station = LocalDemoAccount.stations[0]
        station.description = "Mobile [r] [ON 12:34]"
        await service.connect(to: station)
        XCTAssertNil(service.session)
        XCTAssertEqual(service.error?.localizedDescription, "Connection failed: This station cannot receive calls.")
        XCTAssertEqual(playbackCount, 0)
        await service.disconnect()
    }

    func testOutgoingRestrictionStopsBeforeCreatingDemoSession() async {
        let service = makeService(localDemoPlayback: { _ in })
        service.enableLocalDemo(callsign: "DEMO")
        service.callAccessPolicyProvider = {
            var policy = CallAccessPolicy()
            policy.allowedTypes = []
            return policy
        }
        await service.connect(to: LocalDemoAccount.stations[0])
        XCTAssertNil(service.session)
        XCTAssertNotNil(service.error)
    }

    func testBundledWelcomeContainsDecodableSpeechWithReceiveGainHeadroom() throws {
        let packets = LocalDemoAnnouncement.echoTestPackets()
        XCTAssertGreaterThan(packets.count, 50, "Spoken welcome must be bundled in the app")
        XCTAssertLessThan(packets.count, 150)
        let codec = GSMCodec()
        let samples = packets.flatMap { codec.decodePacket($0) }
        XCTAssertEqual(samples.count, packets.count * 640)
        let peak = try XCTUnwrap(samples.map { abs(Int($0)) }.max())
        XCTAssertGreaterThan(peak, 1_000)
        XCTAssertLessThan(peak, 13_000, "Speech needs headroom for the normal RX gain")
    }

    func testWelcomeUsesReceiveStateAndReleasesPTTAfterPlayback() async throws {
        let packets = Array(LocalDemoAnnouncement.echoTestPackets().dropFirst(8).prefix(3))
        XCTAssertEqual(packets.count, 3)
        var played: [Data] = []
        let service = makeService(localDemoPlayback: { played.append($0) }, localDemoAnnouncement: { packets })
        service.enableLocalDemo(callsign: "DEMO")
        await service.connect(to: LocalDemoAccount.stations[0])
        XCTAssertTrue(service.isRemoteTransmitting)
        XCTAssertFalse(service.canTransmit)
        try await waitUntil { !service.isRemoteTransmitting }
        XCTAssertEqual(played, packets)
        XCTAssertTrue(service.canTransmit)
        XCTAssertFalse(service.isSendingDTMF)
        await service.disconnect()
    }

    func testLeavingDuringWelcomeDelayCancelsAnnouncement() async throws {
        var played = 0
        let service = makeService(localDemoPlayback: { _ in played += 1 }, localDemoAnnouncement: {
            LocalDemoAnnouncement.echoTestPackets()
        })
        service.enableLocalDemo(callsign: "DEMO")
        await service.connect(to: LocalDemoAccount.stations[0])
        XCTAssertTrue(service.isRemoteTransmitting)
        service.setBackgroundMuted(true)
        XCTAssertFalse(service.isRemoteTransmitting)
        await service.disconnect()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(played, 0)
    }

    func testAnnouncementRejectsCorruptOrIncompleteGSMResource() {
        XCTAssertTrue(LocalDemoAnnouncement.packets(from: Data()).isEmpty)
        XCTAssertTrue(LocalDemoAnnouncement.packets(from: Data(repeating: 0, count: 132)).isEmpty)
        var valid = LocalDemoAnnouncement.echoTestPackets().reduce(into: Data()) { $0.append($1) }
        valid.removeLast()
        XCTAssertTrue(LocalDemoAnnouncement.packets(from: valid).isEmpty)
    }

    func testDemoIdentityAndStationCannotFallThroughToRealNetwork() async {
        let service = makeService(localDemoPlayback: { _ in })
        XCTAssertFalse(service.enableLocalDemo(callsign: "W1AW"))
        XCTAssertFalse(service.isLocalDemoMode)
        XCTAssertTrue(service.enableLocalDemo(callsign: "DEMO"))
        await service.connect(to: Station(callsign: "REAL", ipAddress: "198.51.100.1"))
        XCTAssertNil(service.session)
        XCTAssertNotNil(service.error)
        XCTAssertEqual(service.localCallsign, "DEMO")
    }

    func testRemotePadPlaybackStopsWhenAccountLosesAudioFocus() async throws {
        var played: [Data] = []
        let service = makeService(localDemoPlayback: { played.append($0) })
        XCTAssertTrue(service.enableLocalDemo(callsign: "DEMO"))
        let repeater = try XCTUnwrap(LocalDemoAccount.stations.first { $0.type == .repeater })
        await service.connect(to: repeater)
        XCTAssertTrue(service.canSendRemoteDTMF)
        service.sendRemoteDTMF("123")
        try await waitUntil { !played.isEmpty }
        XCTAssertTrue(service.isSendingDTMF)
        service.setBackgroundMuted(true)
        XCTAssertFalse(service.isSendingDTMF)
        XCTAssertFalse(service.isRemoteTransmitting)
        let count = played.count
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(played.count, count)
        await service.disconnect()
    }

    func testDemoConnectChatAndDisconnectNeverConsultTransportOrIdentityResolvers() async throws {
        let service = makeService()
        XCTAssertTrue(service.enableLocalDemo(callsign: " demo "))
        service.authenticatedCallsign = "REAL-CALLSIGN"
        XCTAssertEqual(service.localCallsign, "DEMO")
        let station = try XCTUnwrap(LocalDemoAccount.stations.first)
        await service.connect(to: station)
        XCTAssertEqual(service.session?.state, .connected)
        XCTAssertFalse(service.disableLocalDemo())
        XCTAssertFalse(service.enableLocalDemo(callsign: "DEMO2"))
        await service.sendChat(message: "Hello from review")
        XCTAssertTrue(service.incomingChatMessages.contains { $0.isOutgoing && $0.sender == "DEMO" && $0.body == "Hello from review" })
        await service.disconnect()
        XCTAssertNil(service.session)
        XCTAssertFalse(service.isRemoteTransmitting)
        XCTAssertTrue(service.disableLocalDemo())
        XCTAssertFalse(service.isLocalDemoMode)
    }

    func testDemoReconnectUsesLocalFixtureWithoutDirectoryRefresh() async throws {
        let service = makeService()
        XCTAssertTrue(service.enableLocalDemo(callsign: "DEMO2"))
        let station = try XCTUnwrap(LocalDemoAccount.stations.first)
        service.registerReconnectCandidate(station)
        await service.reconnect()
        XCTAssertEqual(service.session?.state, .connected)
        XCTAssertEqual(service.localCallsign, "DEMO2")
        await service.disconnect()
    }

#if targetEnvironment(simulator)
    func testSimulatorPTTEchoIsPacedAndDisconnectCancelsOldPlayback() async throws {
        var played: [Data] = []
        let service = makeService(localDemoPlayback: { played.append($0) })
        XCTAssertTrue(service.enableLocalDemo(callsign: "DEMO"))
        await service.connect(to: try XCTUnwrap(LocalDemoAccount.stations.first))
        service.sendPTT(active: true)
        XCTAssertEqual(service.session?.isPTTActive, true)
        service.sendPTT(active: false)
        try await waitUntil { service.isRemoteTransmitting && !played.isEmpty }
        XCTAssertFalse(service.canTransmit)
        XCTAssertLessThan(played.count, 5)
        XCTAssertTrue(GSMCodec().decodePacket(try XCTUnwrap(played.first)).contains { abs(Int($0)) > 100 })
        await service.disconnect()
        let countAtDisconnect = played.count
        await service.connect(to: try XCTUnwrap(LocalDemoAccount.stations.first))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(played.count, countAtDisconnect)
        XCTAssertFalse(service.isRemoteTransmitting)
        await service.disconnect()
    }

    func testDemoPTTRequiresFocusAndAccountPermission() async throws {
        var played = 0
        let service = makeService(localDemoPlayback: { _ in played += 1 })
        XCTAssertTrue(service.enableLocalDemo(callsign: "DEMO"))
        await service.connect(to: try XCTUnwrap(LocalDemoAccount.stations.first))
        service.pttPermission = { false }
        service.sendPTT(active: true)
        XCTAssertEqual(service.session?.isPTTActive, false)
        service.pttPermission = { true }
        service.setBackgroundMuted(true)
        service.sendPTT(active: true)
        XCTAssertEqual(service.session?.isPTTActive, false)
        XCTAssertEqual(played, 0)
        await service.disconnect()
    }
#endif

    private func makeService(localDemoPlayback: (@MainActor (Data) -> Void)? = nil,
                             localDemoAnnouncement: @escaping @MainActor () -> [Data] = { [] }) -> EchoLinkConnectionService {
        let service = EchoLinkConnectionService(
            relayClientFactory: { XCTFail("Demo must not allocate a relay"); return EchoLinkRelayClient() },
            selectedRelayClientFactory: { _ in XCTFail("Demo must not allocate a pinned relay"); return EchoLinkRelayClient() },
            networkConfigurationProvider: { XCTFail("Demo must not read stored configuration"); return .init(mode: .direct, host: "", port: 8100, password: "") },
            localDemoPlayback: localDemoPlayback,
            localDemoAnnouncement: localDemoAnnouncement
        )
        service.effectiveTransportProvider = { XCTFail("Demo must not inspect transport selection"); return nil }
        service.resolveStation = { _ in XCTFail("Demo must not resolve real endpoints"); return LocalDemoAccount.stations[0] }
        service.resolveReconnectStation = { _ in XCTFail("Demo must not refresh a real directory"); return nil }
        service.resolveProxySession = { _ in XCTFail("Demo must not authenticate a proxy"); return nil }
        return service
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Local echo did not begin")
    }
}
