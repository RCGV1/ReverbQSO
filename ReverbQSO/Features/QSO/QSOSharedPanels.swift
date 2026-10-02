// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

enum QSODesktopLayout {
    static func radioWidth(for windowWidth: CGFloat) -> CGFloat {
        max(420, windowWidth * 0.48)
    }
}

/// The call identity and status header shared by outgoing and incoming QSOs.
struct QSOCallHeader: View {
    let callsign: String
    let subtitle: String
    let badge: String
    let badgeColor: Color
    let status: String
    let statusColor: Color
    let elapsed: String

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Text(callsign)
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badgeColor.opacity(0.13), in: Capsule())
                        .foregroundStyle(badgeColor)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Label(status, systemImage: "circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(statusColor)
                Text(elapsed)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }
}

/// The same message timeline and composer layout for both call directions.
struct QSOMessagePane<Accessory: View, Composer: View>: View {
    let messages: [ChatMessage]
    let emptyText: String
    let accessory: Accessory
    let composer: Composer
    @State private var isNearBottom = true

    init(
        messages: [ChatMessage],
        emptyText: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder composer: () -> Composer
    ) {
        self.messages = messages
        self.emptyText = emptyText
        self.accessory = accessory()
        self.composer = composer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Messages", systemImage: "bubble.left.and.bubble.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                accessory
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        if messages.isEmpty {
                            ContentUnavailableView(
                                "No Messages Yet",
                                systemImage: "bubble.left",
                                description: Text(emptyText)
                            )
                            .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(messages) { message in
                                    ChatBubble(message: message)
                                        .frame(maxWidth: 640)
                                        .id(message.id)
                                }
                            }
                            .padding(20)
                            .background {
                                GeometryReader { content in
                                    Color.clear.preference(
                                        key: QSOMessageContentFrameKey.self,
                                        value: content.frame(in: .named("qsoMessages"))
                                    )
                                }
                            }
                        }
                    }
                    .coordinateSpace(name: "qsoMessages")
                    .defaultScrollAnchor(.bottom)
                    .onPreferenceChange(QSOMessageContentFrameKey.self) { frame in
                        isNearBottom = frame.maxY - viewport.size.height < 72
                    }
                    .onChange(of: messages.last?.id) { _, id in
                        guard isNearBottom, let id else { return }
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            Divider()
            composer
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QSOMessageContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

struct QSOMeters: View {
    let txLevel: Double
    let rxLevel: Double
    let isTransmitting: Bool
    let isMuted: Bool

    var body: some View {
        VStack(spacing: 10) {
            SignalMeter(level: isTransmitting ? txLevel : 0,
                        label: "TX  \(isTransmitting ? "●" : "○")")
            SignalMeter(level: isMuted ? 0 : rxLevel,
                        label: "RX  \(isMuted ? "○" : "●")")
        }
    }
}

/// Mac radio controls shared by outgoing and incoming calls.
struct QSODesktopAudioPanel<Actions: View>: View {
    @Binding var isPTTActive: Bool
    let canTransmit: Bool
    let isTransmitting: Bool
    let isReceiving: Bool
    let txLevel: Double
    let rxLevel: Double
    let isMuted: Bool
    let onPTTChange: (Bool) -> Void
    let actions: Actions

    init(
        isPTTActive: Binding<Bool>,
        canTransmit: Bool,
        isTransmitting: Bool,
        isReceiving: Bool,
        txLevel: Double,
        rxLevel: Double,
        isMuted: Bool,
        onPTTChange: @escaping (Bool) -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        _isPTTActive = isPTTActive
        self.canTransmit = canTransmit
        self.isTransmitting = isTransmitting
        self.isReceiving = isReceiving
        self.txLevel = txLevel
        self.rxLevel = rxLevel
        self.isMuted = isMuted
        self.onPTTChange = onPTTChange
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isReceiving ? "Receiving" : isTransmitting ? "Transmitting" : "Channel idle",
                  systemImage: isReceiving ? "waveform" : isTransmitting ? "mic.fill"
                    : "antenna.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isReceiving ? .green : isTransmitting ? .orange : .primary)

            HStack(alignment: .center, spacing: 16) {
                PTTButton(isActive: $isPTTActive,
                          isEnabled: canTransmit || isPTTActive,
                          size: 112,
                          onStateChange: onPTTChange)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Hold Space or PTT to talk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    QSOMeters(txLevel: txLevel, rxLevel: rxLevel,
                              isTransmitting: isTransmitting, isMuted: isMuted)
                    if isReceiving {
                        Text("Wait for the other station to finish")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actions
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
