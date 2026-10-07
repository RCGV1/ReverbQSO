// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Active QSO controls and station activity.
struct QSOView: View {

    @StateObject private var viewModel: QSOViewModel
    private let connectionService: EchoLinkConnectionService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showChat = false
    @State private var showAudioRoutes = false
    @State private var showAudioDiagnostics = false
    @AppStorage("showAudioStats") private var showAudioStats = false
    @State private var showDTMF = false
    @State private var showStationActivity = false
    @State private var showParticipants = false
    @State private var showDisconnectConfirmation = false
    @State private var chatDraft = ""
    @State private var dtmfDraft = ""
    @FocusState private var isChatFocused: Bool
    #if targetEnvironment(macCatalyst)
    @State private var showDesktopStationInfo = false
    @State private var participantSearch = ""
    @FocusState private var isRadioFocused: Bool
    @FocusState private var isParticipantSearchFocused: Bool
    @State private var isSpacePTTActive = false
    @State private var spacePTTOwner = UUID()
    @State private var isSpacePTTVisible = false
    #endif

    init(connectionService: EchoLinkConnectionService) {
        self.connectionService = connectionService
        _viewModel = StateObject(wrappedValue: QSOViewModel(connectionService: connectionService))
    }

    var body: some View {
        ZStack {
            backgroundGradient
            if !viewModel.isConnected && !viewModel.canReconnect
                && viewModel.session?.state != .disconnected {
                connectingContent
            } else {
                #if targetEnvironment(macCatalyst)
                desktopContent
                #else
                if horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad {
                    tabletContent
                } else {
                    compactContent
                }
                #endif
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        #if !targetEnvironment(macCatalyst)
        .navigationTitle(UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
                         ? "" : viewModel.isConnected ? viewModel.stationCallsign : "QSO")
        #endif
        .toolbar {
            #if !targetEnvironment(macCatalyst)
            if viewModel.isConnected && showAudioStats {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAudioDiagnostics = true } label: {
                        Label("Audio Stats", systemImage: "waveform.path.ecg")
                    }
                    .accessibilityIdentifier("qso.audioStats")
                    .accessibilityHint("Show encoding, bitrate, packet loss, and audio buffer delay")
                }
            }
            #endif
            if viewModel.isConnected {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { viewModel.toggleRecording() } label: {
                        Label(viewModel.isRecording ? "Stop Clip" : "Record Clip",
                              systemImage: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                    }
                    .tint(viewModel.isRecording ? .red : .primary)
                    .accessibilityLabel(viewModel.isRecording ? "Stop recording clip" : "Record clip")
                }
            }
            if viewModel.isConnected && viewModel.isAutomaticallyRecording {
                ToolbarItem(placement: .topBarLeading) {
                    Label(viewModel.isRecording ? "Automatically recording + clip" : "Automatically recording",
                          systemImage: "record.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        #if !targetEnvironment(macCatalyst)
                        .labelStyle(.iconOnly)
                        #endif
                }
            }
            #if !targetEnvironment(macCatalyst)
            if viewModel.isConnected && hasStationActivity,
               !(horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showStationActivity = true } label: {
                        Label("Station messages", systemImage: "text.bubble")
                    }
                    .accessibilityHint("Show information and messages sent by this station")
                }
            }
            #endif
        }
        .sheet(isPresented: $showChat) {
            ChatView(connectionService: connectionService)
        }
        .sheet(isPresented: $showAudioRoutes) {
            audioRouteSheet
        }
        #if !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showAudioDiagnostics) {
            NavigationStack {
                QSOAudioDiagnosticsView(connectionService: connectionService)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showAudioDiagnostics = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        #endif
        .sheet(isPresented: $showDTMF) {
            dtmfSheet
        }
        .sheet(isPresented: $showStationActivity) {
            stationActivitySheet
        }
        .sheet(isPresented: $showParticipants) {
            participantsSheet
        }
        .alert("Disconnect", isPresented: $showDisconnectConfirmation) {
            Button("Disconnect", role: .destructive) {
                Task { await viewModel.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("End contact with \(viewModel.stationCallsign)?")
        }
        .alert(viewModel.errorTitle, isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.dismissError() } }
        )) {
            if viewModel.canReconnect {
                Button("Reconnect") {
                    Task { await viewModel.reconnect() }
                }
            }
            Button("OK", role: .cancel) {
                viewModel.dismissError()
                if !viewModel.canReconnect,
                   viewModel.session == nil || viewModel.session?.state == .disconnected {
                    dismiss()
                }
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: showAudioStats) { _, enabled in
            if !enabled {
                showAudioDiagnostics = false
                showAudioRoutes = false
            }
        }
        .onChange(of: viewModel.session?.state) { _, newState in
            if (newState == .disconnected || newState == nil), connectionService.error == nil {
                dismiss()
            }
            #if targetEnvironment(macCatalyst)
            if newState != .connected { releaseSpacePTT() }
            #endif
        }
        #if targetEnvironment(macCatalyst)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { releaseSpacePTT() }
        }
        .onDisappear { releaseSpacePTT() }
        #endif
        #if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        .onAppear {
            guard SimulatorDemoData.isEnabled else { return }
            switch SimulatorDemoData.screen {
            case "chat": showChat = true
            case "activity": showStationActivity = true
            case "participants": showParticipants = true
            case "audio": showAudioRoutes = true
            case "dtmf": showDTMF = true
            default: break
            }
        }
        #endif
    }

    // MARK: - Subviews

    private var connectingContent: some View {
        VStack(spacing: 0) {
            stationHeader
                .padding(.top, 24)
                .padding(.horizontal, 24)

            Spacer()
            connectingIndicator
            Spacer()
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactContent: some View {
        GeometryReader { geometry in
            if geometry.size.height < 360 {
                ScrollView {
                    VStack(spacing: 12) {
                        VStack(spacing: 12) {
                            compactStatusContent
                        }
                        .padding(.horizontal, 16)

                        if viewModel.isConnected && !isChatFocused {
                            radioControls(pttSize: 88)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 12) {
                            compactStatusContent
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    if viewModel.isConnected && !isChatFocused {
                        radioControls(pttSize: geometry.size.height < 560 ? 104 : 120)
                    }
                }
            }
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var compactStatusContent: some View {
        if viewModel.isConnected {
            compactConnectionStatus
                .padding(.top, 8)
        } else {
            stationHeader
                .padding(.top, 16)
        }

        if viewModel.isConnected, !viewModel.activeNodeParticipants.isEmpty {
            participantSummary
        }

        audioStatusArea

        if !viewModel.isConnected {
            sessionProgress
                .padding(.top, 32)
        }
    }

    #if !targetEnvironment(macCatalyst)
    private var tabletContent: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                VStack(spacing: 0) {
                    tabletStationHeader
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    Divider()
                    if viewModel.isConnected {
                        HStack(spacing: 0) {
                            tabletRadioPane
                                .frame(width: min(340, geometry.size.width * 0.42))
                            Divider()
                            tabletConversationPane
                        }
                    } else {
                        sessionProgress
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                compactContent
            }
        }
        .background(Color(.systemBackground))
    }

    private var tabletRadioPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Label(viewModel.isRemoteTransmitting ? "Receiving" : viewModel.isPTTActive ? "Transmitting" : "Channel idle",
                      systemImage: viewModel.isRemoteTransmitting ? "waveform" : viewModel.isPTTActive ? "mic.fill" : "antenna.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.isRemoteTransmitting ? .green : viewModel.isPTTActive ? .orange : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                PTTButton(
                    isActive: $viewModel.isPTTActive,
                    isEnabled: viewModel.canTransmit || viewModel.isPTTActive,
                    size: 104
                ) { active in
                    viewModel.togglePTT(active: active)
                }
                levelMeters
                audioStatusArea
                if viewModel.isSendingDTMF {
                    Label("Sending DTMF tones", systemImage: "circle.grid.3x3.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button {
                        viewModel.toggleMute()
                    } label: {
                        Label(viewModel.isMuted ? "Unmute" : "Mute",
                              systemImage: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    Button {
                        showAudioRoutes = true
                    } label: {
                        Label("Audio", systemImage: "airplayaudio")
                    }
                    if supportsRemotePad {
                        Button {
                            showDTMF = true
                        } label: {
                            Label("DTMF", systemImage: "circle.grid.3x3.fill")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    showDisconnectConfirmation = true
                } label: {
                    Label("Disconnect", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(18)
            Divider()
            HStack {
                Label("Participants", systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(viewModel.activeNodeParticipants.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            ScrollView {
                if viewModel.activeNodeParticipants.isEmpty {
                    Text("No participant list available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.activeNodeParticipants) { participant in
                            HStack(spacing: 8) {
                                Image(systemName: participant.isTransmitting ? "waveform" : "person")
                                    .foregroundStyle(participant.isTransmitting ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(participant.callsign)
                                        .font(.subheadline.monospaced().weight(.semibold))
                                    if let name = participant.displayName, name != participant.callsign {
                                        Text(name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var tabletConversationPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Messages", systemImage: "bubble.left.and.bubble.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let station = viewModel.session?.station, station.nodeNumber > 0 {
                    Text("Node \(station.nodeNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if viewModel.chatMessages.isEmpty {
                        ContentUnavailableView(
                            "No Messages Yet",
                            systemImage: "bubble.left",
                            description: Text("Messages from this station will appear here.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.chatMessages) { message in
                                ChatBubble(message: message)
                                    .frame(maxWidth: 640)
                                    .id(message.id)
                            }
                        }
                        .padding(20)
                    }
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: viewModel.chatMessages.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            chatComposer
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    #if targetEnvironment(macCatalyst)
    private var desktopContent: some View {
        VStack(spacing: 0) {
            desktopHeader
            Divider()
            if viewModel.isConnected {
                GeometryReader { geometry in
                    if geometry.size.width >= 780 {
                        HStack(spacing: 0) {
                            desktopConversationPane
                            Divider()
                            desktopRadioPane
                                .frame(width: QSODesktopLayout.radioWidth(for: geometry.size.width))
                        }
                    } else {
                        let radioHeight: CGFloat = 430
                        ScrollView {
                            VStack(spacing: 0) {
                                desktopRadioPane
                                    .frame(height: radioHeight)
                                Divider()
                                desktopConversationPane
                                    .frame(height: max(260, geometry.size.height - radioHeight))
                            }
                        }
                    }
                }
            } else {
                sessionProgress
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                releaseSpacePTT()
                return .handled
            }
            guard !isChatFocused, !isParticipantSearchFocused,
                  !press.modifiers.contains(.command),
                  !press.modifiers.contains(.control),
                  !press.modifiers.contains(.option) else { return .ignored }
            switch press.phase {
            case .down:
                guard !isSpacePTTActive, canStartSpacePTT else { return .handled }
                guard SpacePTTReleaseMonitor.shared.claim(spacePTTOwner) else { return .handled }
                isSpacePTTActive = true
                viewModel.togglePTT(active: true)
            case .repeat:
                break
            default:
                break
            }
            return .handled
        }
        .background(SpacePTTKeyboardHandler {
            let eligible = canStartSpacePTT
            SpacePTTReleaseMonitor.shared.logEligibility("qso", eligible: eligible, focused: isRadioFocused)
            guard eligible, !isSpacePTTActive,
                  SpacePTTReleaseMonitor.shared.claim(spacePTTOwner) else { return }
            isSpacePTTActive = true
            viewModel.togglePTT(active: true)
        })
        .onReceive(SpacePTTReleaseMonitor.shared.releases) { releaseSpacePTT() }
        .onAppear {
            isSpacePTTVisible = true
            isRadioFocused = true
        }
        .onDisappear {
            isSpacePTTVisible = false
            releaseSpacePTT()
        }
        .onChange(of: viewModel.isConnected) { _, connected in
            if connected && !isChatFocused && !isParticipantSearchFocused {
                isRadioFocused = true
            }
        }
        .onChange(of: isChatFocused) { _, focused in
            if focused {
                releaseSpacePTT()
            } else {
                isRadioFocused = true
            }
        }
        .onChange(of: isParticipantSearchFocused) { _, focused in
            if focused {
                releaseSpacePTT()
            } else {
                isRadioFocused = true
            }
        }
        .onChange(of: showAudioDiagnostics) { _, shown in
            if shown { releaseSpacePTT() }
            else if !isChatFocused && !isParticipantSearchFocused { isRadioFocused = true }
        }
    }

    private var desktopHeader: some View {
        QSOCallHeader(
            callsign: viewModel.stationCallsign.isEmpty ? "Connecting…" : viewModel.stationCallsign,
            subtitle: viewModel.session?.station.description.isEmpty == false
                ? viewModel.session?.station.description ?? "" : "EchoLink station",
            badge: viewModel.session?.station.type.displayName ?? "Station",
            badgeColor: viewModel.session.map { typeColor(for: $0.station.type) } ?? .secondary,
            status: connectionStateText,
            statusColor: connectionStateColor,
            elapsed: viewModel.formattedElapsedTime
        )
    }

    private var desktopConversationPane: some View {
        QSOMessagePane(messages: viewModel.chatMessages,
                       emptyText: "Messages from this station will appear here.") {
            Group {
                if !viewModel.sysopInfo.isEmpty {
                    Button {
                        showDesktopStationInfo = true
                    } label: {
                        Label("Station info", systemImage: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .popover(isPresented: $showDesktopStationInfo) {
                        ScrollView {
                            Text(viewModel.sysopInfo)
                                .font(.subheadline)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                        }
                        .frame(width: 360, height: 240)
                    }
                }
                if let station = viewModel.session?.station, station.nodeNumber > 0 {
                    Text("Node \(station.nodeNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } composer: {
            chatComposer
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            audioStatusArea.padding(.horizontal, 20)
        }
    }

    private var desktopRadioPane: some View {
        VStack(spacing: 0) {
            QSODesktopAudioPanel(
                isPTTActive: $viewModel.isPTTActive,
                canTransmit: viewModel.canTransmit,
                isTransmitting: viewModel.isPTTActive,
                isReceiving: viewModel.isRemoteTransmitting,
                txLevel: viewModel.inputLevel,
                rxLevel: viewModel.outputLevel,
                isMuted: viewModel.isMuted,
                onPTTChange: { viewModel.togglePTT(active: $0) }
            ) {
                HStack(spacing: 8) {
                    Button {
                        viewModel.toggleMute()
                    } label: {
                        Label(viewModel.isMuted ? "Unmute" : "Mute",
                              systemImage: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    Button {
                        showAudioRoutes = true
                    } label: {
                        Label("Audio", systemImage: "airplayaudio")
                    }
                    if showAudioStats {
                        Button {
                            showAudioDiagnostics = true
                        } label: {
                            Label("Audio Stats", systemImage: "waveform.path.ecg")
                        }
                        .accessibilityIdentifier("qso-audio-stats")
                        .help("Audio codec, bitrate, packet loss, and buffering")
                        .popover(isPresented: $showAudioDiagnostics) {
                            NavigationStack {
                                QSOAudioDiagnosticsView(connectionService: connectionService)
                                    .toolbar {
                                        ToolbarItem(placement: .topBarTrailing) {
                                            Button("Done") { showAudioDiagnostics = false }
                                        }
                                    }
                            }
                            .frame(width: 440, height: 600)
                        }
                    }
                    if supportsRemotePad {
                        Button {
                            showDTMF = true
                        } label: {
                            Label("DTMF", systemImage: "circle.grid.3x3.fill")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Button(role: .destructive) {
                    showDisconnectConfirmation = true
                } label: {
                    Label("Disconnect", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Divider()
            HStack {
                Label("Participants", systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(viewModel.activeNodeParticipants.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            if viewModel.activeNodeParticipants.count > 8 {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find callsign", text: $participantSearch)
                        .textFieldStyle(.plain)
                        .focused($isParticipantSearchFocused)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
            ScrollView {
                if viewModel.activeNodeParticipants.isEmpty {
                    Text("No participant list available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                } else {
                    LazyVStack(spacing: 7) {
                        ForEach(filteredDesktopParticipants) { participant in
                            HStack(spacing: 8) {
                                Image(systemName: participant.isTransmitting ? "waveform" : "person")
                                    .foregroundStyle(participant.isTransmitting ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(participant.callsign)
                                        .font(.caption.monospaced().weight(.semibold))
                                    if let name = participant.displayName, name != participant.callsign {
                                        Text(name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .simultaneousGesture(TapGesture().onEnded {
            if !isChatFocused && !isParticipantSearchFocused { isRadioFocused = true }
        })
    }

    private var filteredDesktopParticipants: [ActiveNodeParticipant] {
        let query = participantSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.activeNodeParticipants }
        return viewModel.activeNodeParticipants.filter {
            $0.callsign.localizedCaseInsensitiveContains(query)
                || ($0.displayName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    #endif

    @ViewBuilder
    private var sessionProgress: some View {
        if viewModel.canReconnect || viewModel.session?.state == .disconnected {
            disconnectedIndicator
        } else {
            connectingIndicator
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(.systemBackground),
                connectionStateColor.opacity(0.06)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var compactConnectionStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(connectionStateColor).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(connectionStateText)
                        .font(.subheadline)
                        .foregroundStyle(connectionStateColor)
                }
                if let station = viewModel.session?.station {
                    Text(station.nodeNumber > 0
                         ? "\(station.type.displayName) · \(station.nodeNumber)"
                         : station.type.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(viewModel.formattedElapsedTime)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Duration \(viewModel.formattedElapsedTime)")
        }
    }

    private var stationHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Text(viewModel.stationCallsign.isEmpty ? "Connecting..." : viewModel.stationCallsign)
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                #if !targetEnvironment(macCatalyst)
                if hasStationActivity {
                    Button {
                        showStationActivity = true
                    } label: {
                        Image(systemName: "text.bubble.fill")
                            .font(.title3)
                            .padding(8)
                            .background(Color.accentColor.opacity(0.14), in: Circle())
                    }
                    .accessibilityLabel("Station messages")
                    .accessibilityHint("Show information and messages sent by this station")
                }
                #endif
                Spacer(minLength: 0)
            }

            if let session = viewModel.session {
                HStack(spacing: 8) {
                    Text(session.station.type.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(typeColor(for: session.station.type).opacity(0.15))
                        .foregroundStyle(typeColor(for: session.station.type))
                        .clipShape(Capsule())

                    if session.station.nodeNumber > 0 {
                        Text("Node \(session.station.nodeNumber)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(connectionStateColor)
                    .frame(width: 8, height: 8)
                    .opacity(viewModel.isConnected ? 1 : 0.5)

                Text(connectionStateText)
                    .font(.subheadline)
                    .foregroundStyle(connectionStateColor)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Compact header used by the iPad split layout. The radio and message
    /// panes need the vertical space, so the station metadata and connection
    /// state share one row instead of stacking three rows above the divider.
    private var tabletStationHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text(viewModel.stationCallsign.isEmpty ? "Connecting..." : viewModel.stationCallsign)
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    #if !targetEnvironment(macCatalyst)
                    if hasStationActivity {
                        Button {
                            showStationActivity = true
                        } label: {
                            Image(systemName: "text.bubble.fill")
                                .font(.body)
                                .padding(7)
                                .background(Color.accentColor.opacity(0.14), in: Circle())
                        }
                        .accessibilityLabel("Station messages")
                    }
                    #endif
                }

                if let session = viewModel.session {
                    HStack(spacing: 7) {
                        Text(session.station.type.displayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(typeColor(for: session.station.type).opacity(0.15))
                            .foregroundStyle(typeColor(for: session.station.type))
                            .clipShape(Capsule())

                        if session.station.nodeNumber > 0 {
                            Text("Node \(session.station.nodeNumber)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Circle()
                    .fill(connectionStateColor)
                    .frame(width: 8, height: 8)
                    .opacity(viewModel.isConnected ? 1 : 0.5)
                Text(connectionStateText)
                    .font(.subheadline)
                    .foregroundStyle(connectionStateColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasStationActivity: Bool {
        !viewModel.sysopInfo.isEmpty || viewModel.hasIncomingMessages
    }

    private var stationActivitySheet: some View {
        NavigationStack {
            List {
                if !viewModel.sysopInfo.isEmpty {
                    Section("Station information") {
                        Text(viewModel.sysopInfo)
                            .textSelection(.enabled)
                    }
                }
                if !viewModel.chatMessages.isEmpty {
                    Section("Messages") {
                        ForEach(viewModel.chatMessages) { message in
                            ChatBubble(message: message)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Station activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showStationActivity = false }
                }
            }
        }
    }

    private var participantsSheet: some View {
        NavigationStack {
            List(viewModel.activeNodeParticipants) { participant in
                HStack(spacing: 10) {
                    Image(systemName: participant.isTransmitting ? "waveform" : "person")
                        .foregroundStyle(participant.isTransmitting ? .green : .secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(participant.callsign)
                            .font(.body.monospaced().weight(.semibold))
                        if let displayName = participant.displayName,
                           displayName != participant.callsign {
                            Text(displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    if participant.isTransmitting {
                        Text("Talking")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Participants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showParticipants = false }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var participantSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showParticipants = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2")
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.activeNodeParticipants.count) on node")
                        .font(.subheadline.weight(.medium))
                    if let talking = viewModel.activeNodeParticipants.first, talking.isTransmitting {
                        Text("· \(talking.callsign) talking")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Show all participants on this node")

            VStack(alignment: .leading, spacing: 7) {
                ForEach(viewModel.activeNodeParticipants) { participant in
                    HStack(spacing: 8) {
                        Image(systemName: participant.isTransmitting ? "waveform" : "person")
                            .foregroundStyle(participant.isTransmitting ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(participant.callsign)
                                .font(.caption.monospaced().weight(.semibold))
                            if let name = participant.displayName, name != participant.callsign {
                                Text(name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var levelMeters: some View {
        QSOMeters(txLevel: viewModel.inputLevel,
                  rxLevel: viewModel.outputLevel,
                  isTransmitting: viewModel.isPTTActive,
                  isMuted: viewModel.isMuted)
    }

    // MARK: - Messages and Radio Controls

    private func radioControls(pttSize: CGFloat) -> some View {
        VStack(spacing: 6) {
            levelMeters
                .padding(.horizontal, 20)

            PTTButton(
                isActive: $viewModel.isPTTActive,
                isEnabled: viewModel.canTransmit || viewModel.isPTTActive,
                size: pttSize
            ) { active in
                viewModel.togglePTT(active: active)
            }

            Text(viewModel.isSendingDTMF ? "Sending DTMF" : viewModel.isPTTActive ? "Transmitting"
                 : viewModel.isRemoteTransmitting ? "Receiving · wait to talk" : "Hold to talk")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 18)

#if targetEnvironment(macCatalyst)
            chatComposer
                .padding(.horizontal, 12)
#endif

            controlBar
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
#if targetEnvironment(macCatalyst)
        .background(.regularMaterial)
#endif
    }

    private var chatComposer: some View {
        HStack(spacing: 8) {
            TextField("Message station", text: $chatDraft)
                #if targetEnvironment(macCatalyst)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                #else
                .textFieldStyle(.roundedBorder)
                #endif
                .focused($isChatFocused)
                .onSubmit { sendInlineChat() }

            Button(action: sendInlineChat) {
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor, in: Circle())
            }
            .disabled(chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send message")
            .buttonStyle(.plain)
        }
    }

    private func sendInlineChat() {
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatDraft = ""
        Task { await viewModel.sendChat(message: text) }
    }

    #if targetEnvironment(macCatalyst)
    private var canStartSpacePTT: Bool {
        isSpacePTTVisible && scenePhase == .active && !showChat && !showAudioRoutes && !showAudioDiagnostics
            && !showDTMF && !showStationActivity && !showParticipants
            && !showDisconnectConfirmation && viewModel.errorMessage == nil
            && !isChatFocused && !isParticipantSearchFocused
            && !viewModel.isPTTActive && viewModel.canTransmit
    }

    private func releaseSpacePTT() {
        guard isSpacePTTActive else { return }
        SpacePTTReleaseMonitor.shared.release(spacePTTOwner)
        isSpacePTTActive = false
        viewModel.togglePTT(active: false)
    }
    #endif

    private var connectingIndicator: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Connecting...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if viewModel.canCancelConnection {
                Button("Cancel", role: .cancel) {
                    viewModel.cancelConnection()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("qso.cancelConnection")
                .accessibilityHint("Stop connecting and return to the station list")
            }
        }
    }

    private var disconnectedIndicator: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("73 de \(viewModel.localCallsign)")
                .font(.system(.title3, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)
            if let candidate = viewModel.reconnectCandidate {
                Button {
                    Task { await viewModel.reconnect() }
                } label: {
                    Label("Reconnect to \(candidate.callsign)", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isReconnecting)
                .accessibilityHint("Refreshes the EchoLink directory and retries this station once")
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 4) {
            controlButton(
                icon: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: viewModel.isMuted ? "Unmute" : "Mute",
                tint: viewModel.isMuted ? .orange : .primary
            ) {
                viewModel.toggleMute()
            }

            controlButton(icon: "message.fill", label: "Chat", tint: .primary) {
                showChat = true
            }

            controlButton(icon: "airplayaudio", label: "Audio", tint: .primary) {
                showAudioRoutes = true
            }

            if supportsRemotePad {
                controlButton(icon: "circle.grid.3x3.fill", label: "DTMF", tint: .primary) {
                    showDTMF = true
                }
            }

            controlButton(icon: "phone.down.fill", label: "End", tint: .red) {
                showDisconnectConfirmation = true
            }
        }
        .padding(.horizontal, 8)
    }

    private var audioRouteSheet: some View {
        NavigationStack {
            Form {
                Section("Receive Audio") {
                    Label(viewModel.usesWatchAudioOutput ? "Apple Watch" : viewModel.audioOutputRouteName,
                          systemImage: viewModel.usesWatchAudioOutput ? "applewatch" : "speaker.wave.2")
                }

                if let audioStatusMessage = visibleAudioStatusMessage {
                    Section("Audio Status") {
                        Label {
                            Text(audioStatusMessage)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.orange)
                    }
                }

                Section("Transmit Audio") {
                    if MicrophoneAccess.status != .granted {
                        MicrophonePermissionControl(isEmbeddedInSettings: true) {
                            connectionService.prepareMicrophoneAfterPermissionGrant()
                        }
                    }
                    Picker("Microphone", selection: Binding(
                        get: { viewModel.selectedAudioInputDeviceID ?? "" },
                        set: { viewModel.setAudioInputDevice(id: $0.isEmpty ? nil : $0) }
                    )) {
                        Text("System Automatic").tag("")
                        ForEach(viewModel.audioInputDevices) { device in Text(device.name).tag(device.id) }
                        if let selected = viewModel.selectedAudioInputDeviceID,
                           !viewModel.audioInputDevices.contains(where: { $0.id == selected }) {
                            Text("Saved microphone — disconnected").tag(selected)
                        }
                    }
                }

#if targetEnvironment(macCatalyst)
                Section {
                    Button("Open Sound Settings") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else { return }
                        UIApplication.shared.open(url)
                    }
                }
#else
                Section("Built-in Audio") {
                    routeChoice("Speaker", preference: .speaker, icon: "speaker.wave.2")
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        routeChoice("Handset", preference: .receiver, icon: "iphone")
                    }
                    routeChoice("System Default", preference: .system, icon: "checkmark.circle")
                }

                Section("Bluetooth and Other Devices") {
                    HStack {
                        Text("Choose Device")
                        Spacer()
                        SystemAudioRoutePicker()
                            .frame(width: 40, height: 36)
                            .accessibilityLabel("Choose audio device")
                    }
                }
                if viewModel.watchAudioOutputAvailable || viewModel.usesWatchAudioOutput {
                    Section {
                        Button { viewModel.setWatchAudioOutput(true) } label: {
                            HStack {
                                Label("Apple Watch", systemImage: "applewatch")
                                Spacer()
                                if viewModel.usesWatchAudioOutput { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(!viewModel.watchAudioOutputAvailable)
                    }
                }
#endif
                if showAudioStats {
                    Section {
                        NavigationLink {
                            QSOAudioDiagnosticsView(connectionService: connectionService)
                        } label: {
                            Label("Audio Stats", systemImage: "waveform.path.ecg")
                        }
                    }
                }
            }
            .navigationTitle("Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAudioRoutes = false }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var dtmfSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    TextField("DTMF digits", text: $dtmfDraft)
                        .font(.title2.monospacedDigit())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: dtmfDraft) { _, value in
                            let allowed = "0123456789ABCD*#"
                            let normalized = String(value.uppercased().filter { allowed.contains($0) }
                                .prefix(EchoLinkDTMFToneGenerator.maximumDigitCount))
                            if dtmfDraft != normalized { dtmfDraft = normalized }
                        }
                        .accessibilityLabel("DTMF digits")

                    Button {
                        if !dtmfDraft.isEmpty { dtmfDraft.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Delete last digit")
                    .disabled(dtmfDraft.isEmpty)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(Array("123A456B789C*0#D").map(String.init), id: \.self) { digit in
                        Button {
                            if dtmfDraft.count < EchoLinkDTMFToneGenerator.maximumDigitCount {
                                dtmfDraft += digit
                            }
                        } label: {
                            Text(digit)
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .buttonStyle(.bordered)
                        .disabled(dtmfDraft.count >= EchoLinkDTMFToneGenerator.maximumDigitCount)
                    }
                }

                HStack {
                    Button("Clear") { dtmfDraft = "" }
                        .disabled(dtmfDraft.isEmpty)
                    Spacer()
                    Text("\(dtmfDraft.count)/\(EchoLinkDTMFToneGenerator.maximumDigitCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    viewModel.sendRemoteDTMF(dtmfDraft)
                    dtmfDraft = ""
                    showDTMF = false
                } label: {
                    Label("Send Tones", systemImage: "waveform")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!validDTMFDraft || !viewModel.canSendRemoteDTMF)

                if viewModel.session?.station.type == .conference {
                    Text("The remote pad is unavailable in conferences.")
                        .foregroundStyle(.secondary)
                } else if viewModel.session?.station.type == .user {
                    Text("The remote pad is for links and repeaters.")
                        .foregroundStyle(.secondary)
                } else if !viewModel.remotePadAllowed {
                    Text("The remote station has not enabled EchoLink's remote pad.")
                        .foregroundStyle(.secondary)
                } else if !viewModel.canSendRemoteDTMF {
                    Text("Wait for the channel and microphone PTT to become idle.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("DTMF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showDTMF = false }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var validDTMFDraft: Bool {
        !dtmfDraft.isEmpty
            && dtmfDraft.count <= EchoLinkDTMFToneGenerator.maximumDigitCount
            && dtmfDraft.allSatisfy { (try? EchoLinkDTMFToneGenerator.frequencies(for: $0)) != nil }
    }

    private var supportsRemotePad: Bool {
        guard let type = viewModel.session?.station.type else { return false }
        return (type == .link || type == .repeater) && viewModel.remotePadAllowed
    }

#if !targetEnvironment(macCatalyst)
    private func routeChoice(_ title: String, preference: AudioOutputPreference, icon: String) -> some View {
        Button {
            viewModel.setAudioOutputPreference(preference)
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if viewModel.audioOutputPreference == preference && !viewModel.usesWatchAudioOutput {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
#endif

    private func controlButton(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(tint == .primary ? .secondary : tint)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var visibleAudioStatusMessage: String? {
        guard let message = viewModel.audioStatusMessage,
              !message.hasPrefix("Preparing microphone") else { return nil }
        return message
    }

    private var audioStatusArea: some View {
        Group {
            if let message = visibleAudioStatusMessage {
                audioStatus(message)
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func audioStatus(_ message: String) -> some View {
        Button {
            showAudioRoutes = true
        } label: {
            Label {
                Text(message)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .font(.footnote)
        .foregroundStyle(.orange)
        .accessibilityLabel(message)
        .accessibilityHint("Open Audio for details and microphone access.")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var connectionStateText: String {
        guard let session = viewModel.session else { return "Idle" }
        switch session.state {
        case .connecting:    return "Connecting..."
        case .connected:     return "Connected"
        case .disconnecting: return "Disconnecting..."
        case .disconnected:  return "Disconnected"
        }
    }

    private var connectionStateColor: Color {
        guard let session = viewModel.session else { return .orange }
        switch session.state {
        case .connecting:    return .orange
        case .connected:     return .green
        case .disconnecting: return .orange
        case .disconnected:  return .red
        }
    }

    private func typeColor(for type: Station.StationType) -> Color {
        switch type {
        case .user:       return .orange
        case .link:       return .blue
        case .repeater:   return .green
        case .conference: return .purple
        }
    }
}
