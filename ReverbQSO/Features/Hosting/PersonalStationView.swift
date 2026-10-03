// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A single operator's incoming EchoLink line. The host owns the socket and
/// publishes availability only while it can actually receive a call.
struct PersonalStationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var host: EchoLinkConferenceHostService
    @State private var pttPressed = false
    @State private var chatDraft = ""
    @State private var callElapsed = "00:00"
    @State private var confirmsEndCall = false
    @State private var confirmsStopListening = false
    #if targetEnvironment(macCatalyst)
    @FocusState private var isRadioFocused: Bool
    @FocusState private var isChatFocused: Bool
    @State private var isSpacePTTActive = false
    #endif

    private var activeCall: InboundHostSession? {
        host.sessions.first { $0.state == .active }
    }

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
            if let call = activeCall {
                desktopCall(call)
            } else {
                stationOverview
            }
            #else
            stationOverview
            #endif
        }
        .navigationTitle("My Station")
        .toolbar {
            if activeCall != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { host.toggleRecording() } label: {
                        Label(host.isRecording ? "Stop Clip" : "Record Clip",
                              systemImage: host.isRecording ? "stop.circle.fill" : "record.circle")
                    }.tint(host.isRecording ? .red : .primary)
                }
            }
        }
        .confirmationDialog("End this call?", isPresented: $confirmsEndCall) {
            Button("End Call", role: .destructive) {
                guard let call = activeCall else { return }
                releasePTT()
                Task { await host.disconnect(id: call.id) }
            }
            Button("Keep Talking", role: .cancel) {}
        }
        .confirmationDialog("Stop receiving calls?", isPresented: $confirmsStopListening) {
            Button("Stop Receiving Calls", role: .destructive) {
                Task { await appState.stopPersonalCalls() }
            }
            Button("Keep Available", role: .cancel) {}
        }
        .task(id: activeCall?.id) {
            guard let call = activeCall else { return }
            while !Task.isCancelled {
                let seconds = max(0, Int(Date().timeIntervalSince(call.admittedAt)))
                callElapsed = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { releasePTT() }
        .onChange(of: activeCall?.id) { _, id in
            if id == nil { releasePTT() }
        }
        #if targetEnvironment(macCatalyst)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { releasePTT() }
        }
        #endif
    }

    private var stationOverview: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stationHeader

                    if host.isRunning && !host.isPersonalMode {
                        ContentUnavailableView(
                            "Conference host is running",
                            systemImage: "person.3.sequence.fill",
                            description: Text("Stop conference hosting before using your personal station.")
                        )
                    } else if let call = activeCall {
                        activeCallContent(call)
                    } else if let pending = host.pendingCall {
                        pendingCallContent(pending)
                    } else {
                        availabilityContent
                    }

                    if let error = host.errorMessage, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(20)
            }

            #if !targetEnvironment(macCatalyst)
            if activeCall != nil {
                chatComposer
            }
            #endif
        }
    }

    private var stationHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(activeCall?.callsign ?? appState.currentUser)
                .font(.largeTitle.monospaced().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Label(statusText, systemImage: statusIcon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(host.isRunning && host.isPersonalMode ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if activeCall != nil { return "In a call" }
        if host.pendingCall != nil { return "Incoming call" }
        if host.isStarting { return "Starting…" }
        if host.isRunning && host.isPersonalMode { return "Available for calls" }
        return "Not receiving calls"
    }

    private var statusIcon: String {
        if activeCall != nil { return "waveform" }
        if host.pendingCall != nil { return "phone.arrow.down.left" }
        return host.isRunning && host.isPersonalMode ? "checkmark.circle.fill" : "moon.zzz"
    }

    private var availabilityContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Let other EchoLink operators call your station directly.")
                .font(.body)
            Button {
                if host.isRunning {
                    confirmsStopListening = true
                } else {
                    Task { await appState.startPersonalCalls() }
                }
            } label: {
                Label(
                    host.isRunning ? "Stop Receiving Calls" : "Become Available",
                    systemImage: host.isRunning ? "phone.down" : "phone.arrow.down.left"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(host.isStarting || host.isStopping || !appState.qsoHub.entries.isEmpty)

            if !appState.qsoHub.entries.isEmpty {
                Text("Finish the current QSO before receiving personal calls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                #if targetEnvironment(macCatalyst)
                Text("Keep this Mac running and reachable on UDP 5198 and 5199. Direct connection mode is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Text("Calls can arrive while this app is open. iPhone stops listening in the background. Direct connection mode and reachable UDP 5198 and 5199 are required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
    }

    private func pendingCallContent(_ call: InboundHostSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(call.callsign) is calling", systemImage: "phone.arrow.down.left")
                .font(.title3.weight(.semibold))
            HStack {
                Button("Decline", role: .cancel) {
                    Task { await host.declinePendingCall() }
                }
                .buttonStyle(.bordered)
                .disabled(host.isAnsweringPendingCall)
                Button("Answer") {
                    Task { await host.acceptPendingCall() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(host.isAnsweringPendingCall)
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    private func desktopCall(_ call: InboundHostSession) -> some View {
        VStack(spacing: 0) {
            QSOCallHeader(
                callsign: call.callsign,
                subtitle: "Incoming personal call · \(appState.currentUser)",
                badge: "Person",
                badgeColor: .orange,
                status: host.isTransmitting ? "Transmitting"
                    : host.talkerCallsign != nil ? "Receiving" : "Connected",
                statusColor: host.isTransmitting ? .orange
                    : host.talkerCallsign != nil ? .green : .primary,
                elapsed: callElapsed
            )
            Divider()
            GeometryReader { geometry in
                if geometry.size.width >= 780 {
                    HStack(spacing: 0) {
                        desktopConversation
                        Divider()
                        desktopRadioPane
                            .frame(width: QSODesktopLayout.radioWidth(for: geometry.size.width))
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            desktopRadioPane
                                .frame(height: 380)
                            Divider()
                            desktopConversation
                                .frame(height: 500)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .focusable()
        .focusEffectDisabled()
        .focused($isRadioFocused)
        .defaultFocus($isRadioFocused, true)
        .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
            if press.phase == .up {
                guard isSpacePTTActive else { return .ignored }
                releasePTT()
                return .handled
            }
            guard !isChatFocused,
                  !press.modifiers.contains(.command),
                  !press.modifiers.contains(.control),
                  !press.modifiers.contains(.option) else { return .ignored }
            switch press.phase {
            case .down:
                guard !isSpacePTTActive, !host.isTransmitting,
                      host.talkerCallsign == nil else { return .handled }
                isSpacePTTActive = true
                pttPressed = true
                host.setPTT(active: true)
            case .repeat:
                break
            default:
                break
            }
            return .handled
        }
        .onReceive(SpacePTTReleaseMonitor.shared.releases) {
            guard isSpacePTTActive else { return }
            releasePTT()
        }
        .onAppear { isRadioFocused = true }
        .onChange(of: isChatFocused) { _, focused in
            if focused {
                releasePTT()
            } else {
                isRadioFocused = true
            }
        }
        .onChange(of: isRadioFocused) { _, focused in
            if !focused { releasePTT() }
        }
    }

    private var desktopConversation: some View {
        QSOMessagePane(messages: host.messages,
                       emptyText: "Messages from this operator will appear here.") {
            Text("Personal call")
                .font(.caption)
                .foregroundStyle(.secondary)
        } composer: {
            messageComposer
        }
    }

    private var desktopRadioPane: some View {
        VStack(spacing: 0) {
            QSODesktopAudioPanel(
                isPTTActive: $pttPressed,
                canTransmit: !host.isTransmitting && host.talkerCallsign == nil,
                isTransmitting: host.isTransmitting,
                isReceiving: host.talkerCallsign != nil && !host.isTransmitting,
                txLevel: host.inputLevel,
                rxLevel: host.outputLevel,
                isMuted: false,
                onPTTChange: { host.setPTT(active: $0) }
            ) {
                Button(role: .destructive) {
                    confirmsEndCall = true
                } label: {
                    Label("End Call", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .simultaneousGesture(TapGesture().onEnded {
            if !isChatFocused { isRadioFocused = true }
        })
    }
    #endif

    private func activeCallContent(_ call: InboundHostSession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(call.callsign)
                        .font(.title2.monospaced().weight(.semibold))
                    Text(host.talkerCallsign.map { "Listening to \($0)" }
                         ?? (host.isTransmitting ? "Transmitting" : "Connected"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("End Call", role: .destructive) { confirmsEndCall = true }
                    .buttonStyle(.bordered)
            }

            if host.isAutomaticallyRecording {
                Label(host.isRecording ? "Automatically recording + clip" : "Automatically recording",
                      systemImage: "record.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            } else if host.isRecording {
                Label("Recording clip", systemImage: "record.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 18) {
                PTTButton(
                    isActive: $pttPressed,
                    isEnabled: pttPressed || (!host.isTransmitting && host.talkerCallsign == nil),
                    size: 100,
                    onStateChange: { host.setPTT(active: $0) }
                )
                VStack(alignment: .leading, spacing: 7) {
                    Text("Hold to talk")
                        .font(.headline)
                    Text("Release to listen")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    QSOMeters(txLevel: host.inputLevel,
                              rxLevel: host.outputLevel,
                              isTransmitting: host.isTransmitting,
                              isMuted: false)
                }
            }

            Divider()
            Text("Messages")
                .font(.headline)
            if host.messages.isEmpty {
                Text("Messages from this station appear here.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(host.messages) { message in
                        ChatBubble(message: message)
                    }
                }
            }
        }
    }

    private var chatComposer: some View {
        VStack(spacing: 0) {
            Divider()
            messageComposer
                .padding(12)
        }
    }

    private var messageComposer: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $chatDraft)
                    #if targetEnvironment(macCatalyst)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                    .focused($isChatFocused)
                    #else
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .onSubmit(sendChat)
                Button(action: sendChat) {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor, in: Circle())
                }
                    .accessibilityLabel("Send message")
                    .disabled(chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.plain)
        }
    }

    private func releasePTT() {
        pttPressed = false
        host.setPTT(active: false)
        #if targetEnvironment(macCatalyst)
        isSpacePTTActive = false
        #endif
    }

    private func sendChat() {
        let body = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task {
            if await host.sendChat(body) { chatDraft = "" }
        }
    }
}
