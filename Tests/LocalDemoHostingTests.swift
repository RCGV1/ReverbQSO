// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class LocalDemoHostingTests: XCTestCase {
    func testPersonalDemoReceivesAcceptsChatsAndDisconnectsWithoutDirectoryAvailability() async throws {
        var refreshCount = 0
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: {
            refreshCount += 1
            XCTFail("Local demo hosting must not refresh the real directory")
            return []
        })
        let outbound = EchoLinkConnectionService()
        XCTAssertTrue(outbound.enableLocalDemo(callsign: LocalDemoAccount.username))
        let host = EchoLinkConferenceHostService()

        await host.startPersonal(
            callsign: outbound.localCallsign,
            directory: directory,
            outbound: outbound,
            ports: .init(audio: 0, control: 0),
            monitorAudio: false
        )

        XCTAssertTrue(host.isRunning)
        XCTAssertTrue(host.isPersonalMode)
        XCTAssertEqual(host.maximumPeers, 1)
        XCTAssertNil(host.errorMessage)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(directory.isAvailableForCalls)

        try await waitUntil { host.pendingCall != nil }
        let caller = try XCTUnwrap(host.pendingCall)
        XCTAssertEqual(caller.callsign, "N1DEMO")
        XCTAssertTrue(host.sessions.isEmpty)

        await host.acceptPendingCall()
        XCTAssertNil(host.pendingCall)
        XCTAssertEqual(host.sessions.map(\.callsign), ["N1DEMO"])
        XCTAssertTrue(host.messages.contains { !$0.isOutgoing })

        let didSendPersonalChat = await host.sendChat("Hello from App Review")
        XCTAssertTrue(didSendPersonalChat)
        XCTAssertTrue(host.messages.contains {
            $0.isOutgoing && $0.sender == LocalDemoAccount.username && $0.body == "Hello from App Review"
        })

        await host.disconnect(id: caller.id)
        XCTAssertTrue(host.sessions.isEmpty)
        XCTAssertTrue(host.isRunning)
        XCTAssertFalse(directory.isAvailableForCalls)

        await host.stop()
        XCTAssertFalse(host.isRunning)
        XCTAssertNil(host.pendingCall)
        XCTAssertTrue(host.sessions.isEmpty)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(directory.isAvailableForCalls)
    }

    func testConferenceDemoAdmitsPeerAndUsesNormalChatAPIWithoutNetwork() async throws {
        var refreshCount = 0
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: {
            refreshCount += 1
            XCTFail("Local demo conference must not refresh the real directory")
            return []
        })
        let outbound = EchoLinkConnectionService()
        XCTAssertTrue(outbound.enableLocalDemo(callsign: LocalDemoAccount.secondUsername))
        let host = EchoLinkConferenceHostService()

        await host.start(
            callsign: outbound.localCallsign,
            directory: directory,
            outbound: outbound,
            policy: InboundHostPolicy(maximumPeers: 3),
            ports: .init(audio: 0, control: 0),
            monitorAudio: false
        )

        XCTAssertTrue(host.isRunning)
        XCTAssertFalse(host.isPersonalMode)
        XCTAssertEqual(host.maximumPeers, 3)
        try await waitUntil { !host.sessions.isEmpty }
        XCTAssertEqual(host.sessions.first?.callsign, "N1DEMO")
        XCTAssertTrue(host.messages.contains { !$0.isOutgoing })
        let didSendConferenceChat = await host.sendChat("Conference check")
        XCTAssertTrue(didSendConferenceChat)
        XCTAssertTrue(host.messages.contains {
            $0.isOutgoing && $0.sender == LocalDemoAccount.secondUsername && $0.body == "Conference check"
        })
        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(directory.isAvailableForCalls)

        await host.stop()
        XCTAssertFalse(host.isRunning)
    }

    func testStoppingDemoBeforeIncomingCallCancelsItsGeneration() async throws {
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: {
            XCTFail("Stopped local demo must not refresh the real directory")
            return []
        })
        let outbound = EchoLinkConnectionService()
        XCTAssertTrue(outbound.enableLocalDemo(callsign: LocalDemoAccount.username))
        let host = EchoLinkConferenceHostService()

        await host.startPersonal(
            callsign: outbound.localCallsign,
            directory: directory,
            outbound: outbound,
            ports: .init(audio: 0, control: 0),
            monitorAudio: false
        )
        XCTAssertTrue(host.isRunning)
        await host.stop()
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(host.isRunning)
        XCTAssertNil(host.pendingCall)
        XCTAssertTrue(host.sessions.isEmpty)
        XCTAssertFalse(directory.isAvailableForCalls)
    }

    func testPersonalDemoPendingCallCanBeDeclined() async throws {
        let directory = EchoLinkDirectoryService(fetchStationsForRefresh: {
            XCTFail("Local demo decline must not refresh the real directory")
            return []
        })
        let outbound = EchoLinkConnectionService()
        XCTAssertTrue(outbound.enableLocalDemo(callsign: LocalDemoAccount.username))
        let host = EchoLinkConferenceHostService()

        await host.startPersonal(
            callsign: outbound.localCallsign,
            directory: directory,
            outbound: outbound,
            ports: .init(audio: 0, control: 0),
            monitorAudio: false
        )
        try await waitUntil { host.pendingCall != nil }

        await host.declinePendingCall()

        XCTAssertNil(host.pendingCall)
        XCTAssertTrue(host.sessions.isEmpty)
        XCTAssertTrue(host.isRunning)
        XCTAssertFalse(directory.isAvailableForCalls)
        await host.stop()
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for local demo host state")
    }
}
