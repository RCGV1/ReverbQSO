// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine

/// View model for the chat interface during an active QSO session.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published var messages: [ChatMessage] = []
    @Published var draftMessage: String = ""

    // MARK: - Dependencies

    private let connectionService: EchoLinkConnectionService
    private var cancellables = Set<AnyCancellable>()

    var stationCallsign: String {
        connectionService.session?.station.callsign ?? "Messages"
    }

    init(connectionService: EchoLinkConnectionService) {
        self.connectionService = connectionService
        bindToService()
    }

    // MARK: - Actions

    /// Send the current draft message.
    func sendMessage() async {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draftMessage = ""
        await connectionService.sendChat(message: text)
    }

    // MARK: - Binding

    private func bindToService() {
        connectionService.$incomingChatMessages
            .receive(on: DispatchQueue.main)
            .assign(to: &$messages)
    }
}
