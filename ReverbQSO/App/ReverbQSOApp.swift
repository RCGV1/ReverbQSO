// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct ReverbQSOApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("ReverbQSO") {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.directoryService)
                .environmentObject(appState.connectionService)
                .environmentObject(appState.qsoHub)
                .environmentObject(appState.favoritesViewModel)
                .environmentObject(appState.recentConnectionsService)
        }
        #if targetEnvironment(macCatalyst)
        .commands {
            MacRadioCommands(
                qsoHub: appState.qsoHub,
                conferenceHost: appState.conferenceHostService
            )
        }
        #endif
    }
}

private struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var qsoHub: QSOHub
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("permissions.onboarding.completed") private var permissionsOnboardingCompleted = false
    @State private var dismissedDemoPermissions = false
    @State private var showLinkedQSO = false
    @State private var showPersonalCall = false
    #if targetEnvironment(macCatalyst)
    @State private var pendingMacRoute: String?
    #endif

    var body: some View {
        Group {
            if shouldShowPermissionOnboarding {
                PermissionOnboardingView {
                    permissionsOnboardingCompleted = true
                    dismissedDemoPermissions = true
                }
            } else if appState.isLoggedIn {
                #if targetEnvironment(macCatalyst)
                MacSidebarView(showPersonalCall: $showPersonalCall)
                #else
                MainTabView(showLinkedQSO: $showLinkedQSO, showPersonalCall: $showPersonalCall)
                #endif
            } else {
                LoginView()
            }
        }
        .modifier(IncomingCallPrompt(host: appState.conferenceHostService) {
            showPersonalCall = true
        })
        .alert("Recording failed", isPresented: Binding(
            get: { qsoHub.recordingError != nil },
            set: { isPresented in
                if !isPresented { qsoHub.recordingError = nil }
            }
        )) {
            Button("OK", role: .cancel) {
                qsoHub.recordingError = nil
            }
        } message: {
            Text(qsoHub.recordingError ?? "The recording could not be saved.")
        }
        .onOpenURL { url in
            guard ["reverbqso", "openecholink"].contains(url.scheme) else { return }
            #if targetEnvironment(macCatalyst)
            guard let route = url.host else { return }
            if appState.isLoggedIn {
                openMacRoute(route)
            } else {
                pendingMacRoute = route
            }
            #else
            switch url.host {
            case "qso":
                if appState.qsoHub.activeService.session?.state == .connected {
                    showLinkedQSO = true
                }
            case "personal":
                showPersonalCall = true
            default:
                break
            }
            #endif
        }
        #if targetEnvironment(macCatalyst)
        .onChange(of: appState.isLoggedIn) { _, loggedIn in
            guard loggedIn, let route = pendingMacRoute else { return }
            pendingMacRoute = nil
            Task { @MainActor in
                await Task.yield()
                openMacRoute(route)
            }
        }
        #endif
        .task(id: scenePhase) {
            appState.setApplicationActive(scenePhase == .active)
            #if targetEnvironment(macCatalyst)
            if scenePhase == .active { MacMessageNotifier.refreshAuthorizationStatus() }
            #endif
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if scenePhase == .background {
                await appState.stopPersonalCalls()
            }
            #endif
        }
        .onReceive(appState.directoryService.$isLoggedIn) { loggedIn in
            if !loggedIn && appState.isLoggedIn {
                Task { await appState.handleCurrentDirectoryLogout() }
            }
        }
    }

    private var shouldShowPermissionOnboarding: Bool {
        #if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            return SimulatorDemoData.screen == "permissions" && !dismissedDemoPermissions
        }
        #endif
        return !permissionsOnboardingCompleted
    }

    #if targetEnvironment(macCatalyst)
    private func openMacRoute(_ route: String) {
        switch route {
        case "qso":
            guard appState.qsoHub.activeID != nil else { return }
            NotificationCenter.default.post(name: .openCurrentQSO, object: nil)
        case "settings":
            NotificationCenter.default.post(name: .openSettings, object: nil)
        case "directory":
            NotificationCenter.default.post(name: .openDirectory, object: nil)
        case "favorites":
            NotificationCenter.default.post(name: .openFavorites, object: nil)
        case "recents":
            NotificationCenter.default.post(name: .openRecents, object: nil)
        case "hosting":
            NotificationCenter.default.post(name: .openHosting, object: nil)
        case "personal":
            showPersonalCall = true
        default:
            break
        }
    }
    #endif
}

private struct IncomingCallPrompt: ViewModifier {
    @ObservedObject var host: EchoLinkConferenceHostService
    let onAnswer: () -> Void
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onReceive(host.$pendingCall) { call in
                isPresented = call != nil
            }
            .alert("Incoming EchoLink call", isPresented: $isPresented) {
                Button("Decline", role: .cancel) {
                    Task { await host.declinePendingCall() }
                }
                Button("Answer") {
                    Task {
                        await host.acceptPendingCall()
                        if host.sessions.contains(where: { $0.state == .active }) { onAnswer() }
                    }
                }
            } message: {
                Text("\(host.pendingCall?.callsign ?? "A station") is calling you.")
            }
    }
}

private struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var connectionService: EchoLinkConnectionService
    @EnvironmentObject private var qsoHub: QSOHub
    @Binding var showLinkedQSO: Bool
    @Binding var showPersonalCall: Bool
    @State private var selectedTab: Tab = .directory
    @State private var directoryPath: [QSORoute] = []
    @State private var favoritesPath: [QSORoute] = []
    @State private var recentsPath: [QSORoute] = []
    @State private var settingsPath: [QSORoute] = []
    @State private var showSettingsStation = false
    @State private var qsoTab: Tab?
    @State private var presentedEntryID: UUID?

    private enum Tab: Hashable {
        case directory, favorites, recents, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            QSONavigationTab(path: $directoryPath, qsoHub: qsoHub, onReturn: openQSO) {
                DirectoryView(directoryService: appState.directoryService)
                    .id(appState.currentUser)
            }
            .tabItem { Label("Directory", systemImage: "dot.radiowaves.left.and.right") }
            .tag(Tab.directory)

            QSONavigationTab(path: $favoritesPath, qsoHub: qsoHub, onReturn: openQSO) {
                FavoritesView()
            }
            .tabItem { Label("Favorites", systemImage: "star") }
            .tag(Tab.favorites)

            QSONavigationTab(path: $recentsPath, qsoHub: qsoHub, onReturn: openQSO) {
                RecentView()
            }
            .tabItem { Label("Recents", systemImage: "clock.arrow.circlepath") }
            .tag(Tab.recents)

            QSONavigationTab(path: $settingsPath, qsoHub: qsoHub, onReturn: openQSO) {
                SettingsView(showPersonalStation: $showSettingsStation)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .onReceive(qsoHub.$activeID) { id in
            if let id {
                if presentedEntryID != id {
                    presentedEntryID = id
                    #if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
                    // Exercise the return bar without opening a real connection.
                    if SimulatorDemoData.isEnabled && SimulatorDemoData.screen == "browse-qso" { return }
                    #endif
                    qsoTab = selectedTab
                    pushQSO(id, in: selectedTab)
                }
            } else {
                presentedEntryID = nil
                qsoTab = nil
                directoryPath.removeAll()
                favoritesPath.removeAll()
                recentsPath.removeAll()
                settingsPath.removeAll()
            }
        }
        .onChange(of: showLinkedQSO) { _, requested in
            guard requested else { return }
            openQSO()
            showLinkedQSO = false
        }
        .onChange(of: showPersonalCall) { _, requested in
            guard requested else { return }
            selectedTab = .settings
            showSettingsStation = true
            showPersonalCall = false
        }
        #if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        .onAppear {
            guard SimulatorDemoData.isEnabled else { return }
            switch SimulatorDemoData.screen {
            case "favorites": selectedTab = .favorites
            case "recents": selectedTab = .recents
            case "personal":
                selectedTab = .settings
                showSettingsStation = true
            case "settings": selectedTab = .settings
            default: break
            }
        }
        #endif
    }

    private func openQSO() {
        guard let id = qsoHub.activeID else { return }
        let tab = qsoTab ?? selectedTab
        qsoTab = tab
        selectedTab = tab
        pushQSO(id, in: tab)
    }

    private func pushQSO(_ sessionID: UUID, in tab: Tab) {
        let route = QSORoute.qso(sessionID)
        switch tab {
        case .directory: directoryPath = [route]
        case .favorites: favoritesPath = [route]
        case .recents: recentsPath = [route]
        case .settings: settingsPath = [route]
        }
    }
}

#if targetEnvironment(macCatalyst)
private extension Notification.Name {
    static let openCurrentQSO = Notification.Name("ReverbQSO.openCurrentQSO")
    static let openSettings = Notification.Name("ReverbQSO.openSettings")
    static let openHosting = Notification.Name("ReverbQSO.openHosting")
    static let openDirectory = Notification.Name("ReverbQSO.openDirectory")
    static let openFavorites = Notification.Name("ReverbQSO.openFavorites")
    static let openRecents = Notification.Name("ReverbQSO.openRecents")
}

private struct MacRadioCommands: Commands {
    @ObservedObject var qsoHub: QSOHub
    @ObservedObject var conferenceHost: EchoLinkConferenceHostService

    private var connectionService: EchoLinkConnectionService { qsoHub.activeService }

    private var isTransmitting: Bool {
        conferenceHost.isRunning
            ? conferenceHost.isTransmitting
            : connectionService.session?.isPTTActive == true
    }

    var body: some Commands {
        CommandMenu("Radio") {
            if conferenceHost.isRunning {
                Button(conferenceHost.isPersonalMode ? "Available for Calls" : "Hosting a Conference") {}
                    .disabled(true)
            } else if let session = connectionService.session, session.state == .connected {
                Button("Connected to \(session.station.callsign)") {}
                    .disabled(true)
            } else {
                Button("No Active QSO") {}
                    .disabled(true)
            }

            Button("Release PTT") {
                if conferenceHost.isRunning {
                    conferenceHost.setPTT(active: false)
                } else {
                    connectionService.sendPTT(active: false)
                }
            }
            .disabled(!isTransmitting)

            Button(connectionService.session?.isMuted == true ? "Unmute Receive Audio" : "Mute Receive Audio") {
                connectionService.toggleMute()
            }
            .disabled(connectionService.session?.state != .connected)

            Divider()

            Button("Show Current QSO") {
                NotificationCenter.default.post(name: .openCurrentQSO, object: nil)
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])
            .disabled(connectionService.session == nil)

            Button("Settings…") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}
#endif

private enum QSORoute: Hashable {
    case qso(UUID)
}

private struct QSONavigationTab<Content: View>: View {
    @Binding var path: [QSORoute]
    @ObservedObject var qsoHub: QSOHub
    let onReturn: () -> Void
    let content: Content

    init(
        path: Binding<[QSORoute]>,
        qsoHub: QSOHub,
        onReturn: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        _path = path
        self.qsoHub = qsoHub
        self.onReturn = onReturn
        self.content = content()
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .safeAreaInset(edge: .top) {
                    if path.isEmpty, let id = qsoHub.activeID,
                       let active = qsoHub.entry(for: id) {
                        HStack(spacing: 0) {
                            Button(action: onReturn) {
                                HStack(spacing: 10) {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(.tint)
                                    Text("Return to QSO")
                                        .fontWeight(.semibold)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Text(active.station?.callsign ?? "Connecting…")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Return to QSO with \(active.station?.callsign ?? "connecting station")")
                            .accessibilityIdentifier("return-to-qso")
                            if qsoHub.entries.count > 1 {
                                Divider().frame(height: 20)
                                Menu {
                                    ForEach(qsoHub.entries) { entry in
                                        Button(entry.station?.callsign ?? "Connecting…") {
                                            qsoHub.select(entry.id)
                                            onReturn()
                                        }
                                    }
                                } label: {
                                    Label("\(qsoHub.entries.count)", systemImage: "phone.connection")
                                        .font(.subheadline)
                                        .padding(.horizontal, 16)
                                        .frame(minHeight: 44)
                                }
                                .accessibilityLabel("Switch between \(qsoHub.entries.count) QSOs")
                            }
                        }
                        .font(.subheadline)
                        .background(.bar)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
                .navigationDestination(for: QSORoute.self) { route in
                    if case .qso(let id) = route, let entry = qsoHub.entry(for: id) {
                        QSOView(connectionService: entry.service)
                            .id(entry.id)
                            .onAppear { qsoHub.select(id) }
                    } else {
                        ContentUnavailableView("QSO Ended", systemImage: "phone.down")
                    }
                }
        }
    }
}

/// Keeps a standalone navigation container in the Mac sidebar. On iPhone,
/// the tab owns the NavigationStack so QSO uses the native back gesture.
struct StandaloneNavigationContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        NavigationStack { content }
        #else
        content
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct MacSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var connectionService: EchoLinkConnectionService
    @EnvironmentObject private var qsoHub: QSOHub
    @Binding var showPersonalCall: Bool
    @State private var selection: Destination? = .directory
    @State private var showSettingsStation = false

    private enum Destination: Hashable {
        case directory
        case favorites
        case recents
        case settings
        case qso(UUID)
        case hosting
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Stations") {
                    NavigationLink(value: Destination.directory) {
                        Label("Directory", systemImage: "dot.radiowaves.left.and.right")
                    }
                    NavigationLink(value: Destination.favorites) {
                        Label("Favorites", systemImage: "star")
                    }
                    NavigationLink(value: Destination.recents) {
                        Label("Recents", systemImage: "clock.arrow.circlepath")
                    }
                }

                if !qsoHub.entries.isEmpty {
                    Section("On Air") {
                        ForEach(qsoHub.entries) { entry in
                            NavigationLink(value: Destination.qso(entry.id)) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.station?.callsign ?? "Connecting…")
                                        Text("\(entry.callsign) · \(entry.mode.title)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "waveform")
                                }
                            }
                        }
                    }
                }

                Section("App") {
                    NavigationLink(value: Destination.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                Section("Station") {
                    NavigationLink(value: Destination.hosting) {
                        Label("Conference Host", systemImage: "person.3.fill")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("ReverbQSO")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
        } detail: {
            Group {
                switch selection ?? .directory {
                case .directory:
                    DirectoryView(directoryService: appState.directoryService)
                        .id(appState.currentUser)
                case .favorites:
                    FavoritesView()
                case .recents:
                    RecentView()
                case .settings:
                    NavigationStack {
                        SettingsView(showPersonalStation: $showSettingsStation)
                    }
                case .qso(let id):
                    if let entry = qsoHub.entry(for: id) {
                        QSOView(connectionService: entry.service)
                            .id(entry.id)
                    } else {
                        ContentUnavailableView("QSO Ended", systemImage: "phone.down")
                    }
                case .hosting:
                    ConferenceHostView(
                        host: appState.conferenceHostService,
                        directory: appState.directoryService,
                        outbound: connectionService,
                        callsign: appState.currentUser
                    )
                }
            }
        }
        .onReceive(qsoHub.$activeID) { id in
            if let id { selection = .qso(id) }
        }
        .onChange(of: selection) { _, destination in
            if case .qso(let id)? = destination { qsoHub.select(id) }
        }
        .onReceive(qsoHub.$entries) { entries in
            if case .qso(let id)? = selection,
               !entries.contains(where: { $0.id == id }) {
                selection = entries.last.map { .qso($0.id) } ?? .directory
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCurrentQSO)) { _ in
            guard let id = qsoHub.activeID else { return }
            selection = .qso(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            selection = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDirectory)) { _ in
            selection = .directory
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFavorites)) { _ in
            selection = .favorites
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRecents)) { _ in
            selection = .recents
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHosting)) { _ in
            selection = .hosting
        }
        .onChange(of: showPersonalCall) { _, requested in
            guard requested else { return }
            selection = .settings
            showSettingsStation = true
            showPersonalCall = false
        }
    }
}
#endif

private struct LoginView: View {
    @EnvironmentObject private var appState: AppState

    private enum Field: Hashable {
        case callsign, password
    }

    @State private var callsign = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var showingRegistration = false
    @FocusState private var focusedField: Field?

    private let passwordHelpURL = URL(string: "https://www.echolink.org/validation/pw_reset_email.jsp")!

    private var canSubmit: Bool {
        !isSubmitting
            && !callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            #if targetEnvironment(macCatalyst)
            let brandWidth = min(geometry.size.width * 0.36, 520)
            let formMaxWidth: CGFloat = 480
            #else
            let brandWidth = geometry.size.width * 0.42
            let formMaxWidth: CGFloat = 400
            #endif
            let isWideLayout = geometry.size.width >= 700

            HStack(spacing: 0) {
                if isWideLayout {
                    tabletBrandPanel
                        .frame(width: brandWidth)
                }

                if isWideLayout {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer(minLength: 12)

                            Text("Sign in")
                                .font(.largeTitle.weight(.bold))
                                .padding(.bottom, 4)
                            Text("EchoLink account")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 20)

                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Callsign")
                                        .font(.subheadline.weight(.semibold))
                                    TextField("Your callsign", text: $callsign)
                                        .textContentType(.username)
                                        .textInputAutocapitalization(.characters)
                                        .autocorrectionDisabled()
                                        .keyboardType(.asciiCapable)
                                        .submitLabel(.next)
                                        .focused($focusedField, equals: .callsign)
                                        .onSubmit { focusedField = .password }
                                        .loginFieldStyle()
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Password")
                                        .font(.subheadline.weight(.semibold))
                                    SecureField("EchoLink password", text: $password)
                                        .textContentType(.password)
                                        .submitLabel(.go)
                                        .focused($focusedField, equals: .password)
                                        .onSubmit { if canSubmit { submitLogin() } }
                                        .loginFieldStyle()
                                }
                            }
                            .accessibilityElement(children: .contain)

                            Link("Forgot password?", destination: passwordHelpURL)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                                .padding(.top, 4)

                            if let error = appState.loginError, !error.isEmpty {
                                Label(error, systemImage: "exclamationmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 20)
                                    .accessibilityAddTraits(.updatesFrequently)
                            }

                            Button(action: submitLogin) {
                                HStack(spacing: 8) {
                                    if isSubmitting {
                                        ProgressView()
                                            .tint(.white)
                                    }
                                    Text(isSubmitting ? "Signing In…" : "Sign In")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!canSubmit)
                            .padding(.top, 12)

                            Spacer().frame(height: 28)

                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    showingRegistration = true
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("Register a callsign")
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .accessibilityHidden(true)
                                    }
                                    .font(.subheadline.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)

                                Link("Privacy Policy", destination: ReverbQSOLinks.privacyPolicy)
                                    .font(.subheadline)
                            }
                            .padding(.bottom, 16)

                            Spacer(minLength: 12)
                        }
                        .frame(maxWidth: formMaxWidth)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        .padding(.horizontal, 28)
                    }
                    .scrollDismissesKeyboard(.interactively)
                } else {
                    compactLoginForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .onAppear {
                if callsign.isEmpty {
                    callsign = appState.currentUser
                }
                #if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
                if SimulatorDemoData.isEnabled && password.isEmpty {
                    password = SimulatorDemoData.password
                }
                if SimulatorDemoData.isEnabled && SimulatorDemoData.screen == "register" {
                    showingRegistration = true
                }
                #endif
            }
            .sheet(isPresented: $showingRegistration) {
                EchoLinkRegistrationView(initialCallsign: callsign)
            }
        }
    }

    private var compactLoginForm: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("ReverbQSO", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.title.weight(.bold))
                        .labelStyle(.titleAndIcon)
                    Text("Sign in with EchoLink")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                LabeledContent("Callsign") {
                    TextField("Callsign", text: $callsign)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.username)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .callsign)
                        .onSubmit { focusedField = .password }
                        .accessibilityLabel("Callsign")
                }
                LabeledContent("Password") {
                    SecureField("EchoLink password", text: $password)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit { if canSubmit { submitLogin() } }
                        .accessibilityLabel("Password")
                }
            }

            Section {
                Button(action: submitLogin) {
                    HStack(spacing: 8) {
                        if isSubmitting { ProgressView().tint(.white) }
                        Text(isSubmitting ? "Signing In…" : "Sign In")
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if let error = appState.loginError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }

            Section {
                Link("Forgot password?", destination: passwordHelpURL)
                Button("Register a callsign") { showingRegistration = true }
                Link("Privacy Policy", destination: ReverbQSOLinks.privacyPolicy)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var tabletBrandPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 58, weight: .light))
                .accessibilityHidden(true)
            Text("ReverbQSO")
                .font(.largeTitle.weight(.bold))
            Text("Connect with stations, repeaters, and conferences.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 36)
        .background {
            LinearGradient(
                colors: [.blue, .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea(edges: .vertical)
        }
    }

    private func submitLogin() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            await appState.login(callsign: callsign, password: password)
            isSubmitting = false
        }
    }
}

private struct EchoLinkRegistrationView: View {
    @Environment(\.dismiss) private var dismiss

    let initialCallsign: String
    private let validationURL = URL(string: "https://www.echolink.org/validation/")!
    @State private var callsign = ""
    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var canSubmit: Bool {
        !isSubmitting && !callsign.isEmpty && !email.isEmpty && !password.isEmpty
            && password == passwordConfirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                if let successMessage {
                    Section {
                        Label("Registration requested", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(successMessage)
                        Link("Open EchoLink validation", destination: validationURL)
                    } footer: {
                        Text("After EchoLink approves your license, sign in here with the callsign and password you chose.")
                    }
                } else {
                    Section {
                        Text("Register your callsign with EchoLink, then follow the email instructions to validate your amateur radio license.")
                            .foregroundStyle(.secondary)
                    }

                    Section("Your details") {
                        TextField("Callsign", text: $callsign)
                            .textContentType(.username)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        TextField("Email address", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Choose a password", text: $password)
                            .textContentType(.newPassword)
                        SecureField("Confirm password", text: $passwordConfirmation)
                            .textContentType(.newPassword)
                        if !passwordConfirmation.isEmpty && password != passwordConfirmation {
                            Text("Passwords don't match.")
                                .foregroundStyle(.red)
                        }
                    }

                    Section {
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.red)
                        }
                        Button {
                            submitRegistration()
                        } label: {
                            if isSubmitting {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Register Callsign")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit)
                    } footer: {
                        Text("Use 5–14 standard keyboard characters. EchoLink treats letters as uppercase. Keep this password for sign-in after validation.")
                    }
                }
            }
            .navigationTitle("Register")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if callsign.isEmpty { callsign = initialCallsign }
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 500, minHeight: 520)
        #else
        .presentationDetents([.large])
        #endif
    }

    private func submitRegistration() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                successMessage = try await EchoLinkRegistrationClient().register(
                    callsign: callsign,
                    email: email,
                    password: password
                )
                password = ""
                passwordConfirmation = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension View {
    func loginFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            #if targetEnvironment(macCatalyst)
            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            #else
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            #endif
    }
}
