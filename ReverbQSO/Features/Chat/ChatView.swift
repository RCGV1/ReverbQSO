// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

private struct ChatBottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Sheet-style chat view for exchanging text messages during a QSO session.
///
/// Receives `connectionService` explicitly (same reason as QSOView/DirectoryView —
/// @EnvironmentObject is not accessible in StateObject init).
struct ChatView: View {

    @StateObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTextFieldFocused: Bool
    @State private var isNearBottom = true
    @State private var newMessageCount = 0

    init(connectionService: EchoLinkConnectionService) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(connectionService: connectionService))
    }

    var body: some View {
        NavigationStack {
            messageList
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    inputBar
                }
                .navigationTitle(viewModel.stationCallsign)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    private struct PresentedMessage: Identifiable {
        let message: ChatMessage
        let showsTime: Bool
        let showsSender: Bool
        let startsGroup: Bool

        var id: UUID { message.id }
    }

    private var presentedMessages: [PresentedMessage] {
        var previous: ChatMessage?
        return viewModel.messages.map { message in
            let showsTime = previous.map {
                !Calendar.current.isDate($0.timestamp, inSameDayAs: message.timestamp)
                    || message.timestamp.timeIntervalSince($0.timestamp) >= 15 * 60
            } ?? true
            let startsGroup = showsTime || previous.map {
                $0.sender != message.sender
                    || $0.isOutgoing != message.isOutgoing
                    || message.timestamp.timeIntervalSince($0.timestamp) >= 2 * 60
            } ?? true
            let row = PresentedMessage(
                message: message,
                showsTime: showsTime,
                showsSender: !message.isOutgoing && startsGroup,
                startsGroup: startsGroup
            )
            previous = message
            return row
        }
    }

    // MARK: - Subviews

    private var messageList: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        if viewModel.messages.isEmpty {
                            ContentUnavailableView(
                                "No Messages",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("Send a message to the station.")
                            )
                            .padding(.top, 60)
                        } else {
                            LazyVStack(spacing: 3) {
                                ForEach(presentedMessages) { row in
                                    if row.showsTime {
                                        Text(row.message.timestamp.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                    }

                                    ChatBubble(
                                        message: row.message,
                                        showsSender: row.showsSender,
                                        showsTimestamp: false
                                    )
                                    .padding(.top, row.startsGroup && !row.showsTime ? 8 : 0)
                                    .id(row.id)
                                }
                                GeometryReader { bottom in
                                    Color.clear.preference(
                                        key: ChatBottomOffsetKey.self,
                                        value: bottom.frame(in: .named("chatScroll")).maxY
                                    )
                                }
                                .frame(height: 8)
                                .id("conversation-bottom")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }
                    .coordinateSpace(name: "chatScroll")
                    .scrollDismissesKeyboard(.interactively)

                    if newMessageCount > 0 {
                        Button {
                            proxy.scrollTo("conversation-bottom", anchor: .bottom)
                            newMessageCount = 0
                        } label: {
                            Label("\(newMessageCount) new", systemImage: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 8)
                    }
                }
                .onPreferenceChange(ChatBottomOffsetKey.self) { bottomY in
                    isNearBottom = viewModel.messages.isEmpty || bottomY <= viewport.size.height + 32
                    if isNearBottom { newMessageCount = 0 }
                }
            }
            .task {
                await Task.yield()
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .onChange(of: viewModel.messages.last?.id) { oldID, newID in
                guard newID != nil else { return }
                if oldID == nil || isNearBottom || viewModel.messages.last?.isOutgoing == true {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                } else {
                    newMessageCount += 1
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $viewModel.draftMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isTextFieldFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color(.separator), lineWidth: 1)
                }
                .onSubmit {
                    Task { await viewModel.sendMessage() }
                }

            Button {
                Task { await viewModel.sendMessage() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.callout.weight(.bold))
                    .frame(width: 32, height: 32)
                    .background(viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color(.systemGray4) : Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .disabled(viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Color(.systemBackground)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {

    let message: ChatMessage
    var showsSender = true
    var showsTimestamp = true

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if showsSender && !message.isOutgoing {
                    Text(message.sender)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                Text(message.body)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(message.isOutgoing ? Color.accentColor : Color(.systemGray5))
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                if showsTimestamp {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            }

            if !message.isOutgoing { Spacer(minLength: 48) }
        }
    }
}
