// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class ChatMessageNotificationCursorTests: XCTestCase {
    func testSvxLinkForwardedChatUsesOriginalSender() {
        let message = ChatMessage(sender: "N0NODE-R", body: "K1ABC>Good evening")

        XCTAssertEqual(message.sender, "K1ABC")
        XCTAssertEqual(message.body, "Good evening")
        XCTAssertEqual(message.relayedVia, ["N0NODE-R"])
    }

    func testForwardedChatPreservesMessageComparisonsAndQuotedCallsign() {
        let message = ChatMessage(sender: "N0NODE-R", body: "K1ABC>K2XYZ>5 > 3")
        XCTAssertEqual(message.sender, "K1ABC")
        XCTAssertEqual(message.body, "K2XYZ>5 > 3")
    }

    func testNestedRepeaterForwardingRetainsRelayPath() {
        let message = ChatMessage(sender: "N0NODE-R", body: "W1LINK-L>K1ABC>Hello")
        XCTAssertEqual(message.sender, "K1ABC")
        XCTAssertEqual(message.body, "Hello")
        XCTAssertEqual(message.relayedVia, ["N0NODE-R", "W1LINK-L"])
    }

    func testStationNoticesAndOrdinaryUserMessagesKeepTheirText() {
        for message in [
            ChatMessage(sender: "N0NODE-R", body: "Status>Listening"),
            ChatMessage(sender: "N0NODE-R", body: "K1ABC>"),
            ChatMessage(sender: "K1ABC", body: "K2XYZ>Hello"),
            ChatMessage(sender: "N0NODE-R", body: "K1ABC>Hello", isOutgoing: true),
            ChatMessage(sender: "N0NODE-R", body: "K1ABC>Hello", isInformational: true)
        ] {
            XCTAssertTrue(message.relayedVia.isEmpty)
            XCTAssertTrue(message.body.contains(">"))
        }
    }

    func testForwardedChatStillNotifiesOnce() {
        let message = ChatMessage(sender: "*DEMO*", body: "K1ABC>Hello")
        var cursor = ChatMessageNotificationCursor()
        XCTAssertEqual(message.sender, "K1ABC")
        XCTAssertEqual(cursor.newIncomingMessages(in: [message]).map(\.id), [message.id])
        XCTAssertTrue(cursor.newIncomingMessages(in: [message]).isEmpty)
    }

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
