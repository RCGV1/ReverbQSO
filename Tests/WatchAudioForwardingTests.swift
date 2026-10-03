// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class WatchAudioForwardingTests: XCTestCase {
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

private struct PendingSend {
    let data: Data
    let reply: (Data) -> Void
    let error: (Error) -> Void
}

private enum TestError: Error {
    case failed
}
