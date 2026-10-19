// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

@MainActor
final class EchoLinkConferenceHostServiceTests: XCTestCase {
    private enum TestTimeout: Error { case expired }

    private static func directConfiguration() -> EchoLinkProxyConfiguration {
        EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "")
    }

    func testGlobalCallRestrictionRejectsVerifiedCallerBeforeRinging() async throws {
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: {
            [Station(callsign: "N0AAA", ipAddress: "127.0.0.1")]
        })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService(configurationProvider: Self.directConfiguration)
        host.callAccessPolicyProvider = {
            var policy = CallAccessPolicy()
            policy.blockedCountries = ["US"]
            return policy
        }
        let controlPort = try availablePort()
        await host.startPersonal(callsign: "W6HOST", directory: directory, outbound: EchoLinkConnectionService(),
                                 ports: .init(audio: try availablePort(), control: controlPort), monitorAudio: false)
        guard host.isRunning else { return XCTFail(host.errorMessage ?? "Could not listen") }
        defer { Task { await host.stop() } }
        let caller = try BoundUDPSocket(localPort: 0)
        defer { caller.close() }
        try await caller.send(EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0AAA"), to: "127.0.0.1", port: controlPort)
        let response = try await receive(caller)
        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: response.data).contains {
            if case .bye = $0 { return true }; return false
        })
        XCTAssertNil(host.pendingCall)
        XCTAssertTrue(host.sessions.isEmpty)
    }

    func testPersonalAnswerRechecksRestrictionChangedWhileCallerWasRinging() async throws {
        let station = Station(callsign: "N0AAA", ipAddress: "127.0.0.1")
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [station] })
        directory.isLoggedIn = true
        var policy = CallAccessPolicy()
        let host = EchoLinkConferenceHostService(configurationProvider: Self.directConfiguration)
        host.callAccessPolicyProvider = { policy }
        let controlPort = try availablePort()
        await host.startPersonal(callsign: "W6HOST", directory: directory, outbound: EchoLinkConnectionService(),
                                 ports: .init(audio: try availablePort(), control: controlPort), monitorAudio: false)
        guard host.isRunning else { return XCTFail(host.errorMessage ?? "Could not listen") }
        defer { Task { await host.stop() } }
        let caller = try BoundUDPSocket(localPort: 0)
        defer { caller.close() }
        try await caller.send(EchoLinkControlPacketCodec.buildSDESPacket(callsign: station.callsign),
                              to: "127.0.0.1", port: controlPort)
        try await waitUntil { host.pendingCall != nil }

        policy.blockedCallsigns = [station.callsign]
        await host.acceptPendingCall()

        let response = try await receive(caller)
        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: response.data).contains {
            if case .bye(let reason) = $0 { return reason?.contains("blocked") == true }; return false
        }, "Answer must apply the current incoming restrictions")
        XCTAssertNil(host.pendingCall)
        XCTAssertTrue(host.sessions.isEmpty)
        XCTAssertTrue(directory.isAvailableForCalls)
    }

    func testReleasedPTTDuringInputPreparationDoesNotReportStaleFailure() async throws {
        let preparing = expectation(description: "host preparing microphone")
        var finishPreparation: CheckedContinuation<Bool, Never>?
        let host = EchoLinkConferenceHostService(configurationProvider: Self.directConfiguration, prepareCaptureInput: {
            preparing.fulfill()
            return await withCheckedContinuation { finishPreparation = $0 }
        })
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [] })
        directory.isLoggedIn = true
        await host.start(
            callsign: "W6HOST", directory: directory, outbound: EchoLinkConnectionService(),
            policy: .init(maximumPeers: 2),
            ports: .init(audio: try availablePort(), control: try availablePort()), monitorAudio: false
        )
        guard host.isRunning else { return XCTFail(host.errorMessage ?? "Host failed to start") }
        host.setPTT(active: true)
        await fulfillment(of: [preparing], timeout: 2)
        host.setPTT(active: false)
        try await waitUntil { !host.isTransmitting }
        finishPreparation?.resume(returning: false)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNil(host.errorMessage)
        XCTAssertNil(host.talkerCallsign)
        XCTAssertFalse(host.isTransmitting)
        await host.stop()
    }

    func testDisconnectingLastPersonalPeerReleasesPTTDuringInputPreparation() async throws {
        let preparing = expectation(description: "host preparing microphone")
        var finishPreparation: CheckedContinuation<Bool, Never>?
        let host = EchoLinkConferenceHostService(prepareCaptureInput: {
            preparing.fulfill()
            return await withCheckedContinuation { finishPreparation = $0 }
        })
        host.installSimulatorDemoIncomingCall()
        await host.acceptPendingCall()
        let caller = try XCTUnwrap(host.sessions.first)
        host.setPTT(active: true)
        await fulfillment(of: [preparing], timeout: 2)

        await host.disconnect(id: caller.id)
        for _ in 0..<20 { await Task.yield() }
        let wasStillTransmitting = host.isTransmitting
        let staleTalker = host.talkerCallsign
        // Complete the injected preparation so the test leaves no suspended task.
        finishPreparation?.resume(returning: false)
        await host.stop()

        XCTAssertFalse(wasStillTransmitting, "A finished personal QSO must release microphone preparation and PTT")
        XCTAssertNil(staleTalker)
    }

    func testLocalPTTSendsSpeexOnlyToCapablePeerAndFlushesOneShortPacket() async throws {
        let audioEngine = AudioEngine()
        let stations = [
            Station(callsign: "N0SPX", ipAddress: "127.0.0.1"),
            Station(callsign: "N0GSM", ipAddress: "127.0.0.1")
        ]
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { stations })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService(
            configurationProvider: Self.directConfiguration,
            audioEngine: audioEngine,
            prepareCaptureInput: {
                try? await Task.sleep(for: .seconds(60))
                return false
            }
        )
        let audioPort = try availablePort()
        let controlPort = try availablePort()
        await host.start(
            callsign: "W6HOST", directory: directory, outbound: EchoLinkConnectionService(),
            policy: .init(maximumPeers: 2),
            ports: .init(audio: audioPort, control: controlPort), monitorAudio: false
        )
        guard host.isRunning else { return XCTFail(host.errorMessage ?? "Host failed to start") }
        defer { Task { await host.stop() } }

        let speexAudio = try BoundUDPSocket(localPort: 0)
        let speexControl = try BoundUDPSocket(localPort: 0)
        let gsmAudio = try BoundUDPSocket(localPort: 0)
        let gsmControl = try BoundUDPSocket(localPort: 0)
        defer {
            speexAudio.close(); speexControl.close()
            gsmAudio.close(); gsmControl.close()
        }
        try await joinPeer(
            callsign: "N0SPX", audio: speexAudio, control: speexControl,
            hostControlPort: controlPort, advertiseSpeex: true
        )
        try await joinPeer(
            callsign: "N0GSM", audio: gsmAudio, control: gsmControl,
            hostControlPort: controlPort, advertiseSpeex: false
        )
        try await waitUntil { host.sessions.count == 2 }

        let forwardedPCM = (0..<640).map { Int16(($0 % 32) * 300 - 4_800) }
        let forwardedPayload = try XCTUnwrap(GSMCodec.stripHeader(GSMCodec().encode(forwardedPCM)))
        try await gsmAudio.send(
            EchoLinkAudioPacketCodec.buildLegacyVoicePacket(gsmPayload: forwardedPayload, sequence: 77),
            to: "127.0.0.1", port: audioPort
        )
        let forwarded = try await receiveVoice(speexAudio, payloadType: 3)
        XCTAssertEqual(Data(forwarded.data[2...3]), Data([0, 0]))
        XCTAssertEqual(Data(forwarded.data[4...7]), Data([0, 0, 0, 0]))
        try await waitUntil { host.talkerCallsign == nil }

        host.setPTT(active: true)
        let samples = (0..<700).map { Int16(($0 % 80) * 200 - 8_000) }
        audioEngine.encodeTransmitPCM(samples)
        host.setPTT(active: false)

        let firstSpeex = try await receiveVoice(speexAudio, payloadType: 0x96)
        let finalSpeex = try await receiveVoice(speexAudio, payloadType: 0x96)
        let gsm = try await receiveVoice(gsmAudio, payloadType: 3)
        XCTAssertEqual(Data(firstSpeex.data[2...3]), Data([0, 1]))
        XCTAssertEqual(Data(firstSpeex.data[4...7]), Data([0, 0, 2, 128]))
        XCTAssertEqual(Data(finalSpeex.data[2...3]), Data([0, 2]))
        XCTAssertEqual(Data(finalSpeex.data[4...7]), Data([0, 0, 5, 0]))
        XCTAssertEqual(Data(gsm.data[4...7]), Data([0, 0, 0, 0]))
        guard case .gsm(let gsmPayload) = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(gsm.data) else {
            return XCTFail("Expected GSM packet")
        }
        XCTAssertEqual(gsmPayload.count, GSMCodec.encodedFrameSize * 4)
        let speexDecoder = SpeexCodec()
        XCTAssertEqual(speexDecoder.decodePacket(Data(firstSpeex.data.dropFirst(12)))?.count, 640)
        XCTAssertEqual(speexDecoder.decodePacket(Data(finalSpeex.data.dropFirst(12)))?.count, 640)
        try await waitUntil { !host.isTransmitting }

        host.setPTT(active: true)
        let exactPacket = Array(samples.prefix(640))
        audioEngine.encodeTransmitPCM(exactPacket)
        let onlySpeex = try await receiveVoice(speexAudio, payloadType: 0x96)
        XCTAssertEqual(Data(onlySpeex.data[2...3]), Data([0, 3]))
        XCTAssertEqual(Data(onlySpeex.data[4...7]), Data([0, 0, 7, 128]))
        host.setPTT(active: false)
        try await waitUntil { !host.isTransmitting }
        let receivedExtraVoice = try await receivesVoice(speexAudio, within: .milliseconds(250))
        XCTAssertFalse(receivedExtraVoice, "An exact 640-sample burst must not flush an extra silent packet")
    }

    func testSpeexCapabilityUpdateTakesEffectOnNextPTTInsteadOfMidBurst() async throws {
        let audioEngine = AudioEngine()
        let station = Station(callsign: "N0PEER", ipAddress: "127.0.0.1")
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [station] })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService(
            configurationProvider: Self.directConfiguration,
            audioEngine: audioEngine,
            prepareCaptureInput: {
                try? await Task.sleep(for: .seconds(60))
                return false
            }
        )
        let audioPort = try availablePort()
        let controlPort = try availablePort()
        await host.start(
            callsign: "W6HOST", directory: directory, outbound: EchoLinkConnectionService(),
            policy: .init(maximumPeers: 2),
            ports: .init(audio: audioPort, control: controlPort), monitorAudio: false
        )
        guard host.isRunning else { return XCTFail(host.errorMessage ?? "Host failed to start") }
        defer { Task { await host.stop() } }

        let peerAudio = try BoundUDPSocket(localPort: 0)
        let peerControl = try BoundUDPSocket(localPort: 0)
        defer { peerAudio.close(); peerControl.close() }
        try await joinPeer(
            callsign: "N0PEER", audio: peerAudio, control: peerControl,
            hostControlPort: controlPort, advertiseSpeex: false
        )
        try await waitUntil { host.sessions.count == 1 }

        let samples = (0..<640).map { Int16(($0 % 64) * 250 - 8_000) }
        host.setPTT(active: true)
        try await peerControl.send(
            EchoLinkControlPacketCodec.buildSDESPacket(
                callsign: "N0PEER", audioPort: peerAudio.actualLocalPort, advertiseSpeex: true
            ),
            to: "127.0.0.1", port: controlPort
        )
        try await Task.sleep(for: .milliseconds(50))
        audioEngine.encodeTransmitPCM(samples)
        let firstBurst = try await receiveVoice(peerAudio, payloadType: 3)
        XCTAssertEqual(firstBurst.data[1], 3)
        host.setPTT(active: false)
        try await waitUntil { !host.isTransmitting }

        host.setPTT(active: true)
        audioEngine.encodeTransmitPCM(samples)
        let nextBurst = try await receiveVoice(peerAudio, payloadType: 0x96)
        XCTAssertEqual(nextBurst.data[1], 0x96)
        host.setPTT(active: false)
        try await waitUntil { !host.isTransmitting }
    }

    func testPersonalIncomingCallRetainsSpeexCapabilityAfterAnswer() async throws {
        let audioEngine = AudioEngine()
        let station = Station(callsign: "N0CALL", ipAddress: "127.0.0.1")
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [station] })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService(
            configurationProvider: Self.directConfiguration,
            audioEngine: audioEngine,
            prepareCaptureInput: {
                try? await Task.sleep(for: .seconds(60))
                return false
            }
        )
        let audioPort = try availablePort()
        let controlPort = try availablePort()
        await host.startPersonal(
            callsign: "W6HOST", directory: directory, outbound: EchoLinkConnectionService(),
            ports: .init(audio: audioPort, control: controlPort), monitorAudio: false
        )
        guard host.isRunning else { return XCTFail(host.errorMessage ?? "Personal host failed to start") }
        defer { Task { await host.stop() } }

        let peerAudio = try BoundUDPSocket(localPort: 0)
        let peerControl = try BoundUDPSocket(localPort: 0)
        defer { peerAudio.close(); peerControl.close() }
        try await peerControl.send(
            EchoLinkControlPacketCodec.buildSDESPacket(
                callsign: "N0CALL", audioPort: peerAudio.actualLocalPort, advertiseSpeex: true
            ),
            to: "127.0.0.1", port: controlPort
        )
        try await waitUntil { host.pendingCall?.callsign == "N0CALL" }
        await host.acceptPendingCall()
        let acknowledgement = try await receive(peerControl)
        let acknowledgementInfo = try XCTUnwrap(
            EchoLinkControlPacketCodec.parseEvents(from: acknowledgement.data).compactMap { event in
                if case .sdes(let info) = event { return info }
                return nil
            }.first
        )
        XCTAssertTrue(acknowledgementInfo.supportsSpeex)
        try await waitUntil { host.sessions.count == 1 }

        let samples = (0..<640).map { Int16(($0 % 40) * 300 - 6_000) }
        host.setPTT(active: true)
        audioEngine.encodeTransmitPCM(samples)
        let voice = try await receiveVoice(peerAudio, payloadType: 0x96)
        XCTAssertEqual(voice.data[1], 0x96)
        host.setPTT(active: false)
        try await waitUntil { !host.isTransmitting }
    }

    func testPersonalCallRingsUntilAcceptedAndRejectsAnotherCaller() async throws {
        let stations = [
            Station(callsign: "N0AAA", ipAddress: "127.0.0.1"),
            Station(callsign: "K1BBB", ipAddress: "127.0.0.1")
        ]
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { stations })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService(configurationProvider: Self.directConfiguration)
        let audioPort = try availablePort()
        let controlPort = try availablePort()
        await host.startPersonal(
            callsign: "W6HOST", directory: directory, outbound: EchoLinkConnectionService(),
            ports: .init(audio: audioPort, control: controlPort), monitorAudio: false
        )
        guard host.isRunning else { return XCTFail(host.errorMessage ?? "Personal host failed to start") }
        defer { Task { await host.stop() } }

        let caller = try BoundUDPSocket(localPort: 0)
        let second = try BoundUDPSocket(localPort: 0)
        defer { caller.close(); second.close() }
        try await caller.send(EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0AAA"),
                              to: "127.0.0.1", port: controlPort)
        try await waitUntil { host.pendingCall?.callsign == "N0AAA" }
        XCTAssertTrue(host.sessions.isEmpty)

        try await second.send(EchoLinkControlPacketCodec.buildSDESPacket(callsign: "K1BBB"),
                              to: "127.0.0.1", port: controlPort)
        let busy = try await receive(second)
        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: busy.data).contains {
            if case .bye = $0 { return true }; return false
        })
        XCTAssertEqual(host.pendingCall?.callsign, "N0AAA")

        await host.acceptPendingCall()
        let accepted = try await receive(caller)
        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: accepted.data).contains {
            if case .sdes = $0 { return true }; return false
        })
        XCTAssertNil(host.pendingCall)
        XCTAssertEqual(host.sessions.map(\.callsign), ["N0AAA"])
    }

    func testPersonalCallCanBeDeclinedAndAnotherCallerCanRing() async throws {
        let stations = [
            Station(callsign: "N0AAA", ipAddress: "127.0.0.1"),
            Station(callsign: "K1BBB", ipAddress: "127.0.0.1")
        ]
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { stations })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService(configurationProvider: Self.directConfiguration)
        let audioPort = try availablePort()
        let controlPort = try availablePort()
        await host.startPersonal(
            callsign: "W6HOST", directory: directory, outbound: EchoLinkConnectionService(),
            ports: .init(audio: audioPort, control: controlPort), monitorAudio: false
        )
        guard host.isRunning else { return XCTFail(host.errorMessage ?? "Personal host failed to start") }
        defer { Task { await host.stop() } }

        let caller = try BoundUDPSocket(localPort: 0)
        let next = try BoundUDPSocket(localPort: 0)
        defer { caller.close(); next.close() }
        try await caller.send(EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0AAA"),
                              to: "127.0.0.1", port: controlPort)
        try await waitUntil { host.pendingCall?.callsign == "N0AAA" }
        await host.declinePendingCall()
        let declined = try await receive(caller)
        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: declined.data).contains {
            if case .bye(let reason) = $0 { return reason == "Declined" }; return false
        })
        XCTAssertNil(host.pendingCall)
        try await next.send(EchoLinkControlPacketCodec.buildSDESPacket(callsign: "K1BBB"),
                            to: "127.0.0.1", port: controlPort)
        try await waitUntil { host.pendingCall?.callsign == "K1BBB" }
    }

    func testPersonalCallExpiresBeforeLateAnswer() async throws {
        let station = Station(callsign: "N0AAA", ipAddress: "127.0.0.1")
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [station] })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService(configurationProvider: Self.directConfiguration)
        let audioPort = try availablePort()
        let controlPort = try availablePort()
        await host.startPersonal(callsign: "W6HOST", directory: directory,
                                 outbound: EchoLinkConnectionService(),
                                 ports: .init(audio: audioPort, control: controlPort), monitorAudio: false)
        guard host.isRunning else { return XCTFail(host.errorMessage ?? "Personal host failed to start") }
        defer { Task { await host.stop() } }
        let caller = try BoundUDPSocket(localPort: 0)
        defer { caller.close() }
        try await caller.send(EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0AAA"),
                              to: "127.0.0.1", port: controlPort)
        try await waitUntil { host.pendingCall != nil }
        let deadline = try XCTUnwrap(host.pendingCall?.admittedAt).addingTimeInterval(10)
        await host.expirePendingCalls(now: deadline)
        let response = try await receive(caller)
        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: response.data).contains {
            if case .bye(let reason) = $0 { return reason == "No answer" }; return false
        })
        await host.acceptPendingCall()
        XCTAssertNil(host.pendingCall)
        XCTAssertTrue(host.sessions.isEmpty)
        XCTAssertTrue(directory.isAvailableForCalls)
    }

    func testPersonalCallRejectsRepeaterIdentity() async throws {
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { [] })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService(configurationProvider: Self.directConfiguration)
        await host.startPersonal(callsign: "W6HOST-R", directory: directory,
                                 outbound: EchoLinkConnectionService(), monitorAudio: false)
        XCTAssertFalse(host.isRunning)
        XCTAssertTrue(host.errorMessage?.contains("personal callsign") == true)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestTimeout.expired
    }

    func testTwoLocalPeersJoinAndReceiveVoiceAndChat() async throws {
        let stations = [
            Station(callsign: "N0AAA", ipAddress: "127.0.0.1"),
            Station(callsign: "K1BBB", ipAddress: "127.0.0.1")
        ]
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { stations })
        directory.isLoggedIn = true
        let outbound = EchoLinkConnectionService()
        let host = EchoLinkConferenceHostService(configurationProvider: Self.directConfiguration)

        let audioPort = try availablePort()
        let controlPort = try availablePort()
        XCTAssertNotEqual(audioPort, controlPort)
        await host.start(
            callsign: "W6HOST",
            directory: directory,
            outbound: outbound,
            policy: InboundHostPolicy(maximumPeers: 2),
            ports: .init(audio: audioPort, control: controlPort),
            monitorAudio: false
        )
        guard host.isRunning else {
            return XCTFail(host.errorMessage ?? "Host failed to start")
        }
        XCTAssertTrue(directory.isAvailableForCalls)
        defer { Task { await host.stop() } }
        outbound.isConferenceHostActive = { host.isRunning || host.isStarting }
        await outbound.connect(to: stations[0])
        XCTAssertNil(outbound.session)
        XCTAssertTrue(outbound.error?.localizedDescription.contains("Stop conference hosting") == true)

        let firstAudio = try BoundUDPSocket(localPort: 0)
        let firstControl = try BoundUDPSocket(localPort: 0)
        let secondAudio = try BoundUDPSocket(localPort: 0)
        let secondControl = try BoundUDPSocket(localPort: 0)
        defer {
            firstAudio.close()
            firstControl.close()
            secondAudio.close()
            secondControl.close()
        }

        try await firstControl.send(
            EchoLinkControlPacketCodec.buildSDESPacket(callsign: "N0AAA", audioPort: firstAudio.actualLocalPort),
            to: "127.0.0.1", port: controlPort
        )
        let firstReply = try await receive(firstControl)
        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: firstReply.data).contains {
            if case .sdes = $0 { return true }
            return false
        })

        try await secondControl.send(
            EchoLinkControlPacketCodec.buildSDESPacket(callsign: "K1BBB", audioPort: secondAudio.actualLocalPort),
            to: "127.0.0.1", port: controlPort
        )
        let secondReply = try await receive(secondControl)
        XCTAssertTrue(EchoLinkControlPacketCodec.parseEvents(from: secondReply.data).contains {
            if case .sdes = $0 { return true }
            return false
        })
        XCTAssertEqual(host.sessions.map(\.callsign).sorted(), ["K1BBB", "N0AAA"])
        XCTAssertFalse(directory.isAvailableForCalls)

        try await firstAudio.send(
            EchoLinkControlPacketCodec.buildNDATAChatPacket(sender: "SPOOFED", message: "hello"),
            to: "127.0.0.1", port: audioPort
        )
        let forwardedChat = try await receiveUntil(secondAudio) { data in
            EchoLinkControlPacketCodec.parseEvents(from: data).contains {
                if case .chat(let sender, let body) = $0 { return sender == "N0AAA" && body == "hello" }
                return false
            }
        }
        XCTAssertFalse(forwardedChat.data.isEmpty)
        XCTAssertEqual(host.messages.last?.sender, "N0AAA")
        XCTAssertEqual(host.messages.last?.body, "hello")
        let chatSent = await host.sendChat("hello from host")
        XCTAssertTrue(chatSent)
        let hostChat = try await receiveUntil(secondAudio) { data in
            EchoLinkControlPacketCodec.parseEvents(from: data).contains {
                if case .chat(let sender, let body) = $0 {
                    return sender == "W6HOST" && body == "hello from host"
                }
                return false
            }
        }
        XCTAssertFalse(hostChat.data.isEmpty)

        let encoded = GSMCodec().encode(Array(repeating: Int16(500), count: GSMCodec.samplesPerFrame * 4))
        let payload = try XCTUnwrap(GSMCodec.stripHeader(encoded))
        try await firstAudio.send(
            EchoLinkAudioPacketCodec.buildLegacyVoicePacket(gsmPayload: payload, sequence: 42),
            to: "127.0.0.1", port: audioPort
        )
        let forwardedVoice = try await receiveUntil(secondAudio) { data in
            if case .gsm = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(data) { return true }
            return false
        }
        XCTAssertEqual(forwardedVoice.data[2], 0)
        XCTAssertEqual(forwardedVoice.data[3], 0)
        XCTAssertEqual(host.talkerCallsign, "N0AAA")

        await host.stop()
        XCTAssertFalse(host.isRunning)
        XCTAssertFalse(directory.isAvailableForCalls)
        XCTAssertTrue(host.sessions.isEmpty)
    }

    func testShortG711PlaysImmediatelyAndForwardsOnlyAfterACompleteGSMFrame() async throws {
        let stations = [Station(callsign: "N0AAA", ipAddress: "127.0.0.1"),
                        Station(callsign: "K1BBB", ipAddress: "127.0.0.1")]
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { stations })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService(configurationProvider: Self.directConfiguration)
        let audioPort = try availablePort(), controlPort = try availablePort()
        await host.start(callsign: "W6HOST", directory: directory, outbound: EchoLinkConnectionService(),
                         policy: .init(maximumPeers: 2), ports: .init(audio: audioPort, control: controlPort),
                         monitorAudio: false)
        defer { Task { await host.stop() } }
        XCTAssertTrue(host.isRunning, host.errorMessage ?? "")
        let talkerAudio = try BoundUDPSocket(localPort: 0), talkerControl = try BoundUDPSocket(localPort: 0)
        let listenerAudio = try BoundUDPSocket(localPort: 0), listenerControl = try BoundUDPSocket(localPort: 0)
        defer { talkerAudio.close(); talkerControl.close(); listenerAudio.close(); listenerControl.close() }
        try await joinPeer(callsign: "N0AAA", audio: talkerAudio, control: talkerControl,
                           hostControlPort: controlPort, advertiseSpeex: false)
        try await joinPeer(callsign: "K1BBB", audio: listenerAudio, control: listenerControl,
                           hostControlPort: controlPort, advertiseSpeex: false)
        var receivedPCM: [[Int16]] = []
        host.onUnmonitoredReceivedPCM = { receivedPCM.append($0) }
        let voiceRead = Task { () throws -> BoundUDPSocket.Datagram in
            try await withThrowingTaskGroup(of: BoundUDPSocket.Datagram.self) { group in
                group.addTask {
                    while true {
                        let datagram = try await listenerAudio.receive(maximumBytes: 4_096)
                        if datagram.data.count >= 12, datagram.data[0] == 0xC0 { return datagram }
                    }
                }
                group.addTask { try await Task.sleep(for: .seconds(2)); throw TestTimeout.expired }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
        defer { voiceRead.cancel() }
        func packet(_ sequence: UInt8) -> Data {
            Data([0x80, 0, 0, sequence, 0, 0, 0, 0, 0, 0, 0, 1]) + Data(repeating: 0xFF, count: 80)
        }
        try await talkerAudio.send(packet(1), to: "127.0.0.1", port: audioPort)
        for _ in 0..<100 where receivedPCM.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(receivedPCM, [[Int16](repeating: 0, count: 80)],
                       "Play the received 10 ms immediately while the GSM frame is incomplete")
        try await talkerAudio.send(packet(2), to: "127.0.0.1", port: audioPort)
        let forwarded = try await voiceRead.value
        let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(forwarded.data))
        guard case .gsm(let payload) = parsed.packet else { return XCTFail("Expected GSM forwarding") }
        XCTAssertEqual(payload.count, 33, "Never send a header-only voice datagram for the first 80 samples")
        XCTAssertEqual(GSMCodec().decodePacket(payload).count, 160)
        XCTAssertEqual(parsed.metadata?.sequenceNumber, 0, "An empty encoder result must not advance output sequence")
        XCTAssertEqual(parsed.metadata?.timestamp, 0)
        XCTAssertEqual(receivedPCM.count, 2)
        await host.stop()
    }

    private func availablePort() throws -> UInt16 {
        let socket = try BoundUDPSocket(localPort: 0)
        let port = socket.actualLocalPort
        socket.close()
        return port
    }

    private func receive(_ socket: BoundUDPSocket) async throws -> BoundUDPSocket.Datagram {
        try await withThrowingTaskGroup(of: BoundUDPSocket.Datagram.self) { group in
            group.addTask { try await socket.receive(maximumBytes: 4_096) }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw TestTimeout.expired
            }
            let datagram = try await group.next()!
            group.cancelAll()
            return datagram
        }
    }

    private func receiveUntil(
        _ socket: BoundUDPSocket,
        matching predicate: (Data) -> Bool
    ) async throws -> BoundUDPSocket.Datagram {
        for _ in 0..<8 {
            let datagram = try await receive(socket)
            if predicate(datagram.data) { return datagram }
        }
        throw TestTimeout.expired
    }

    private func joinPeer(
        callsign: String,
        audio: BoundUDPSocket,
        control: BoundUDPSocket,
        hostControlPort: UInt16,
        advertiseSpeex: Bool
    ) async throws {
        try await control.send(
            EchoLinkControlPacketCodec.buildSDESPacket(
                callsign: callsign,
                audioPort: audio.actualLocalPort,
                advertiseSpeex: advertiseSpeex
            ),
            to: "127.0.0.1", port: hostControlPort
        )
        let acknowledgement = try await receive(control)
        let info = try XCTUnwrap(
            EchoLinkControlPacketCodec.parseEvents(from: acknowledgement.data).compactMap { event in
                if case .sdes(let info) = event { return info }
                return nil
            }.first
        )
        XCTAssertTrue(info.supportsSpeex)
    }

    private func receiveVoice(
        _ socket: BoundUDPSocket,
        payloadType: UInt8
    ) async throws -> BoundUDPSocket.Datagram {
        try await receiveUntil(socket) { data in
            data.count >= 12 && data[data.startIndex] == 0xC0 && data[data.startIndex + 1] == payloadType
        }
    }

    private func receivesVoice(
        _ socket: BoundUDPSocket,
        within duration: Duration
    ) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                let datagram = try await socket.receive(maximumBytes: 4_096)
                return EchoLinkAudioPacketCodec.parseIncomingAudioPacket(datagram.data) != nil
            }
            group.addTask {
                try await Task.sleep(for: duration)
                return false
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
