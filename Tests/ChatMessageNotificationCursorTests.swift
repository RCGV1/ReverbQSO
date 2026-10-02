// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class ChatMessageNotificationCursorTests: XCTestCase {
    func testExistingMessagesAreNotReplayedAndOnlyNewChatAlerts() {
        let earlier = ChatMessage(sender: "W6ABC", body: "Earlier")
        var cursor = ChatMessageNotificationCursor(messages: [earlier])
        let outgoing = ChatMessage(sender: "ME", body: "Reply", isOutgoing: true)
        let stationInfo = ChatMessage(sender: "Remote", body: "Welcome", isInformational: true)
        let incoming = ChatMessage(sender: "K6XYZ", body: "Hello")
        let transcript = [earlier, outgoing, stationInfo, incoming]

        XCTAssertEqual(cursor.newIncomingMessages(in: transcript).map(\.id), [incoming.id])
        XCTAssertTrue(cursor.newIncomingMessages(in: transcript).isEmpty)
    }

    func testCappedTranscriptStillDetectsNewMessage() {
        let earlier = (0..<200).map { ChatMessage(sender: "W6ABC", body: "\($0)") }
        var cursor = ChatMessageNotificationCursor(messages: earlier)
        let newest = ChatMessage(sender: "K6XYZ", body: "New")

        XCTAssertEqual(cursor.newIncomingMessages(in: Array(earlier.dropFirst()) + [newest]).map(\.id),
                       [newest.id])
    }
}
