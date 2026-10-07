// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import Combine
@testable import ReverbQSO

final class VoicePipelineSmokeTests: XCTestCase {
#if targetEnvironment(simulator)
    @MainActor
    func testFailedCaptureRetiresStartTaskSoRemotePadRemainsAvailable() async throws {
        let service = EchoLinkConnectionService()
        service.session = QSOSession(
            station: Station(callsign: "N0CALL-L", ipAddress: "127.0.0.1", type: .link),
            state: .connected
        )
        var packet = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0CALL-L")
        let capability = try XCTUnwrap(packet.range(of: Data("D0".utf8)))
        packet.replaceSubrange(capability, with: Data("D1".utf8))
        await service.handleAudioData(packet)
        service.sendPTT(active: true)
        for _ in 0..<100 {
            if service.session?.isPTTActive == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.session?.isPTTActive, false)
        XCTAssertEqual(service.audioStatusMessage, "Microphone input is unavailable.")
        XCTAssertTrue(service.canSendRemoteDTMF)
        await service.disconnect()
    }
#endif

    @MainActor
    func testRemotePadRequiresAudioFocusAndTransmitPermission() async throws {
        let service = EchoLinkConnectionService()
        service.session = QSOSession(
            station: Station(callsign: "N0CALL-L", ipAddress: "127.0.0.1", type: .link),
            state: .connected
        )
        var packet = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0CALL-L")
        let capability = try XCTUnwrap(packet.range(of: Data("D0".utf8)))
        packet.replaceSubrange(capability, with: Data("D1".utf8))
        await service.handleAudioData(packet)
        XCTAssertTrue(service.canSendRemoteDTMF)

        service.setBackgroundMuted(true)
        XCTAssertFalse(service.canSendRemoteDTMF)
        service.sendRemoteDTMF("1")
        XCTAssertFalse(service.isSendingDTMF)

        service.setBackgroundMuted(false)
        service.pttPermission = { false }
        XCTAssertFalse(service.canSendRemoteDTMF)
        service.sendRemoteDTMF("1")
        XCTAssertFalse(service.isSendingDTMF)
        await service.disconnect()
    }

    func testLegacyVoicePipelineRoundTripRemainsAudible() {
        let encoder = GSMCodec()
        let decoder = GSMCodec()

        // Two complete EchoLink packets of non-trivial waveform data (not silence).
        let input: [Int16] = (0..<(GSMCodec.samplesPerFrame * 8)).map { i in
            let phase = i % 64
            return Int16((phase - 32) * 900)
        }

        // Capture side: encode to BEEF-wrapped GSM.
        let encoded = encoder.encode(input)
        let encodedPayload = GSMCodec.stripHeader(encoded) ?? Data()
        XCTAssertEqual(encodedPayload.count, GSMCodec.encodedFrameSize * 8)

        // Network send side: packetize into EchoLink legacy RTP voice packets.
        var pending = encodedPayload
        let payloadPackets = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(
            buffer: &pending
        )
        XCTAssertEqual(payloadPackets.count, 2)
        XCTAssertTrue(payloadPackets.allSatisfy { $0.count == GSMCodec.encodedFrameSize * 4 })
        XCTAssertTrue(pending.isEmpty)

        var decodedAll: [Int16] = []
        var seq: UInt16 = 1
        for payload in payloadPackets {
            let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                gsmPayload: payload,
                sequence: seq
            )
            seq &+= 1

            // Receive side: parse packet then decode GSM payload.
            guard case .gsm(let parsedPayload)? = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet) else {
                return XCTFail("Expected parsed GSM payload from legacy voice packet")
            }
            decodedAll.append(contentsOf: decoder.decodePacket(parsedPayload))
        }

        XCTAssertEqual(decodedAll.count, GSMCodec.samplesPerFrame * 8)
        XCTAssertTrue(decodedAll.contains(where: { abs(Int($0)) > 100 }))
    }
}

@MainActor
final class QSOViewModelTests: XCTestCase {
    func testRemotePadRequiresD1AndLinkOrRepeater() async {
        let service = EchoLinkConnectionService()
        let link = Station(callsign: "N0CALL-L", ipAddress: "192.0.2.10", type: .link)
        service.session = QSOSession(station: link, state: .connected)

        var enabledPacket = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "W6ABC-L")
        guard let capabilityRange = enabledPacket.range(of: Data("D0".utf8)) else {
            return XCTFail("SDES fixture did not contain D0")
        }
        enabledPacket.replaceSubrange(capabilityRange, with: Data("D1".utf8))
        await service.handleAudioData(enabledPacket)
        XCTAssertTrue(service.remotePadAllowed)
        XCTAssertTrue(service.canSendRemoteDTMF)

        service.session = QSOSession(station: Station(callsign: "*TEST*", ipAddress: "192.0.2.10", type: .conference), state: .connected)
        XCTAssertFalse(service.canSendRemoteDTMF)
        service.session = QSOSession(station: Station(callsign: "W6ABC", ipAddress: "192.0.2.10", type: .user), state: .connected)
        XCTAssertFalse(service.canSendRemoteDTMF)

        service.session = QSOSession(station: link, state: .connected)
        await service.handleAudioData(EchoLinkControlPacketCodec.buildSDESPacket(callsign: "W6ABC-L"))
        XCTAssertFalse(service.remotePadAllowed)
        XCTAssertFalse(service.canSendRemoteDTMF)
    }

    func testUnexpectedFailureOffersReconnectAndUserDisconnectClearsIt() async {
        let service = EchoLinkConnectionService()
        let station = Station(callsign: "N0CALL", ipAddress: "192.0.2.10", nodeNumber: 123)

        service.registerReconnectCandidate(station)
        XCTAssertEqual(service.reconnectCandidate, station)

        await service.disconnect()
        XCTAssertNil(service.reconnectCandidate)
    }

    func testReconnectPerformsFreshLookupAndKeepsUsefulUnavailableError() async {
        let service = EchoLinkConnectionService()
        let saved = Station(callsign: "N0CALL", ipAddress: "192.0.2.10", nodeNumber: 123)
        var resolvedCandidates: [Station] = []
        service.resolveReconnectStation = { station in
            resolvedCandidates.append(station)
            return nil
        }
        service.registerReconnectCandidate(saved)

        await service.reconnect()

        XCTAssertEqual(resolvedCandidates, [saved])
        XCTAssertEqual(service.reconnectCandidate, saved)
        XCTAssertTrue(service.error?.localizedDescription.contains("not available") == true)
        XCTAssertNil(service.session)
    }

    func testReconnectDoesNotResolveWhileAnotherSessionIsActive() async {
        let service = EchoLinkConnectionService()
        let saved = Station(callsign: "N0CALL", ipAddress: "192.0.2.10", nodeNumber: 123)
        var didResolve = false
        service.resolveReconnectStation = { station in
            didResolve = true
            return station
        }
        service.registerReconnectCandidate(saved)
        service.session = QSOSession(station: saved, state: .connected)

        await service.reconnect()

        XCTAssertFalse(didResolve)
        XCTAssertEqual(service.error?.localizedDescription, ConnectionError.alreadyConnected.localizedDescription)
    }

    func testReconnectRetiresDisconnectedPresentationSessionBeforeFreshLookup() async {
        let service = EchoLinkConnectionService()
        let saved = Station(callsign: "N0CALL", ipAddress: "192.0.2.10", nodeNumber: 123)
        var didResolve = false
        service.resolveReconnectStation = { _ in
            didResolve = true
            return nil
        }
        service.registerReconnectCandidate(saved)
        service.session = QSOSession(station: saved, state: .disconnected)

        let viewModel = QSOViewModel(connectionService: service)
        await Task.yield()
        XCTAssertTrue(viewModel.canReconnect)

        await service.reconnect()

        XCTAssertTrue(didResolve)
        XCTAssertNil(service.session)
        XCTAssertEqual(service.reconnectCandidate, saved)
    }

    func testReconnectLookupRemainsCancellableAfterPresentationSessionIsCleared() async {
        let service = EchoLinkConnectionService()
        let saved = Station(callsign: "N0CALL", ipAddress: "192.0.2.10", nodeNumber: 123)
        var finishLookup: (() -> Void)?
        let lookupStarted = expectation(description: "reconnect lookup started")
        service.resolveReconnectStation = { _ in
            await withCheckedContinuation { continuation in
                finishLookup = {
                    continuation.resume(returning: saved)
                }
                lookupStarted.fulfill()
            }
        }
        service.registerReconnectCandidate(saved)
        let viewModel = QSOViewModel(connectionService: service)

        let reconnectCancelled = expectation(description: "reconnect candidate cleared")
        var cancellationObservation: AnyCancellable?
        cancellationObservation = service.$reconnectCandidate.dropFirst().sink { candidate in
            if candidate == nil {
                reconnectCancelled.fulfill()
                cancellationObservation?.cancel()
            }
        }
        let reconnectTask = Task { await service.reconnect() }
        await fulfillment(of: [lookupStarted], timeout: 1)
        XCTAssertTrue(service.isReconnecting)
        XCTAssertTrue(viewModel.canCancelConnection)

        viewModel.cancelConnection()
        await fulfillment(of: [reconnectCancelled], timeout: 1)
        finishLookup?()
        await reconnectTask.value
        XCTAssertFalse(viewModel.canCancelConnection)
        XCTAssertFalse(service.isReconnecting)
        XCTAssertNil(service.session)
        XCTAssertNil(service.reconnectCandidate)
    }

    func testReconnectAllowsOnlyOneFreshLookupAtATime() async {
        let service = EchoLinkConnectionService()
        let saved = Station(callsign: "N0CALL", ipAddress: "192.0.2.10", nodeNumber: 123)
        var lookupCount = 0
        service.resolveReconnectStation = { _ in
            lookupCount += 1
            await service.reconnect()
            return nil
        }
        service.registerReconnectCandidate(saved)

        await service.reconnect()

        XCTAssertEqual(lookupCount, 1)
        XCTAssertFalse(service.isReconnecting)
        XCTAssertEqual(service.reconnectCandidate, saved)
    }

    func testUserDisconnectDuringFreshLookupCancelsReconnect() async {
        let service = EchoLinkConnectionService()
        let saved = Station(callsign: "N0CALL", ipAddress: "192.0.2.10", nodeNumber: 123)
        service.resolveReconnectStation = { station in
            await service.disconnect()
            return station
        }
        service.registerReconnectCandidate(saved)

        await service.reconnect()

        XCTAssertNil(service.session)
        XCTAssertNil(service.reconnectCandidate)
        XCTAssertFalse(service.isReconnecting)
    }

    func testAuthenticatedCallsignTakesPrecedenceForHandshakeIdentity() {
        let service = EchoLinkConnectionService()
        service.authenticatedCallsign = "N0TEST"

        XCTAssertEqual(service.localCallsign, "N0TEST")
    }

    func testPTTStateFollowsConnectionServiceSession() async {
        let service = EchoLinkConnectionService()
        let viewModel = QSOViewModel(connectionService: service)
        let station = Station(callsign: "N0CALL", ipAddress: "127.0.0.1")

        service.session = QSOSession(
            station: station,
            state: .connected,
            isPTTActive: true
        )
        await drainMainQueue()
        XCTAssertTrue(viewModel.isPTTActive)

        service.session?.isPTTActive = false
        await drainMainQueue()
        XCTAssertFalse(viewModel.isPTTActive)
    }

    func testStationActivityIndicatorTracksIncomingMessagesAcrossSessionReset() async {
        let service = EchoLinkConnectionService()
        let viewModel = QSOViewModel(connectionService: service)

        service.incomingChatMessages = [
            ChatMessage(sender: "LOCAL", body: "hello", isOutgoing: true)
        ]
        await drainMainQueue()
        XCTAssertFalse(viewModel.hasIncomingMessages)

        service.incomingChatMessages.append(
            ChatMessage(sender: "REMOTE", body: "station details", isOutgoing: false)
        )
        await drainMainQueue()
        XCTAssertTrue(viewModel.hasIncomingMessages)

        service.incomingChatMessages = []
        await drainMainQueue()
        XCTAssertFalse(viewModel.hasIncomingMessages)
    }

    private func drainMainQueue() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}
