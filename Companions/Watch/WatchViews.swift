// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

private enum WatchRoute: Hashable {
    case watchQSO
    case phoneQSO
    case directory
    case callCQ
    case login
    case settings
}

struct WatchRootView: View {
    @ObservedObject var model: WatchAppModel
    @ObservedObject private var connectionService: EchoLinkConnectionService
    @AppStorage("watch.permissions.onboarding.completed") private var microphoneOnboardingCompleted = false
    @State private var path: [WatchRoute] = []

    init(model: WatchAppModel) {
        self.model = model
        _connectionService = ObservedObject(wrappedValue: model.connectionService)
    }

    var body: some View {
        Group {
            if !microphoneOnboardingCompleted {
                WatchMicrophoneOnboarding {
                    microphoneOnboardingCompleted = true
                }
            } else {
                NavigationStack(path: $path) {
                    WatchHomeView(model: model, connectionService: connectionService, directoryService: model.directoryService)
                        .navigationTitle("ReverbQSO")
                        .navigationDestination(for: WatchRoute.self) { route in
                            switch route {
                            case .watchQSO:
                                WatchQSOView(model: model, service: connectionService)
                                    .navigationTitle("On Watch")
                            case .phoneQSO:
                                WatchPhoneQSOView(model: model)
                                    .navigationTitle("On iPhone")
                            case .directory:
                                WatchDirectoryView(model: model, service: model.directoryService)
                                    .navigationTitle("Stations")
                            case .callCQ:
                                WatchCallCQView(model: model)
                                    .navigationTitle("Call CQ")
                            case .login:
                                WatchLoginView(model: model)
                                    .navigationTitle("Sign In")
                            case .settings:
                                WatchSettingsView(model: model)
                                    .navigationTitle("Settings")
                            }
                        }
                }
                .onChange(of: path) { _, newPath in
                    var seenQSORoutes = Set<WatchRoute>()
                    let deduplicatedPath = newPath.filter { route in
                        switch route {
                        case .watchQSO, .phoneQSO:
                            return seenQSORoutes.insert(route).inserted
                        default:
                            return true
                        }
                    }
                    if deduplicatedPath != newPath {
                        path = deduplicatedPath
                    }
                }
            }
        }
        .task { reconcileRoutes() }
        .onChange(of: connectionService.session?.state) { _, _ in reconcileRoutes() }
        .onChange(of: model.companionStatus.connected) { _, _ in reconcileRoutes() }
    }

    private func reconcileRoutes() {
        let watchConnected = connectionService.session?.state == .connected
        let phoneConnected = model.companionStatus.connected
        if !watchConnected {
            path.removeAll { $0 == .watchQSO }
        }
        if !phoneConnected {
            path.removeAll { $0 == .phoneQSO }
        }
        // Keep the QSO the operator selected visible when both devices have
        // calls; never push a second QSO on top of the first one.
        if path.contains(.watchQSO) || path.contains(.phoneQSO) { return }
        if watchConnected {
            path.append(.watchQSO)
        } else if phoneConnected {
            path.append(.phoneQSO)
        }
    }
}

private struct WatchMicrophoneOnboarding: View {
    let onContinue: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var microphoneStatus: MicrophoneAuthorizationState = .notDetermined

    var body: some View {
        VStack(spacing: 6) {
            Label("Talk on Watch", systemImage: "mic.fill")
                .font(.headline)
                .foregroundStyle(.primary)
            if microphoneStatus == .notDetermined {
                Button {
                    Task {
                        _ = await MicrophoneAccess.request()
                        microphoneStatus = MicrophoneAccess.status
                    }
                } label: {
                    Text("Allow Mic")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(.white)
                        .background(.tint, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Microphone lets you transmit from Watch.")
            } else if microphoneStatus == .granted {
                Label("Microphone ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Microphone is off. Change it in Watch Settings to transmit.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(action: onContinue) {
                Text("Continue")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.gray.opacity(0.3), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Microphone access can be changed later in Settings.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            microphoneStatus = MicrophoneAccess.status
        }
    }
}

private struct WatchHomeView: View {
    @ObservedObject var model: WatchAppModel
    @ObservedObject var connectionService: EchoLinkConnectionService
    @ObservedObject var directoryService: EchoLinkDirectoryService

    var body: some View {
        List {
            if let error = model.connectionError {
                Text(error).foregroundStyle(.orange).font(.caption)
            }

            if !model.isWatchLoggedIn && !model.canUsePhone {
                Section {
                    Text(model.isCompanionReachable
                         ? "Sign in on iPhone to sync your stations"
                         : "Sign in here to use Watch on its own")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Sign in on Watch", value: WatchRoute.login)
                }
            }

            if connectionService.session != nil || model.companionStatus.connected {
                Section("Now") {
                    if let session = connectionService.session {
                        NavigationLink(value: WatchRoute.watchQSO) {
                            activeRow(session.station.callsign, destination: "On Watch", icon: "applewatch")
                        }
                    }
                    if model.companionStatus.connected {
                        NavigationLink(value: WatchRoute.phoneQSO) {
                            activeRow(model.companionStatus.callsign, destination: "On iPhone", icon: "iphone")
                        }
                    }
                }
            }

            if !model.phoneFavorites.isEmpty || model.isWatchLoggedIn {
                Section("Favorites") {
                    if model.phoneFavorites.isEmpty {
                        Text("Favorite stations from iPhone appear here")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.phoneFavorites.prefix(12)) { station in
                            WatchStationRow(model: model, station: station, savedStation: true)
                        }
                    }
                }
            }

            if !model.recentStations.isEmpty || model.isWatchLoggedIn {
                Section("Recent") {
                    if model.recentStations.isEmpty {
                        Text("Stations you used recently appear here")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.recentStations.prefix(12)) { station in
                            WatchStationRow(model: model, station: station, savedStation: true)
                        }
                    }
                }
            }

            Section {
                if model.isWatchLoggedIn {
                    NavigationLink("Call CQ", value: WatchRoute.callCQ)
                        .disabled(model.hasWatchSession)
                    NavigationLink("Search stations", value: WatchRoute.directory)
                }
                NavigationLink("Settings", value: WatchRoute.settings)
            }
        }
        #if os(watchOS)
        .listStyle(.carousel)
        #else
        .listStyle(.plain)
        #endif
    }

    private func activeRow(_ callsign: String, destination: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.green)
            VStack(alignment: .leading) {
                Text(callsign).font(.headline.monospaced()).lineLimit(1)
                Text(destination).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct WatchStationRow: View {
    @ObservedObject var model: WatchAppModel
    let station: Station
    let savedStation: Bool

    var body: some View {
        Group {
            if model.companionStatus.connected && model.companionStatus.callsign.caseInsensitiveCompare(station.callsign) == .orderedSame {
                NavigationLink(value: WatchRoute.phoneQSO) { rowLabel }
            } else if let session = model.connectionService.session,
                      session.station.callsign.caseInsensitiveCompare(station.callsign) == .orderedSame {
                NavigationLink(value: WatchRoute.watchQSO) { rowLabel }
            } else {
                Button {
                    Task { await model.connect(to: station, savedStation: savedStation) }
                } label: {
                    rowLabel
                }
                .disabled(model.preferredDestination(for: station) == nil)
            }
        }
        .contextMenu {
            if model.canUsePhone {
                Button("Connect on iPhone", systemImage: "iphone") {
                    Task { await model.connect(to: station, destination: .iPhone, savedStation: savedStation) }
                }
            }
            if model.isWatchLoggedIn {
                Button("Connect on Watch", systemImage: "applewatch") {
                    Task { await model.connect(to: station, destination: .onWatch, savedStation: savedStation) }
                }
            }
        }
        .accessibilityHint("Connects \(destinationLabel). Long press to choose the other device.")
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(station.callsign).font(.headline.monospaced()).lineLimit(1)
                Text(destinationLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let destination = model.preferredDestination(for: station) {
                Image(systemName: destination == .iPhone ? "iphone" : "applewatch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationLabel: String {
        switch model.preferredDestination(for: station) {
        case .iPhone: "Connect on iPhone"
        case .onWatch: "Connect on Watch"
        case nil: model.isCompanionReachable ? "Sign in to connect" : "iPhone unavailable · sign in on Watch"
        }
    }
}

private struct WatchLoginView: View {
    @ObservedObject var model: WatchAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Sign in on Watch")
                    .font(.headline)
                Text("Use your EchoLink callsign. Your iPhone account syncs automatically when available.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextField("Callsign", text: $model.callsign)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                SecureField("Password", text: $model.password)
                    .textContentType(.password)

                if let loginError = model.loginError {
                    Label(loginError, systemImage: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await model.login() }
                } label: {
                    if model.isLoggingIn {
                        ProgressView()
                    } else {
                        Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .disabled(model.isLoggingIn || model.callsign.isEmpty || model.password.isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .onChange(of: model.isWatchLoggedIn) { _, loggedIn in
            if loggedIn && model.loginError == nil { dismiss() }
        }
    }
}

private struct WatchPhoneQSOView: View {
    @ObservedObject var model: WatchAppModel
    @State private var confirmsDisconnect = false

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Text(model.companionStatus.callsign.isEmpty ? "iPhone QSO" : model.companionStatus.callsign)
                    .font(.headline.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(!model.companionStatus.connected ? "iPhone QSO ended"
                     : model.companionStatus.isRemoteTransmitting ? "Receiving — wait to transmit"
                     : model.companionStatus.isTransmitting ? "Transmitting" : "Connected on iPhone")
                    .font(.caption)
                    .foregroundStyle(model.companionStatus.isRemoteTransmitting ? .orange : .secondary)

                if !model.isCompanionReachable {
                    Label("iPhone unavailable", systemImage: "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                WatchPTTControl(
                    isEnabled: model.phoneCanTransmit && model.isCompanionReachable,
                    isTransmitting: model.companionStatus.isTransmitting,
                    begin: { model.beginPTT(on: .iPhone) },
                    end: model.endPTT
                )

                if let message = model.companionMessage {
                    Text(message).font(.caption2).foregroundStyle(.orange)
                }
                Button {
                    confirmsDisconnect = true
                } label: {
                    Label("End QSO", systemImage: "phone.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .disabled(!model.isCompanionReachable)
            }
        }
        .confirmationDialog("Disconnect iPhone QSO?", isPresented: $confirmsDisconnect) {
            Button("Disconnect", role: .destructive) { model.disconnectPhoneSession() }
            Button("Keep Listening", role: .cancel) {}
        }
    }
}

private struct WatchSettingsView: View {
    @ObservedObject var model: WatchAppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MicrophoneGainSettings.modeKey) private var microphoneGainMode = MicrophoneGainMode.automatic.rawValue
    @AppStorage(MicrophoneGainSettings.key) private var microphoneGain = 1.0
    @State private var microphoneStatus: MicrophoneAuthorizationState = .notDetermined

    var body: some View {
        List {
            Section("Permissions") {
                Text(microphoneStatus == .granted ? "Microphone allowed" : microphoneStatus == .denied ? "Microphone off" : "Microphone not asked")
                    .foregroundStyle(microphoneStatus == .granted ? .green : .secondary)
                if microphoneStatus == .notDetermined {
                    Button("Allow Microphone") {
                        Task {
                            _ = await MicrophoneAccess.request()
                            microphoneStatus = MicrophoneAccess.status
                        }
                    }
                } else if microphoneStatus == .denied {
                    Text("Enable microphone access in Watch Settings to transmit.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Watch audio") {
                Picker("Mic gain", selection: $microphoneGainMode) {
                    Text("Automatic").tag(MicrophoneGainMode.automatic.rawValue)
                    Text("Manual").tag(MicrophoneGainMode.manual.rawValue)
                }
                if microphoneGainMode == MicrophoneGainMode.manual.rawValue {
                    Slider(value: $microphoneGain,
                           in: MicrophoneGainSettings.minimum...MicrophoneGainSettings.maximum,
                           step: 0.05) {
                        Text("Mic gain")
                    }
                    Text(String(format: "%.2f×", microphoneGain))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("For calls made on Watch. iPhone calls use the iPhone's audio setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Watch network") {
                Button("Automatic") { model.networkMode = .automatic }
                    .foregroundStyle(model.networkMode == .automatic ? .green : .primary)
                Button("Direct") { model.networkMode = .direct }
                    .foregroundStyle(model.networkMode == .direct ? .green : .primary)
                Button("Public Proxy") { model.networkMode = .publicProxy }
                    .foregroundStyle(model.networkMode == .publicProxy ? .green : .primary)
                if let effective = model.directoryService.effectiveTransport {
                    Text("Current: \(effective.configuration.mode.title)")
                        .font(.caption)
                }
                Text("Changes apply the next time you sign in on Watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Recording") {
                RecordingSettingsRows(demo: model.connectionService.isLocalDemoMode)
            }
            Section("Calls") {
                NavigationLink("Recordings") {
                    RecordingsView(demo: model.connectionService.isLocalDemoMode)
                }
                NavigationLink("Call Restrictions") {
                    CallRestrictionsView(demo: model.connectionService.isLocalDemoMode)
                }
            }
            if model.isWatchLoggedIn {
                Button("Sign Out", role: .destructive) {
                    Task { await model.signOut() }
                }
            }
        }
        #if os(watchOS)
        .listStyle(.carousel)
        #else
        .listStyle(.plain)
        #endif
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            microphoneStatus = MicrophoneAccess.status
        }
    }
}

private struct WatchDirectoryView: View {
    @ObservedObject var model: WatchAppModel
    @ObservedObject var service: EchoLinkDirectoryService

    var body: some View {
        List {
            HStack {
                TextField("Search", text: Binding(
                    get: { service.searchText },
                    set: { service.search(query: $0) }
                ))
                if service.isLoading { ProgressView().controlSize(.mini) }
            }
            if let error = service.error {
                Text(error.localizedDescription)
                    .font(.caption).foregroundStyle(.orange)
            }

            ForEach(Array(service.filteredStations.prefix(60))) { station in
                WatchStationRow(model: model, station: station, savedStation: false)
                    .disabled(station.isBusy)
            }
        }
        #if os(watchOS)
        .listStyle(.carousel)
        #else
        .listStyle(.plain)
        #endif
    }
}

private struct WatchQSOView: View {
    @ObservedObject var model: WatchAppModel
    @ObservedObject var service: EchoLinkConnectionService
    @State private var confirmsDisconnect = false

    var body: some View {
        ScrollView {
          VStack(spacing: 8) {
            if let session = service.session {
                Text(session.station.callsign)
                    .font(.headline.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(statusText(for: session))
                    .font(.caption)
                    .foregroundStyle(service.isRemoteTransmitting ? .orange : .secondary)
            }

            HStack(spacing: 12) {
                meter(title: "RX", level: service.outputLevel, tint: .green)
                meter(title: "TX", level: service.inputLevel, tint: .red)
            }

            WatchPTTControl(
                isEnabled: service.canTransmit,
                isTransmitting: service.session?.isPTTActive == true,
                begin: { model.beginPTT(on: .onWatch) },
                end: model.endPTT
            )

            Button(service.isRecording ? "Stop Clip" : "Record Clip",
                   systemImage: service.isRecording ? "stop.circle.fill" : "record.circle") {
                service.toggleRecording()
            }
            .font(.caption)
            .buttonStyle(.bordered)

            if service.isAutomaticallyRecording {
                Label(service.isRecording ? "Automatically recording + clip" : "Automatically recording",
                      systemImage: "record.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if service.isRecording {
                Label("Recording clip", systemImage: "record.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if let message = service.audioStatusMessage {
                Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }

            Button {
                confirmsDisconnect = true
            } label: {
                Label("End QSO", systemImage: "phone.down")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
          }
        }
        .confirmationDialog("Disconnect Watch QSO?", isPresented: $confirmsDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task { await model.disconnectOnWatch() }
            }
            Button("Keep Listening", role: .cancel) {}
        }
    }

    private func statusText(for session: QSOSession) -> String {
        switch session.state {
        case .connecting: "Connecting…"
        case .connected where service.isRemoteTransmitting: "Receiving — wait to transmit"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting…"
        case .disconnected: "Disconnected"
        }
    }

    private func meter(title: String, level: Double, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            ProgressView(value: level).tint(tint)
        }
    }
}

private struct WatchCallCQView: View {
    @ObservedObject var model: WatchAppModel
    @State private var preferences = CallCQPreferences.default

    var body: some View {
        Group {
            if let service = model.callCQService {
                WatchCallCQStateView(model: model, service: service)
            } else {
                List {
                    Picker("Language", selection: language) {
                        Text("English").tag("en")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Italian").tag("it")
                        Text("Portuguese").tag("pt")
                        Text("Japanese").tag("ja")
                    }
                    Picker("Country", selection: country) {
                        Text("Accept Any").tag("")
                        ForEach(Locale.Region.isoRegions.map(\.identifier).sorted(), id: \.self) { code in
                            Text(Locale.current.localizedString(forRegionCode: code) ?? code).tag(code)
                        }
                    }
                    Toggle("Users", isOn: nodeType(.user))
                    Toggle("Links", isOn: nodeType(.link))
                    Toggle("Repeaters", isOn: nodeType(.repeater))
                    Toggle("Skip recent", isOn: $preferences.avoidRecentContacts)
                    Button("Call CQ", systemImage: "dot.radiowaves.left.and.right") {
                        model.beginCallCQ(preferences: preferences)
                    }
                    .disabled(preferences.nodeTypes.isEmpty)
                }
            }
        }
        .onDisappear {
            guard model.callCQService != nil else { return }
            Task { await model.cancelCallCQ() }
        }
    }

    private var language: Binding<String> {
        Binding(get: { preferences.languageCodes.first ?? "en" },
                set: { preferences.languageCodes = [$0] })
    }

    private var country: Binding<String> {
        Binding(get: { preferences.countryCodes.first ?? "" },
                set: { preferences.countryCodes = $0.isEmpty ? [] : [$0] })
    }

    private func nodeType(_ type: Station.StationType) -> Binding<Bool> {
        Binding(get: { preferences.nodeTypes.contains(type) }, set: { enabled in
            if enabled { preferences.nodeTypes.insert(type) } else { preferences.nodeTypes.remove(type) }
        })
    }
}

private struct WatchCallCQStateView: View {
    @ObservedObject var model: WatchAppModel
    @ObservedObject var service: CallCQService

    var body: some View {
        switch service.state {
        case .idle:
            ProgressView()
        case .waiting:
            VStack(spacing: 10) {
                ProgressView()
                Text("Calling CQ…").font(.headline)
                Text("Waiting for a matching station").font(.caption2).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { Task { await model.cancelCallCQ() } }
            }
        case .matched(let station):
            ProgressView("Connecting to \(station.callsign)…")
                .task { await model.connectToCallCQMatch(station) }
        case .failed(let message):
            VStack(spacing: 8) {
                Label("CQ Unavailable", systemImage: "exclamationmark.triangle")
                Text(message).font(.caption2).foregroundStyle(.secondary)
                Button("Back") { Task { await model.cancelCallCQ() } }
            }
        }
    }
}

private struct WatchPTTControl: View {
    let isEnabled: Bool
    let isTransmitting: Bool
    let begin: () -> Bool
    let end: () -> Void
    @State private var didBegin = false
    @GestureState private var isPressed = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: isTransmitting ? "mic.fill" : "mic")
                .font(.system(size: 34, weight: .semibold))
            Text(isTransmitting ? "TRANSMITTING" : "HOLD PTT")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: 112, height: 112)
        .background(isTransmitting ? Color.red : isEnabled ? Color.green : Color.gray.opacity(0.45))
        .clipShape(Circle())
        .scaleEffect(isPressed ? 0.94 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .contentShape(Circle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, pressed, _ in
                    pressed = true
                }
        )
        .onChange(of: isPressed) { _, pressed in
            if pressed {
                guard !didBegin, isEnabled else { return }
                didBegin = begin()
            } else if didBegin {
                didBegin = false
                end()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(isTransmitting ? "Transmitting" : "Push to Talk")
        .accessibilityHint(isEnabled ? "Press and hold to transmit. Release to stop." : "Push to talk is currently unavailable.")
        .accessibilityAddTraits(.isButton)
        .onChange(of: isEnabled) { _, enabled in
            guard !enabled, didBegin else { return }
            didBegin = false
            end()
        }
        .onDisappear {
            guard didBegin else { return }
            didBegin = false
            end()
        }
    }
}
