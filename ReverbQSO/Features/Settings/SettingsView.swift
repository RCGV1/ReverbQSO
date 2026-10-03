// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var showPersonalStation: Bool
    @AppStorage(MicrophoneGainSettings.modeKey) private var microphoneGainMode = MicrophoneGainMode.automatic.rawValue
    @AppStorage(MicrophoneGainSettings.key) private var microphoneGain = 1.0
    #if targetEnvironment(macCatalyst)
    @AppStorage(MacMessageNotifier.enabledKey) private var messageNotificationsEnabled = true
    #endif
    @StateObject private var viewModel = SettingsViewModel(loadSettings: false)
    @State private var showingAddAccount = false
    @State private var showingAccounts = false
    @State private var newCallsign = ""
    @State private var newPassword = ""
    @State private var isAddingAccount = false

    init(showPersonalStation: Binding<Bool> = .constant(false)) {
        _showPersonalStation = showPersonalStation
    }

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
            List {
                Section("Account") { accountContent }
                Section("My Station") {
                    PersonalStationSettingsRows(
                        host: appState.conferenceHostService,
                        showPersonalStation: $showPersonalStation
                    )
                }
                Section("Calls") { NavigationLink("Call Restrictions") { CallRestrictionsView(demo: appState.isDemoMode) } }
                Section("Audio") { audioContent }
                Section("Recording") { RecordingSettingsRows(demo: appState.isDemoMode) }
                Section("Notifications") { notificationContent }
                Section("Network") { connectionContent }
                Section("About") { aboutContent }
            }
            .listStyle(.insetGrouped)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .center)
            .navigationTitle("Settings")
            #else
            StandaloneNavigationContainer {
                List {
                    Section("Account") { accountContent }
                    Section("My Station") {
                        PersonalStationSettingsRows(
                            host: appState.conferenceHostService,
                            showPersonalStation: $showPersonalStation
                        )
                    }
                    Section("Calls") { NavigationLink("Call Restrictions") { CallRestrictionsView(demo: appState.isDemoMode) } }
                    Section("Audio") { audioContent }
                    Section("Recording") { RecordingSettingsRows(demo: appState.isDemoMode) }
                    Section("Network") { connectionContent }
                    Section("About") { aboutContent }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Settings")
            }
            #endif
        }
        .onAppear { viewModel.setDemoMode(appState.isDemoMode) }
        .onChange(of: appState.isDemoMode) { _, enabled in viewModel.setDemoMode(enabled) }
        .onChange(of: viewModel.networkMode) { _, _ in viewModel.scheduleProxySettingsSave() }
        .onChange(of: viewModel.selectedPublicProxyID) { _, _ in viewModel.scheduleProxySettingsSave() }
        .onChange(of: viewModel.proxyHost) { _, _ in viewModel.scheduleProxySettingsSave() }
        .onChange(of: viewModel.proxyPort) { _, _ in viewModel.scheduleProxySettingsSave() }
        .onChange(of: viewModel.proxyPassword) { _, _ in viewModel.scheduleProxySettingsSave() }
        .onDisappear { viewModel.flushPendingSettingsSave() }
        .task(id: viewModel.networkMode) {
            viewModel.setDemoMode(appState.isDemoMode)
            if viewModel.networkMode == .publicProxy && viewModel.publicProxies.isEmpty {
                await viewModel.refreshPublicProxies()
            }
        }
        .sheet(isPresented: $showingAccounts) { accountsSheet }
        .navigationDestination(isPresented: $showPersonalStation) {
            PersonalStationView(host: appState.conferenceHostService)
        }
        #if targetEnvironment(macCatalyst)
        .onChange(of: messageNotificationsEnabled) { _, enabled in
            if enabled { MacMessageNotifier.refreshAuthorization() }
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    @ViewBuilder private var notificationContent: some View {
        Toggle("Message alerts", isOn: $messageNotificationsEnabled)
        MacMessagePermissionControl(isEmbeddedInSettings: true)
    }
    #endif

    @ViewBuilder private var audioContent: some View {
        MicrophonePermissionControl(isEmbeddedInSettings: true)
        Picker("Microphone Gain", selection: $microphoneGainMode) {
            Text("Automatic").tag(MicrophoneGainMode.automatic.rawValue)
            Text("Manual").tag(MicrophoneGainMode.manual.rawValue)
        }

        if microphoneGainMode == MicrophoneGainMode.manual.rawValue {
            HStack(spacing: 12) {
                Slider(value: $microphoneGain,
                       in: MicrophoneGainSettings.minimum...MicrophoneGainSettings.maximum,
                       step: 0.05)
                    .accessibilityLabel("Microphone gain level")
                Text(String(format: "%.2f×", microphoneGain))
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
        } else {
            Text("Adjusts your microphone level while you transmit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var accountContent: some View {
            if appState.isLoggedIn {
                LabeledContent("Signed in as", value: appState.currentUser)
                Button {
                    showingAccounts = true
                } label: {
                    Label("Manage Accounts", systemImage: "person.2")
                }
                #if targetEnvironment(macCatalyst)
                .buttonStyle(.bordered)
                #endif
                Text("Station passwords are stored in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    private var accountsSheet: some View {
        NavigationStack {
            List {
                Section("Saved Stations") {
                    ForEach(appState.savedAccounts, id: \.self) { callsign in
                        Button {
                            Task {
                                await appState.switchAccount(to: callsign)
                                if appState.currentUser == callsign { showingAccounts = false }
                            }
                        } label: {
                            HStack {
                                Text(callsign).font(.body.monospaced())
                                Spacer()
                                if callsign == appState.currentUser {
                                    Label("Active", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(callsign == appState.currentUser)
                        .contextMenu {
                            Button("Remove Saved Account", role: .destructive) {
                                Task { await appState.removeSavedAccount(callsign) }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        newCallsign = ""
                        newPassword = ""
                        showingAddAccount = true
                    } label: {
                        Label("Add Account", systemImage: "person.crop.circle.badge.plus")
                    }
                    Button("Sign Out of \(appState.currentUser)", role: .destructive) {
                        Task {
                            await appState.logout()
                            showingAccounts = false
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingAccounts = false }
                }
            }
        }
        .sheet(isPresented: $showingAddAccount) { addAccountSheet }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 320, idealHeight: 420)
        #endif
    }

    private var addAccountSheet: some View {
        NavigationStack {
            Form {
                Section("Station Account") {
                    TextField("Callsign", text: $newCallsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SecureField("EchoLink Password", text: $newPassword)
                }
                if let error = appState.loginError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddAccount = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign In") {
                        isAddingAccount = true
                        Task {
                            await appState.login(callsign: newCallsign, password: newPassword)
                            isAddingAccount = false
                            if appState.loginError == nil {
                                newPassword = ""
                                showingAddAccount = false
                            }
                        }
                    }
                    .disabled(isAddingAccount || newCallsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newPassword.isEmpty)
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 280, idealHeight: 320)
        #endif
    }

    @ViewBuilder private var connectionContent: some View {
            Picker("Connection Method", selection: $viewModel.networkMode) {
                ForEach(EchoLinkNetworkMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            if let transport = appState.directoryService.effectiveTransport {
                LabeledContent("Current Connection", value: transport.configuration.mode.title)
                Text("Connection method changes take effect the next time this account signs in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.networkMode == .automatic {
                Text("Automatic selects a connection method when you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.networkMode == .publicProxy {
                Picker("Proxy Server", selection: $viewModel.selectedPublicProxyID) {
                    Text("Automatic").tag("")
                    ForEach(viewModel.publicProxies.filter(\.isReady)) { proxy in
                        Text(proxy.name).tag(proxy.id)
                    }
                }
                Button(viewModel.isLoadingPublicProxies ? "Refreshing…" : "Refresh Server List") {
                    Task { await viewModel.refreshPublicProxies() }
                }
                .disabled(viewModel.isLoadingPublicProxies)
            } else if viewModel.networkMode == .customProxy {
                TextField("Server Address", text: $viewModel.proxyHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $viewModel.proxyPort)
                    .keyboardType(.numberPad)
                SecureField("Proxy Password", text: $viewModel.proxyPassword)
                if viewModel.activeNetworkMode != .customProxy {
                    Text("Complete these details to activate your custom proxy. Until then, \(viewModel.activeNetworkMode.title) stays active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let proxySettingsError = viewModel.proxySettingsError {
                Text(proxySettingsError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(connectionModeExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
    }

    private var connectionModeExplanation: String {
        switch viewModel.networkMode {
        case .automatic:
            return "Use Direct when a public local address is available; otherwise discover a relay, with Public Proxy as fallback."
        case .direct:
            return "Connect to stations directly. If calls time out, try Public Proxy."
        case .relay:
            return "Route calls through an EchoLink relay when direct connections are blocked."
        case .publicProxy:
            return "A public proxy is selected automatically unless you choose a server above."
        case .customProxy:
            return "Use a proxy provided by your station or network administrator."
        }
    }

    @ViewBuilder private var aboutContent: some View {
            LabeledContent("Version", value: viewModel.appVersion)
            Link("Source Code", destination: viewModel.githubURL)
            NavigationLink("Licenses") { LicensesView() }
    }

}

private struct PersonalStationSettingsRows: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var host: EchoLinkConferenceHostService
    @Binding var showPersonalStation: Bool
    @State private var confirmsStopListening = false

    private var activeCall: InboundHostSession? {
        host.sessions.first { $0.state == .active }
    }

    private var status: String {
        if let activeCall { return "In a call with \(activeCall.callsign)" }
        if let pending = host.pendingCall { return "\(pending.callsign) is calling" }
        if host.isStarting { return "Starting…" }
        if host.isStopping { return "Stopping…" }
        if host.isRunning { return host.isPersonalMode ? "Available for calls" : "Conference hosting" }
        return "Not receiving calls"
    }

    var body: some View {
        LabeledContent("Incoming calls", value: status)

        if activeCall != nil || host.pendingCall != nil {
            Button {
                showPersonalStation = true
            } label: {
                Label(activeCall == nil ? "Answer or Decline" : "Open Current Call",
                      systemImage: "phone.arrow.down.left")
            }
        } else if host.isRunning && !host.isPersonalMode {
            Text("Conference hosting is active. Manage it from Conference Host.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button {
                if host.isRunning {
                    confirmsStopListening = true
                } else {
                    Task { await appState.startPersonalCalls() }
                }
            } label: {
                Label(host.isRunning ? "Stop Receiving Calls" : "Become Available",
                      systemImage: host.isRunning ? "phone.down" : "phone.arrow.down.left")
            }
            .disabled(host.isStarting || host.isStopping || (!host.isRunning && !appState.qsoHub.entries.isEmpty))
            .confirmationDialog("Stop receiving calls?", isPresented: $confirmsStopListening) {
                Button("Stop Receiving Calls", role: .destructive) {
                    Task { await appState.stopPersonalCalls() }
                }
                Button("Keep Available", role: .cancel) {}
            }

            if !host.isRunning && !appState.qsoHub.entries.isEmpty {
                Text("Finish your current QSO before receiving personal calls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                #if targetEnvironment(macCatalyst)
                Text("Keep this Mac open and reachable on UDP 5198 and 5199. Direct connection mode is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Text("Direct mode and reachable UDP 5198 and 5199 are required. This device receives calls only while the app is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
        }

        if let error = host.errorMessage, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
