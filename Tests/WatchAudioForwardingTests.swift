// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
#if os(iOS) && !targetEnvironment(macCatalyst)
import WatchConnectivity
#endif
@testable import ReverbQSO

@MainActor
final class WatchAudioForwardingTests: XCTestCase {
#if os(iOS) && targetEnvironment(simulator)
    func testStaleWatchPTTStartCannotKeyReplacementPhoneSession() async {
        let app = AppState()
        let radio = app.connectionService
        _ = radio.enableLocalDemo(callsign: "DEMO")
        radio.session = QSOSession(station: LocalDemoAccount.stations[1], state: .connected)
        let bridge = WatchPhoneBridge(connectionService: radio, appState: app, activateSession: false)
        let reply = await sendWatchCommand([
            "command": "ptt", "active": true,
            "sessionID": UUID().uuidString, "holdID": UUID().uuidString
        ], to: bridge)

        XCTAssertEqual(reply, false)
        XCTAssertEqual(radio.session?.isPTTActive, false)
        await radio.disconnect()
    }

    func testStaleWatchDisconnectCannotEndReplacementPhoneSession() async {
        let app = AppState()
        let radio = app.connectionService
        _ = radio.enableLocalDemo(callsign: "DEMO")
        radio.session = QSOSession(station: LocalDemoAccount.stations[1], state: .connected)
        let currentID = radio.session?.id
        let bridge = WatchPhoneBridge(connectionService: radio, appState: app, activateSession: false)
        let reply = await sendWatchCommand([
            "command": "disconnect", "sessionID": UUID().uuidString
        ], to: bridge)

        XCTAssertEqual(reply, false)
        XCTAssertEqual(radio.session?.id, currentID)
        XCTAssertEqual(radio.session?.state, .connected)
        await radio.disconnect()
    }

    func testOldWatchReleaseCannotStopNewHoldOnSamePhoneSession() async throws {
        let app = AppState()
        let radio = app.connectionService
        _ = radio.enableLocalDemo(callsign: "DEMO")
        radio.session = QSOSession(station: LocalDemoAccount.stations[1], state: .connected)
        let sessionID = try XCTUnwrap(radio.session?.id).uuidString
        let bridge = WatchPhoneBridge(connectionService: radio, appState: app, activateSession: false)
        let oldHold = UUID().uuidString
        let newHold = UUID().uuidString
        _ = await sendWatchCommand(["command": "ptt", "active": true,
            "sessionID": sessionID, "holdID": oldHold], to: bridge)
        radio.session?.isPTTActive = false // A capture interruption ended the old turn.
        let start = await sendWatchCommand(["command": "ptt", "active": true,
            "sessionID": sessionID, "holdID": newHold], to: bridge)
        XCTAssertEqual(start, true)
        XCTAssertEqual(radio.session?.isPTTActive, true)

        _ = await sendWatchCommand(["command": "ptt", "active": false,
            "sessionID": sessionID, "holdID": oldHold], to: bridge)

        XCTAssertEqual(radio.session?.isPTTActive, true)
        await radio.disconnect()
    }

    private func sendWatchCommand(_ command: [String: Any], to bridge: WatchPhoneBridge) async -> Bool? {
        await withCheckedContinuation { continuation in
            bridge.session(WCSession.default, didReceiveMessage: command) { reply in
                continuation.resume(returning: reply["ok"] as? Bool)
            }
        }
    }
#endif
    func testWatchCredentialSyncDefersWhileIndependentSessionIsActive() {
        XCTAssertEqual(
            WatchCredentialSyncPolicy.disposition(
                phoneAccount: "N0BBB",
                linkedPhoneCallsign: "N0AAA",
                isWatchLoggedIn: true,
                hasSession: true,
                isReconnecting: false
            ),
            .deferUntilIdle
        )
    }

    func testWatchCredentialSyncDefersWhileIndependentSessionIsReconnecting() {
        XCTAssertEqual(
            WatchCredentialSyncPolicy.disposition(
                phoneAccount: "N0BBB",
                linkedPhoneCallsign: "N0AAA",
                isWatchLoggedIn: true,
                hasSession: false,
                isReconnecting: true
            ),
            .deferUntilIdle
        )
    }

    func testWatchCredentialSyncRequestsFreshCredentialsWhenIdleAndAccountDiffers() {
        XCTAssertEqual(
            WatchCredentialSyncPolicy.disposition(
                phoneAccount: "N0BBB",
                linkedPhoneCallsign: "N0AAA",
                isWatchLoggedIn: true,
                hasSession: false,
                isReconnecting: false
            ),
            .request
        )
    }

    func testWatchCredentialSyncIgnoresMatchingOrEmptyAccountWhenIdle() {
        XCTAssertEqual(
            WatchCredentialSyncPolicy.disposition(
                phoneAccount: "n0aaa",
                linkedPhoneCallsign: "N0AAA",
                isWatchLoggedIn: true,
                hasSession: false,
                isReconnecting: false
            ),
            .ignore
        )
        XCTAssertEqual(
            WatchCredentialSyncPolicy.disposition(
                phoneAccount: "",
                linkedPhoneCallsign: "N0AAA",
                isWatchLoggedIn: true,
                hasSession: false,
                isReconnecting: false
            ),
            .ignore
        )
    }

    func testWatchStationSnapshotUsesCurrentBusyRelayAndCountMetadata() {
        let saved = Station(
            callsign: "K1CURRENT-R",
            description: "Saved location",
            ipAddress: "192.0.2.1",
            type: .repeater,
            nodeNumber: 123
        )
        let current = Station(
            callsign: "K1CURRENT-R",
            description: "Current location [r] [20/20] [BUSY 12:34]",
            ipAddress: "198.51.100.1",
            type: .repeater,
            isBusy: true,
            nodeNumber: 123
        )

        let snapshot = WatchStationSnapshot.resolving(saved, from: [current])

        XCTAssertTrue(snapshot.isBusy)
        XCTAssertTrue(snapshot.isRelayOnly)
        XCTAssertEqual(snapshot.reportedConnected, 20)
        XCTAssertEqual(snapshot.reportedLimit, 20)
        XCTAssertEqual(snapshot.description, "Current location [r]")
    }

    func testWatchStationSnapshotClearsStaleAvailabilityAndFallsBackWhenDirectoryUnknown() {
        let saved = Station(
            callsign: "K1CURRENT-R",
            description: "Saved location [r] [20/20] [BUSY 12:34]",
            ipAddress: "192.0.2.1",
            type: .repeater,
            isBusy: true,
            nodeNumber: 123
        )
        let current = Station(
            callsign: "K1CURRENT-R",
            description: "Current location [3/20] [ON 12:35]",
            ipAddress: "198.51.100.1",
            type: .repeater,
            nodeNumber: 123
        )

        let snapshot = WatchStationSnapshot.resolving(saved, from: [current])
        XCTAssertFalse(snapshot.isBusy)
        XCTAssertFalse(snapshot.isRelayOnly)
        XCTAssertEqual(snapshot.reportedConnected, 3)
        XCTAssertEqual(snapshot.reportedLimit, 20)
        XCTAssertEqual(snapshot.description, "Current location")

        let fallback = WatchStationSnapshot.resolving(saved, from: [])
        XCTAssertTrue(fallback.isBusy)
        XCTAssertTrue(fallback.isRelayOnly)
        XCTAssertEqual(fallback.reportedConnected, 20)
        XCTAssertEqual(fallback.reportedLimit, 20)
    }

    func testWatchStationSnapshotPreservesBusyStateAndDefaultsOldPayloadsToAvailable() throws {
        let current = try XCTUnwrap(WatchStationSnapshot(dictionary: [
            "callsign": "K1FULL-R",
            "nodeNumber": 123,
            "type": Station.StationType.repeater.rawValue,
            "isBusy": true,
            "description": "Hilltop [BUSY 12:34]"
        ]))
        XCTAssertTrue(current.station.isBusy)

        let legacy = try XCTUnwrap(WatchStationSnapshot(dictionary: [
            "callsign": "K1OLD-R",
            "nodeNumber": 456,
            "type": Station.StationType.repeater.rawValue,
            "description": "Old snapshot"
        ]))
        XCTAssertFalse(legacy.station.isBusy)
    }

    func testWatchStationSnapshotRoundTripsAvailabilityMetadataBeyondDescriptionBudget() throws {
        let station = Station(
            callsign: "K1FULL-R",
            description: String(repeating: "x", count: 140) + " [r] [20/20] [BUSY 12:34]",
            ipAddress: "192.0.2.1",
            type: .repeater,
            isBusy: true,
            nodeNumber: 123
        )

        let encoded = WatchStationSnapshot(station: station).dictionary
        XCTAssertEqual((encoded["description"] as? String)?.count, 120)
        let decoded = try XCTUnwrap(WatchStationSnapshot(dictionary: encoded))

        XCTAssertTrue(decoded.isRelayOnly)
        XCTAssertEqual(decoded.reportedConnected, 20)
        XCTAssertEqual(decoded.reportedLimit, 20)
        XCTAssertTrue(decoded.station.isRelayOnly)
        XCTAssertEqual(decoded.station.reportedConnections?.connected, 20)
        XCTAssertEqual(decoded.station.reportedConnections?.limit, 20)
        XCTAssertTrue(decoded.station.isConnectionLimitReached)
        XCTAssertFalse(decoded.station.displayDescription.localizedCaseInsensitiveContains("[ON"))
        XCTAssertFalse(decoded.station.displayDescription.contains("[20/20]"))

        let shortStation = Station(
            callsign: "K2SHORT-R",
            description: "Short location [r] [20/20] [ON 12:34]",
            ipAddress: "192.0.2.2",
            type: .repeater
        )
        let shortEncoded = WatchStationSnapshot(station: shortStation).dictionary
        let shortDecoded = try XCTUnwrap(WatchStationSnapshot(dictionary: shortEncoded))
        XCTAssertFalse(shortDecoded.station.displayDescription.localizedCaseInsensitiveContains("[ON"))
        XCTAssertFalse(shortDecoded.station.displayDescription.contains("[20/20]"))
    }

    func testReceiveSequenceRejectsDuplicateLateWrongStreamAndExpiredFrames() {
        let stream = UUID()
        let otherStream = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        var sequence = WatchAudioReceiveSequence()

        XCTAssertTrue(sequence.accept(frame(stream: stream, sequence: 2, sentAt: now), expectedStreamID: stream, now: now))
        XCTAssertFalse(sequence.accept(frame(stream: stream, sequence: 2, sentAt: now), expectedStreamID: stream, now: now))
        XCTAssertFalse(sequence.accept(frame(stream: stream, sequence: 1, sentAt: now), expectedStreamID: stream, now: now))
        XCTAssertFalse(sequence.accept(frame(stream: otherStream, sequence: 3, sentAt: now), expectedStreamID: stream, now: now))
        XCTAssertFalse(sequence.accept(frame(stream: stream, sequence: 3, sentAt: now.addingTimeInterval(-1.01)), expectedStreamID: stream, now: now))
        XCTAssertFalse(sequence.accept(frame(stream: stream, sequence: 3, sentAt: now.addingTimeInterval(2.01)), expectedStreamID: stream, now: now))
    }

    func testFrameDecodeRejectsOversizedEnvelopeAndMalformedOrOversizedPayload() throws {
        XCTAssertNil(WatchAudioFrame.decode(Data(repeating: 0, count: 8_193)))
        XCTAssertNil(WatchAudioFrame.decode(Data("not-json".utf8)))

        let oversizedPayload = frame(stream: UUID(), sequence: 1, datagram: Data(repeating: 7, count: 4_097))
        XCTAssertNil(WatchAudioFrame.decode(try JSONEncoder().encode(oversizedPayload)))

        let emptyPayload = frame(stream: UUID(), sequence: 1, datagram: Data())
        XCTAssertNil(WatchAudioFrame.decode(try JSONEncoder().encode(emptyPayload)))
    }

    func testForwarderKeepsOneInFlightAndOnlyThreeNewestPendingFrames() async throws {
        var sends: [PendingSend] = []
        let forwarder = WatchAudioForwarder { data, reply, error in
            sends.append(PendingSend(data: data, reply: reply, error: error))
        }
        let stream = UUID()

        for value in UInt8(1)...6 {
            forwarder.forward(Data([value]), streamID: stream)
        }

        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(try decodedPayload(sends[0].data), Data([1]))

        sends[0].reply(Data([1]))
        await settleCallbacks()
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(try decodedPayload(sends[1].data), Data([4]))

        sends[1].reply(Data([1]))
        await settleCallbacks()
        XCTAssertEqual(try decodedPayload(sends[2].data), Data([5]))

        sends[2].reply(Data([1]))
        await settleCallbacks()
        XCTAssertEqual(try decodedPayload(sends[3].data), Data([6]))
    }

    func testFalseAcknowledgementTriggersFailureAndDropsPendingFrames() async {
        var sends: [PendingSend] = []
        var failureCount = 0
        let forwarder = WatchAudioForwarder { data, reply, error in
            sends.append(PendingSend(data: data, reply: reply, error: error))
        }
        forwarder.onFailure = { failureCount += 1 }
        let stream = UUID()
        forwarder.forward(Data([1]), streamID: stream)
        forwarder.forward(Data([2]), streamID: stream)

        sends[0].reply(Data([0]))
        await settleCallbacks()

        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(sends.count, 1)
    }

    func testWorkerQueueAcknowledgementAdvancesQueuedAudioOnMainActor() async throws {
        var sends: [PendingSend] = []
        let advanced = expectation(description: "next audio frame sent")
        let forwarder = WatchAudioForwarder { data, reply, error in
            XCTAssertTrue(Thread.isMainThread)
            sends.append(PendingSend(data: data, reply: reply, error: error))
            if sends.count == 2 { advanced.fulfill() }
        }
        let stream = UUID()
        forwarder.forward(Data([1]), streamID: stream)
        forwarder.forward(Data([2]), streamID: stream)
        let pending = try XCTUnwrap(sends.first)

        await Task.detached { pending.reply(Data([1])) }.value
        await fulfillment(of: [advanced], timeout: 2)

        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(try decodedPayload(sends[1].data), Data([2]))
        forwarder.stop()
    }

    func testWorkerQueueFailureStopsQueuedAudioOnMainActor() async throws {
        var sends: [PendingSend] = []
        let failed = expectation(description: "forwarding failure reported")
        let forwarder = WatchAudioForwarder { data, reply, error in
            sends.append(PendingSend(data: data, reply: reply, error: error))
        }
        forwarder.onFailure = {
            XCTAssertTrue(Thread.isMainThread)
            failed.fulfill()
        }
        let stream = UUID()
        forwarder.forward(Data([1]), streamID: stream)
        forwarder.forward(Data([2]), streamID: stream)
        let pending = try XCTUnwrap(sends.first)

        await Task.detached { pending.error(TestError.failed) }.value
        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(sends.count, 1)
    }

    func testCallbacksFromStoppedStreamCannotFailOrAdvanceNewStream() async throws {
        var sends: [PendingSend] = []
        var failureCount = 0
        let forwarder = WatchAudioForwarder { data, reply, error in
            sends.append(PendingSend(data: data, reply: reply, error: error))
        }
        forwarder.onFailure = { failureCount += 1 }

        forwarder.forward(Data([1]), streamID: UUID())
        let stale = sends[0]
        forwarder.stop()

        let newStream = UUID()
        forwarder.forward(Data([2]), streamID: newStream)
        forwarder.forward(Data([3]), streamID: newStream)
        XCTAssertEqual(sends.count, 2)

        stale.reply(Data([0]))
        stale.error(TestError.failed)
        await settleCallbacks()
        XCTAssertEqual(failureCount, 0)
        XCTAssertEqual(sends.count, 2)

        sends[1].reply(Data([1]))
        await settleCallbacks()
        XCTAssertEqual(sends.count, 3)
        XCTAssertEqual(try decodedPayload(sends[2].data), Data([3]))
    }

    private func frame(
        stream: UUID,
        sequence: UInt64,
        sentAt: Date = Date(),
        datagram: Data = Data([1])
    ) -> WatchAudioFrame {
        WatchAudioFrame(version: 1, streamID: stream, sequence: sequence, sentAt: sentAt, datagram: datagram)
    }

    private func decodedPayload(_ data: Data) throws -> Data {
        try JSONDecoder().decode(WatchAudioFrame.self, from: data).datagram
    }

    private func settleCallbacks() async {
        for _ in 0..<3 { await Task.yield() }
    }
}

// Immutable transport callbacks intentionally invoked from a worker, matching WCSession.
private struct PendingSend: @unchecked Sendable {
    let data: Data
    let reply: (Data) -> Void
    let error: (Error) -> Void
}

private enum TestError: Error {
    case failed
}
