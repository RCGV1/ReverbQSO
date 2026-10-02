// SPDX-License-Identifier: GPL-3.0-or-later

#if targetEnvironment(macCatalyst)
import SwiftUI

/// The signed-in station can host a roundtable on the Mac. EchoLink's directory
/// and the Mac's incoming UDP reachability determine whether others can join.
struct ConferenceHostView: View {
    private enum TextFieldFocus: Hashable {
        case allowedCallsigns, blockedCallsigns, chat
    }

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var host: EchoLinkConferenceHostService
    let directory: EchoLinkDirectoryService
    let outbound: EchoLinkConnectionService
    let callsign: String

    @AppStorage("conferenceHostMaximumPeers") private var maximumPeers = 4
    @AppStorage("conferenceHostAllowConferenceServers") private var allowConferenceServers = false
    @AppStorage("conferenceHostAllowMultiConferencing") private var allowMultiConferencing = false
    @AppStorage("conferenceHostAllowedCallsigns") private var allowedCallsigns = ""
    @AppStorage("conferenceHostBlockedCallsigns") private var blockedCallsigns = ""
    @State private var pttPressed = false
    @State private var isSpacePTTActive = false
    @State private var chatDraft = ""
    @FocusState private var focusedTextField: TextFieldFocus?
    @FocusState private var isRadioFocused: Bool

    var body: some View {
        Form {
            Section("Station") {
                LabeledContent("Callsign", value: callsign)
                LabeledContent("Status") {
                    Label(host.isRunning ? "Hosting" : host.isStarting ? "Starting" : "Offline",
                          systemImage: host.isRunning ? "dot.radiowaves.left.and.right" : "circle")
                        .foregroundStyle(host.isRunning ? .green : .secondary)
                }
                if host.isRunning {
                    LabeledContent("Connections", value: "\(host.sessions.count) / \(host.maximumPeers)")
                    if let talker = host.talkerCallsign {
                        LabeledContent("Talking", value: talker)
                    }
                }
            }

            Section("Conference settings") {
                Stepper("Maximum connected stations: \(maximumPeers)", value: $maximumPeers, in: 2...99)
                    .disabled(host.isRunning || host.isStarting)
                Toggle("Allow conference servers", isOn: $allowConferenceServers)
                    .disabled(host.isRunning || host.isStarting)
                Toggle("Allow multi-conferencing", isOn: $allowMultiConferencing)
                    .disabled(host.isRunning || host.isStarting || !allowConferenceServers)
                TextField("Allowed callsigns (optional)", text: $allowedCallsigns)
                    .textInputAutocapitalization(.characters)
                    .focused($focusedTextField, equals: .allowedCallsigns)
                    .disabled(host.isRunning || host.isStarting)
                TextField("Blocked callsigns (optional)", text: $blockedCallsigns)
                    .textInputAutocapitalization(.characters)
                    .focused($focusedTextField, equals: .blockedCallsigns)
                    .disabled(host.isRunning || host.isStarting)
                Text("Separate callsigns with commas. An allowed list admits only those callsigns; the blocked list always takes priority.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Plan for roughly \(maximumPeers * 17) kbps of upstream voice bandwidth at capacity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Incoming calls") {
                Text("Select Direct in Network Settings. The Mac must receive UDP 5198 and 5199 on its own public address. Hosting uses your signed-in callsign; a dedicated *NAME* conference requires separate EchoLink registration.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if host.isRunning {
                    Button("Stop hosting", role: .destructive) {
                        Task { await host.stop() }
                    }
                } else {
                    Button {
                        Task {
                            await host.start(
                                callsign: callsign,
                                directory: directory,
                                outbound: outbound,
                                policy: InboundHostPolicy(
                                    maximumPeers: maximumPeers,
                                    allowsConferenceServers: allowConferenceServers,
                                    allowsMultiConferencing: allowMultiConferencing,
                                    deniedCallsigns: Self.callsigns(from: blockedCallsigns),
                                    allowedCallsigns: allowedCallsigns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? nil : Self.callsigns(from: allowedCallsigns)
                                )
                            )
                        }
                    } label: {
                        if host.isStarting {
                            ProgressView("Starting host…")
                        } else {
                            Label("Start hosting", systemImage: "person.3.fill")
                        }
                    }
                    .disabled(host.isStarting || !directory.isLoggedIn || outbound.session != nil)
                }
                if let error = host.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            if host.isRunning {
                Section("Local operator") {
                    HStack(spacing: 24) {
                        PTTButton(
                            isActive: $pttPressed,
                            isEnabled: pttPressed || (!host.isTransmitting && host.talkerCallsign == nil),
                            size: 88,
                            onStateChange: { host.setPTT(active: $0) }
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            Text(host.isTransmitting ? "Transmitting" : host.talkerCallsign.map { "Listening to \($0)" } ?? "Hold PTT to speak")
                                .font(.headline)
                            ProgressView(value: host.inputLevel)
                                .accessibilityLabel("Microphone level")
                            Text("Hold Space or the button to talk. One station speaks at a time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Participants") {
                    if host.sessions.isEmpty {
                        Text("Waiting for stations to join")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(host.sessions, id: \.id) { peer in
                        HStack {
                            Image(systemName: host.talkerCallsign == peer.callsign ? "waveform" : "person")
                                .foregroundStyle(host.talkerCallsign == peer.callsign ? .green : .secondary)
                            Text(peer.callsign)
                                .font(.body.monospaced().weight(.semibold))
                            Spacer()
                            if host.talkerCallsign == peer.callsign {
                                Text("Talking")
                                    .foregroundStyle(.green)
                            }
                            Button("Disconnect", role: .destructive) {
                                Task { await host.disconnect(id: peer.id) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Section("Conference chat") {
                    if host.messages.isEmpty {
                        Text("Messages from participants appear here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(host.messages) { message in
                                        ChatBubble(message: message)
                                            .id(message.id)
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                            .frame(minHeight: 120, maxHeight: 280)
                            .onChange(of: host.messages.last?.id) { _, id in
                                if let id { proxy.scrollTo(id, anchor: .bottom) }
                            }
                        }
                    }
                    HStack {
                        TextField("Message everyone", text: $chatDraft)
                            .focused($focusedTextField, equals: .chat)
                            .onSubmit { sendChat() }
                            .disabled(host.sessions.isEmpty)
                        Button("Send", action: sendChat)
                            .disabled(host.sessions.isEmpty || chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .navigationTitle("Conference Host")
        .toolbar {
            if host.isRunning && !host.sessions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { host.toggleRecording() } label: {
                        Label(host.isRecording ? "Stop Recording" : "Record QSO", systemImage: host.isRecording ? "stop.circle.fill" : "record.circle")
                    }.tint(host.isRecording ? .red : .primary)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isRadioFocused)
        .defaultFocus($isRadioFocused, true)
        .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
            if press.phase == .up {
                guard isSpacePTTActive else { return .ignored }
                releaseSpacePTT()
                return .handled
            }
            guard focusedTextField == nil,
                  !press.modifiers.contains(.command),
                  !press.modifiers.contains(.control),
                  !press.modifiers.contains(.option) else { return .ignored }
            switch press.phase {
            case .down:
                guard !isSpacePTTActive, host.isRunning, !host.isTransmitting,
                      host.talkerCallsign == nil else { return .handled }
                isSpacePTTActive = true
                host.setPTT(active: true)
            case .repeat:
                break
            default:
                break
            }
            return .handled
        }
        .onAppear { isRadioFocused = true }
        .onDisappear { releaseSpacePTT() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { releaseSpacePTT() }
        }
        .onChange(of: focusedTextField) { _, focused in
            if focused != nil {
                releaseSpacePTT()
            } else {
                isRadioFocused = true
            }
        }
        .onChange(of: isRadioFocused) { _, focused in
            if !focused { releaseSpacePTT() }
        }
        .onChange(of: allowConferenceServers) { _, allowed in
            if !allowed { allowMultiConferencing = false }
        }
        .onChange(of: host.isRunning) { _, running in
            if !running {
                pttPressed = false
                releaseSpacePTT()
            } else if focusedTextField == nil {
                isRadioFocused = true
            }
        }
    }

    private static func callsigns(from text: String) -> Set<String> {
        Set(text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }.filter { !$0.isEmpty })
    }

    private func sendChat() {
        Task {
            if await host.sendChat(chatDraft) { chatDraft = "" }
        }
    }

    private func releaseSpacePTT() {
        guard isSpacePTTActive else { return }
        isSpacePTTActive = false
        host.setPTT(active: false)
    }
}
#endif
