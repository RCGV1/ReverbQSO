// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServiceManagement
import SwiftUI

@main
struct ReverbQSOMenuBarApp: App {
    @StateObject private var radio = MenuBarRadioModel()
    @State private var sessionToEnd: MenuBarSession?
    @State private var confirmingEnd = false

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(16)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if radio.hasFreshState {
                        if radio.incomingCall { incomingCallControls }
                        if let session = radio.activeSession { activeQSO(session) }
                        if !radio.inactiveSessions.isEmpty { otherSessions }
                        if radio.hosting { hostingControls }
                        if radio.transmitting { releasePTTButton }
                        if radio.sessions.isEmpty && !radio.hosting && !radio.incomingCall {
                            idleState
                        }
                    } else {
                        unavailableState
                    }
                }
                .padding(16)
                Divider()
                footer
                    .padding(12)
                if let serviceMessage = radio.serviceMessage {
                    Text(serviceMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
            .frame(width: 320)
            .confirmationDialog("End QSO?", isPresented: $confirmingEnd) {
                Button("End QSO", role: .destructive) {
                    if let sessionToEnd {
                        radio.disconnectSession(sessionToEnd.id)
                    }
                    sessionToEnd = nil
                }
                Button("Cancel", role: .cancel) { sessionToEnd = nil }
            } message: {
                Text("Disconnect from \(sessionToEnd?.station ?? "this station")?")
            }
        } label: {
            Image(systemName: radio.symbolName)
                .accessibilityLabel("ReverbQSO: \(radio.statusTitle)")
        }
        .menuBarExtraStyle(.window)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: radio.symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(radio.statusColor)
                .frame(width: 32, height: 32)
                .background(radio.statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(radio.statusTitle)
                    .font(.headline)
                Text(radio.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var incomingCallControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Incoming from \(radio.station)")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            HStack {
                Button {
                    radio.answerCall()
                    radio.open("personal")
                } label: {
                    Label("Answer", systemImage: "phone.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    radio.declineCall()
                } label: {
                    Label("Decline", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func activeQSO(_ session: MenuBarSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: radio.transmitting ? "mic.fill" : radio.receiving ? "waveform" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(radio.statusColor)
                Text(session.station)
                    .font(.system(.headline, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(radio.transmitting ? "TX" : radio.receiving ? "RX" : session.connected ? "Connected" : "Connecting")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(radio.statusColor)
            }
            Text("Using \(session.account)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(radio.isHoldingPTT ? "Transmitting" : "Hold to Talk", systemImage: "mic.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(
                    radio.isHoldingPTT ? Color.green : Color.accentColor,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .opacity((session.canTransmit && !radio.transmitting) || radio.isHoldingPTT ? 1 : 0.5)
                .contentShape(Rectangle())
                .onLongPressGesture(
                    minimumDuration: .infinity,
                    maximumDistance: .infinity,
                    pressing: { pressed in radio.setPTTHeld(pressed, for: session.id) },
                    perform: {}
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hold to Talk")
                .accessibilityHint("Press and hold to transmit; release to stop")
            HStack(spacing: 8) {
                Button("Show QSO") { radio.open("qso") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.connected)
                Button(session.muted ? "Unmute" : "Mute") { radio.toggleMuteSession(session.id) }
                    .disabled(!session.connected)
                    .accessibilityLabel(session.muted ? "Unmute receive audio" : "Mute receive audio")
                Spacer(minLength: 0)
                Button {
                    sessionToEnd = session
                    confirmingEnd = true
                } label: {
                    Image(systemName: "phone.down")
                }
                .help("End QSO with \(session.station)")
                .accessibilityLabel("End QSO with \(session.station)")
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear { radio.setPTTHeld(false, for: session.id) }
    }

    private var otherSessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OTHER QSOS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(radio.inactiveSessions) { session in
                        Button {
                            radio.selectSession(session.id)
                        } label: {
                            HStack {
                                Text(session.station)
                                    .font(.system(.subheadline, design: .monospaced))
                                Spacer()
                                Text(session.connected ? session.account : "Connecting")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .disabled(!session.connected)
                        .accessibilityHint("Select this QSO for audio and push to talk")
                    }
                }
            }
            .frame(height: min(CGFloat(radio.inactiveSessions.count) * 34, 136))
        }
    }

    private var hostingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if radio.personal {
                Label(radio.hostPeerCount > 0 ? "In a call" : "Available for calls", systemImage: "person.crop.circle")
                    .font(.subheadline)
                Button("Open My Station") { radio.open("personal") }
            } else {
                Label("\(radio.hostPeerCount) connected", systemImage: "person.3")
                    .font(.subheadline)
                if !radio.talker.isEmpty {
                    Text("Talking: \(radio.talker)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Open Conference Host") { radio.open("hosting") }
            }
        }
    }

    private var releasePTTButton: some View {
        Button(role: .destructive) { radio.releasePTT() } label: {
            Label("Release PTT", systemImage: "mic.slash.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .accessibilityHint("Stops transmitting immediately")
    }

    private var idleState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a station to start a QSO.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Browse Stations") { radio.open("directory") }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if radio.appRunning {
                Text("Waiting for radio status")
                    .font(.subheadline.weight(.semibold))
            }
            Button("Open ReverbQSO") { radio.open("directory") }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                radio.open("favorites")
            } label: {
                Label("Favorites", systemImage: "star")
            }
            Button {
                radio.open("recents")
            } label: {
                Label("Recents", systemImage: "clock")
            }
            Spacer(minLength: 0)
            Menu {
                Button("Directory") { radio.open("directory") }
                Button("Settings…") { radio.open("settings") }
                Divider()
                Toggle("Open at Login", isOn: Binding(
                    get: { radio.launchAtLogin },
                    set: { radio.setLaunchAtLogin($0) }
                ))
                Divider()
                Button("Quit Menu Bar App") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More options")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct MenuBarSession: Identifiable {
    let id: String
    let station: String
    let account: String
    let connected: Bool
    let active: Bool
    let muted: Bool
    let canTransmit: Bool
}

@MainActor
final class MenuBarRadioModel: ObservableObject {
    @Published private(set) var appRunning = false
    @Published private(set) var connected = false
    @Published private(set) var hosting = false
    @Published private(set) var personal = false
    @Published private(set) var incomingCall = false
    @Published private(set) var transmitting = false
    @Published private(set) var receiving = false
    @Published private(set) var station = ""
    @Published private(set) var sessions: [MenuBarSession] = []
    @Published private(set) var hostPeerCount = 0
    @Published private(set) var talker = ""
    @Published private(set) var pendingCallID = ""
    @Published private(set) var updatedAt = Date.distantPast
    @Published private(set) var now = Date()
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var serviceMessage: String?
    @Published private(set) var isHoldingPTT = false

    private var statusObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var pttTimer: Timer?
    private var heldSessionID: String?

    var hasFreshState: Bool {
        appRunning && now.timeIntervalSince(updatedAt) >= -5 && now.timeIntervalSince(updatedAt) <= 5
    }

    var activeSession: MenuBarSession? { sessions.first(where: \.active) }
    var inactiveSessions: [MenuBarSession] { sessions.filter { !$0.active } }

    var symbolName: String {
        guard hasFreshState else { return "antenna.radiowaves.left.and.right" }
        if incomingCall { return "phone.arrow.down.left.fill" }
        if transmitting { return "mic.fill" }
        if receiving { return "waveform" }
        return "antenna.radiowaves.left.and.right"
    }

    var statusColor: Color {
        guard hasFreshState else { return .secondary }
        if incomingCall || transmitting { return .orange }
        if receiving { return .green }
        return .accentColor
    }

    var statusTitle: String {
        if !appRunning { return "ReverbQSO is closed" }
        guard hasFreshState else { return "Status unavailable" }
        if incomingCall { return "Incoming Call" }
        if transmitting { return "Transmitting" }
        if receiving { return "Receiving" }
        if personal { return "My Station" }
        if hosting { return "Hosting" }
        return connected ? "Connected" : "Radio idle"
    }

    var statusDetail: String {
        if !appRunning { return "Open the app to get started" }
        guard hasFreshState else { return "Waiting for an update from the app" }
        if hosting { return station }
        if let activeSession {
            return sessions.count > 1 ? "\(activeSession.station) · \(sessions.count) QSOs" : activeSession.station
        }
        return "No active QSO"
    }

    init() {
        statusObserver = DistributedNotificationCenter.default().addObserver(
            forName: MacMenuBarProtocol.state,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let payload = (notification.userInfo ?? [:]).reduce(into: [String: Any]()) { result, item in
                if let key = item.key as? String { result[key] = item.value }
            }
            guard let snapshot = RadioSnapshot(payload: payload) else { return }
            Task { @MainActor in self?.receive(snapshot) }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func open(_ destination: String) {
        guard let url = URL(string: "reverbqso://\(destination)") else { return }
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.benjaminfaershtein.OpenEchoLink"
        ) else {
            serviceMessage = "ReverbQSO is not installed."
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            Task { @MainActor in
                self?.serviceMessage = error?.localizedDescription
            }
        }
    }

    func selectSession(_ id: String) { sendCommand("selectSession", id: id) }
    func toggleMuteSession(_ id: String) { sendCommand("toggleMuteSession", id: id) }
    func setPTTHeld(_ held: Bool, for sessionID: String) {
        if held {
            guard !isHoldingPTT, hasFreshState,
                  activeSession?.id == sessionID,
                  activeSession?.canTransmit == true,
                  !transmitting else { return }
            isHoldingPTT = true
            heldSessionID = sessionID
            renewPTT()
            pttTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.renewPTT() }
            }
        } else {
            guard isHoldingPTT else { return }
            isHoldingPTT = false
            pttTimer?.invalidate()
            pttTimer = nil
            if let heldSessionID {
                sendCommand("releaseHeldPTT", id: heldSessionID)
            }
            heldSessionID = nil
        }
    }

    private func renewPTT() {
        guard let heldSessionID, isHoldingPTT,
              hasFreshState, activeSession?.id == heldSessionID,
              activeSession?.connected == true else {
            setPTTHeld(false, for: heldSessionID ?? "")
            return
        }
        sendCommand("holdPTT", id: heldSessionID)
    }
    func answerCall() { sendCommand("answerCall", id: pendingCallID) }
    func declineCall() { sendCommand("declineCall", id: pendingCallID) }
    func disconnectSession(_ id: String) { sendCommand("disconnectSession", id: id) }

    func releasePTT() {
        guard hasFreshState, transmitting else { return }
        setPTTHeld(false, for: heldSessionID ?? "")
        let directory = MacMenuBarProtocol.sharedDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("release".utf8).write(to: MacMenuBarProtocol.releaseFile, options: .atomic)
        DistributedNotificationCenter.default().post(name: MacMenuBarProtocol.releasePTT, object: nil)
        requestState()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            serviceMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Approve ReverbQSO Menu Bar in System Settings > Login Items."
                : nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            serviceMessage = error.localizedDescription
        }
    }

    private func sendCommand(_ type: String, id: String) {
        guard hasFreshState, !id.isEmpty else { return }
        DistributedNotificationCenter.default().post(
            name: MacMenuBarProtocol.command,
            object: nil,
            userInfo: [
                MacMenuBarProtocol.commandTypeKey: type,
                MacMenuBarProtocol.commandIDKey: id
            ]
        )
        requestState()
    }

    private func receive(_ snapshot: RadioSnapshot) {
        appRunning = true
        station = snapshot.station
        connected = snapshot.connected
        hosting = snapshot.hosting
        personal = snapshot.personal
        incomingCall = snapshot.incomingCall
        transmitting = snapshot.transmitting
        receiving = snapshot.receiving
        sessions = snapshot.sessions
        hostPeerCount = snapshot.hostPeerCount
        talker = snapshot.talker
        pendingCallID = snapshot.pendingCallID
        updatedAt = snapshot.updatedAt
        now = Date()
        if let heldSessionID, activeSession?.id != heldSessionID {
            setPTTHeld(false, for: heldSessionID)
        }
    }

    private func requestState() {
        DistributedNotificationCenter.default().post(name: MacMenuBarProtocol.requestState, object: nil)
    }

    private func poll() {
        now = Date()
        let running = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.benjaminfaershtein.OpenEchoLink"
        ).isEmpty
        appRunning = running
        if running,
           let data = try? Data(contentsOf: MacMenuBarProtocol.stateFile),
           let payload = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let snapshot = RadioSnapshot(payload: payload),
           snapshot.updatedAt > updatedAt {
            receive(snapshot)
        }
        if !running {
            clearState()
        } else {
            requestState()
        }
    }

    private func clearState() {
        setPTTHeld(false, for: heldSessionID ?? "")
        connected = false
        hosting = false
        personal = false
        incomingCall = false
        transmitting = false
        receiving = false
        station = ""
        sessions = []
        hostPeerCount = 0
        talker = ""
        pendingCallID = ""
        updatedAt = .distantPast
    }
}

private struct RadioSnapshot {
    let station: String
    let connected: Bool
    let hosting: Bool
    let personal: Bool
    let incomingCall: Bool
    let transmitting: Bool
    let receiving: Bool
    let sessions: [MenuBarSession]
    let hostPeerCount: Int
    let talker: String
    let pendingCallID: String
    let updatedAt: Date

    init?(payload: [String: Any]) {
        guard let timestamp = payload[MacMenuBarProtocol.updatedAtKey] as? Double else { return nil }
        updatedAt = Date(timeIntervalSince1970: timestamp)
        station = payload[MacMenuBarProtocol.stationKey] as? String ?? ""
        connected = payload[MacMenuBarProtocol.connectedKey] as? Bool ?? false
        hosting = payload[MacMenuBarProtocol.hostingKey] as? Bool ?? false
        personal = payload[MacMenuBarProtocol.personalKey] as? Bool ?? false
        incomingCall = payload[MacMenuBarProtocol.incomingCallKey] as? Bool ?? false
        transmitting = payload[MacMenuBarProtocol.transmittingKey] as? Bool ?? false
        receiving = payload[MacMenuBarProtocol.receivingKey] as? Bool ?? false
        hostPeerCount = payload[MacMenuBarProtocol.hostPeerCountKey] as? Int ?? 0
        talker = payload[MacMenuBarProtocol.talkerKey] as? String ?? ""
        pendingCallID = payload[MacMenuBarProtocol.pendingCallIDKey] as? String ?? ""
        let values = payload[MacMenuBarProtocol.sessionsKey] as? [[String: Any]] ?? []
        sessions = values.compactMap { value in
            guard let id = value["id"] as? String,
                  let station = value["station"] as? String else { return nil }
            return MenuBarSession(
                id: id,
                station: station,
                account: value["account"] as? String ?? "",
                connected: value["connected"] as? Bool ?? false,
                active: value["active"] as? Bool ?? false,
                muted: value["muted"] as? Bool ?? false,
                canTransmit: value["canTransmit"] as? Bool ?? false
            )
        }
    }
}
