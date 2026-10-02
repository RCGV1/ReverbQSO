// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A single chat message exchanged during a QSO session.
struct ChatMessage: Identifiable {
    let id: UUID
    let sender: String
    let body: String
    let timestamp: Date
    var isOutgoing: Bool
    let isInformational: Bool

    init(
        id: UUID = UUID(),
        sender: String,
        body: String,
        timestamp: Date = Date(),
        isOutgoing: Bool = false,
        isInformational: Bool = false
    ) {
        self.id = id
        self.sender = sender
        self.body = body
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.isInformational = isInformational
    }
}

/// Tracks only the visible tail, so a reconnect or a capped conference
/// transcript does not replay old messages as new alerts.
struct ChatMessageNotificationCursor {
    private var seenIDs: Set<UUID>

    init(messages: [ChatMessage] = []) {
        seenIDs = Set(messages.suffix(200).map(\.id))
    }

    mutating func newIncomingMessages(in messages: [ChatMessage]) -> [ChatMessage] {
        let recent = Array(messages.suffix(200))
        let newMessages = recent.filter {
            !seenIDs.contains($0.id) && !$0.isOutgoing && !$0.isInformational
        }
        seenIDs = Set(recent.map(\.id))
        return newMessages
    }
}
