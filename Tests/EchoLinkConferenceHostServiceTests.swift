// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

@MainActor
final class EchoLinkConferenceHostServiceTests: XCTestCase {
    private enum TestTimeout: Error { case expired }

    func testGlobalCallRestrictionRejectsVerifiedCallerBeforeRinging() async throws {
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: {
            [Station(callsign: "N0AAA", ipAddress: "127.0.0.1")]
        })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService()
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

    func testReleasedPTTDuringInputPreparationDoesNotReportStaleFailure() async throws {
        let preparing = expectation(description: "host preparing microphone")
        var finishPreparation: CheckedContinuation<Bool, Never>?
        let host = EchoLinkConferenceHostService(prepareCaptureInput: {
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

    func testPersonalCallRingsUntilAcceptedAndRejectsAnotherCaller() async throws {
        let stations = [
            Station(callsign: "N0AAA", ipAddress: "127.0.0.1"),
            Station(callsign: "K1BBB", ipAddress: "127.0.0.1")
        ]
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: { stations })
        directory.isLoggedIn = true
        let host = EchoLinkConferenceHostService()
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
        let host = EchoLinkConferenceHostService()
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
        let host = EchoLinkConferenceHostService()
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
        let host = EchoLinkConferenceHostService()
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
        let host = EchoLinkConferenceHostService()

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
}
