// SPDX-License-Identifier: GPL-3.0-or-later

#if targetEnvironment(macCatalyst)
import Combine
import Foundation
import UIKit
import UserNotifications

/// Publishes the current radio state to the separate native macOS menu bar app.
/// Menu bar PTT commands require an active connected QSO and a short renewed lease.
@MainActor
final class MacMenuBarBridge {
    private let qsoHub: QSOHub
    private let conferenceHost: EchoLinkConferenceHostService
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var commandTimer: Timer?
    private var stateTimer: Timer?
    private var menuPTTLease: (sessionID: UUID, expiresAt: Date)?

    init(qsoHub: QSOHub, conferenceHost: EchoLinkConferenceHostService) {
        self.qsoHub = qsoHub
        self.conferenceHost = conferenceHost

        qsoHub.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.publish() }
            }
            .store(in: &cancellables)
        conferenceHost.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.publish() }
            }
            .store(in: &cancellables)

        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: MacMenuBarProtocol.requestState, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        })
        observers.append(center.addObserver(forName: MacMenuBarProtocol.releasePTT, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.releasePTT() }
        })
        observers.append(center.addObserver(forName: MacMenuBarProtocol.command, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[MacMenuBarProtocol.commandTypeKey] as? String
            let id = notification.userInfo?[MacMenuBarProtocol.commandIDKey] as? String
            Task { @MainActor in await self?.handleCommand(type: type, id: id) }
        })
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.consumeReleaseRequest() }
        }
        // RX activity does not necessarily change the session value. Poll the
        // radio flags so the menu icon follows voice activity as it happens.
        stateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishIfChanged() }
        }
        publish()
    }

    private var lastPublishedState: [String: String] = [:]

    private func publishIfChanged() {
        expireMenuPTTIfNeeded()
        let service = qsoHub.activeService
        let state = [
            "rx": String(service.isRemoteTransmitting),
            "tx": String(conferenceHost.isRunning ? conferenceHost.isTransmitting : service.session?.isPTTActive == true),
            "count": String(qsoHub.entries.count),
            "active": qsoHub.activeID?.uuidString ?? "",
            "talker": conferenceHost.talkerCallsign ?? "",
            "incoming": conferenceHost.pendingCall?.id.uuidString ?? ""
        ]
        guard state != lastPublishedState else { return }
        publish()
    }

    private func consumeReleaseRequest() {
        let url = MacMenuBarProtocol.releaseFile
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        releasePTT()
    }

    private func releasePTT() {
        menuPTTLease = nil
        let connectionService = qsoHub.activeService
        if conferenceHost.isTransmitting {
            conferenceHost.setPTT(active: false)
        }
        if connectionService.session?.state == .connected {
            connectionService.sendPTT(active: false)
        }
        publish()
    }

    private func handleCommand(type: String?, id: String?) async {
        guard let type, let id, let requestedID = UUID(uuidString: id) else { return }
        switch type {
        case "selectSession":
            guard qsoHub.entry(for: requestedID) != nil else { return }
            qsoHub.select(requestedID)
        case "disconnectSession":
            guard let entry = qsoHub.entry(for: requestedID) else { return }
            if entry.service.session?.isPTTActive == true {
                entry.service.sendPTT(active: false)
            }
            await entry.service.disconnect()
        case "toggleMuteSession":
            guard qsoHub.activeID == requestedID,
                  let entry = qsoHub.entry(for: requestedID),
                  entry.service.session?.state == .connected else { return }
            entry.service.toggleMute()
        case "holdPTT":
            guard !conferenceHost.isRunning,
                  qsoHub.activeID == requestedID,
                  let entry = qsoHub.entry(for: requestedID),
                  entry.service.session?.state == .connected,
                  entry.service.session?.isPTTActive == true || entry.service.canTransmit else { return }
            guard menuPTTLease?.sessionID == requestedID
                    || entry.service.session?.isPTTActive != true else { return }
            menuPTTLease = (requestedID, Date().addingTimeInterval(1.5))
            if entry.service.session?.isPTTActive != true {
                entry.service.sendPTT(active: true)
            }
        case "releaseHeldPTT":
            guard menuPTTLease?.sessionID == requestedID else { return }
            menuPTTLease = nil
            qsoHub.entry(for: requestedID)?.service.sendPTT(active: false)
        case "answerCall":
            guard conferenceHost.isPersonalMode,
                  conferenceHost.pendingCall?.id == requestedID else { return }
            await conferenceHost.acceptPendingCall()
        case "declineCall":
            guard conferenceHost.isPersonalMode,
                  conferenceHost.pendingCall?.id == requestedID else { return }
            await conferenceHost.declinePendingCall()
        default:
            return
        }
        publish()
    }

    private func expireMenuPTTIfNeeded() {
        guard let lease = menuPTTLease else { return }
        guard Date() >= lease.expiresAt
                || qsoHub.activeID != lease.sessionID
                || qsoHub.entry(for: lease.sessionID)?.service.session?.state != .connected else { return }
        menuPTTLease = nil
        qsoHub.entry(for: lease.sessionID)?.service.sendPTT(active: false)
    }

    private func publish() {
        let connectionService = qsoHub.activeService
        let session = connectionService.session
        let hosting = conferenceHost.isRunning
        let personal = hosting && conferenceHost.isPersonalMode
        let incomingCall = personal && conferenceHost.pendingCall != nil
        let connected = session?.state == .connected
        lastPublishedState = [
            "rx": String(connectionService.isRemoteTransmitting),
            "tx": String(hosting ? conferenceHost.isTransmitting : session?.isPTTActive == true),
            "count": String(qsoHub.entries.count),
            "active": qsoHub.activeID?.uuidString ?? "",
            "talker": conferenceHost.talkerCallsign ?? "",
            "incoming": conferenceHost.pendingCall?.id.uuidString ?? ""
        ]
        let sessions: [[String: Any]] = qsoHub.entries.map { entry in
            [
                "id": entry.id.uuidString,
                "station": entry.station?.callsign ?? "Connecting…",
                "account": entry.callsign,
                "connected": entry.service.session?.state == .connected,
                "active": entry.id == qsoHub.activeID,
                "muted": entry.service.session?.isMuted == true,
                "canTransmit": entry.service.canTransmit
            ]
        }
        let state: [String: Any] = [
            MacMenuBarProtocol.updatedAtKey: Date().timeIntervalSince1970,
            MacMenuBarProtocol.sessionsKey: sessions,
            MacMenuBarProtocol.hostPeerCountKey: conferenceHost.sessions.count,
            MacMenuBarProtocol.talkerKey: conferenceHost.talkerCallsign ?? "",
            MacMenuBarProtocol.pendingCallIDKey: conferenceHost.pendingCall?.id.uuidString ?? "",
            MacMenuBarProtocol.stationKey: hosting
                ? (personal
                    ? (conferenceHost.pendingCall?.callsign ?? conferenceHost.sessions.first?.callsign ?? "Available for calls")
                    : "Conference Host")
                : (connected ? session?.station.callsign ?? "" : ""),
            MacMenuBarProtocol.connectedKey: connected,
            MacMenuBarProtocol.hostingKey: hosting,
            MacMenuBarProtocol.personalKey: personal,
            MacMenuBarProtocol.incomingCallKey: incomingCall,
            MacMenuBarProtocol.transmittingKey: hosting ? conferenceHost.isTransmitting : (session?.isPTTActive == true),
            MacMenuBarProtocol.receivingKey: hosting ? conferenceHost.talkerCallsign != nil : connectionService.isRemoteTransmitting,
            MacMenuBarProtocol.sessionCountKey: qsoHub.entries.count
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) {
            let directory = MacMenuBarProtocol.sharedDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: MacMenuBarProtocol.stateFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: MacMenuBarProtocol.stateFile.path)
        }
        DistributedNotificationCenter.default().post(
            name: MacMenuBarProtocol.state,
            object: nil,
            userInfo: state
        )
    }
}

@MainActor
final class MacMessageNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "macMessageNotificationsEnabled"

    private let qsoHub: QSOHub
    private let conferenceHost: EchoLinkConferenceHostService
    private let notificationCenter = UNUserNotificationCenter.current()
    private var hubSubscription: AnyCancellable?
    private var hostSubscription: AnyCancellable?
    private var messageSubscriptions: [UUID: AnyCancellable] = [:]
    private var messageCursors: [UUID: ChatMessageNotificationCursor] = [:]
    private var hostCursor: ChatMessageNotificationCursor
    private var isAuthorized = false
    private var lastSoundAt = Date.distantPast

    init(qsoHub: QSOHub, conferenceHost: EchoLinkConferenceHostService) {
        self.qsoHub = qsoHub
        self.conferenceHost = conferenceHost
        hostCursor = ChatMessageNotificationCursor(messages: conferenceHost.messages)
        super.init()

        notificationCenter.delegate = self
        refreshAuthorizationStatus()

        hubSubscription = qsoHub.$entries.sink { [weak self] entries in
            Task { @MainActor [weak self] in self?.observe(entries: entries) }
        }
        hostSubscription = conferenceHost.$messages.dropFirst().sink { [weak self] messages in
            Task { @MainActor [weak self] in self?.handleHostMessages(messages) }
        }
    }

    static func notificationsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func refreshAuthorization() {
        (UNUserNotificationCenter.current().delegate as? MacMessageNotifier)?.requestAuthorization()
    }

    static func refreshAuthorizationStatus() {
        (UNUserNotificationCenter.current().delegate as? MacMessageNotifier)?.refreshAuthorizationStatus()
    }

    private func refreshAuthorizationStatus() {
        Task { [weak self] in
            guard let self else { return }
            let status = await notificationCenter.notificationSettings().authorizationStatus
            isAuthorized = status == .authorized || status == .provisional
        }
    }

    private func requestAuthorization() {
        Task { [weak self] in
            guard let self else { return }
            isAuthorized = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) == true
        }
    }

    private func observe(entries: [QSOHub.Entry]) {
        let currentIDs = Set(entries.map(\.id))
        for id in messageSubscriptions.keys where !currentIDs.contains(id) {
            messageSubscriptions.removeValue(forKey: id)
            messageCursors.removeValue(forKey: id)
        }
        for entry in entries where messageSubscriptions[entry.id] == nil {
            messageCursors[entry.id] = ChatMessageNotificationCursor(messages: entry.service.incomingChatMessages)
            messageSubscriptions[entry.id] = entry.service.$incomingChatMessages.dropFirst().sink { [weak self] messages in
                Task { @MainActor [weak self] in self?.handleMessages(messages, for: entry.id) }
            }
        }
    }

    private func handleMessages(_ messages: [ChatMessage], for id: UUID) {
        guard var cursor = messageCursors[id], let entry = qsoHub.entry(for: id) else { return }
        let newMessages = cursor.newIncomingMessages(in: messages)
        messageCursors[id] = cursor
        for message in newMessages {
            schedule(message, context: entry.station?.callsign ?? "EchoLink", route: "qso", sessionID: id)
        }
    }

    private func handleHostMessages(_ messages: [ChatMessage]) {
        let newMessages = hostCursor.newIncomingMessages(in: messages)
        for message in newMessages {
            schedule(
                message,
                context: conferenceHost.isPersonalMode ? "My Station" : "Conference Host",
                route: conferenceHost.isPersonalMode ? "personal" : "hosting",
                sessionID: nil
            )
        }
    }

    private func schedule(_ message: ChatMessage, context: String, route: String, sessionID: UUID?) {
        guard Self.notificationsEnabled(), isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = message.sender
        content.subtitle = context
        content.body = String(message.body.prefix(300))
        content.threadIdentifier = sessionID?.uuidString ?? route
        content.userInfo = ["route": route, "sessionID": sessionID?.uuidString ?? ""]
        if Date().timeIntervalSince(lastSoundAt) >= 2 {
            content.sound = .default
            lastSoundAt = Date()
        }
        notificationCenter.add(UNNotificationRequest(identifier: message.id.uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = response.notification.request.content.userInfo["route"] as? String
        let sessionID = (response.notification.request.content.userInfo["sessionID"] as? String)
            .flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in self?.open(route: route, sessionID: sessionID) }
        completionHandler()
    }

    private func open(route: String?, sessionID: UUID?) {
        guard let route, ["qso", "personal", "hosting"].contains(route) else { return }
        if route == "qso" {
            guard let sessionID, qsoHub.entry(for: sessionID) != nil else {
                if let recentsURL = URL(string: "reverbqso://recents") {
                    UIApplication.shared.open(recentsURL)
                }
                return
            }
            qsoHub.select(sessionID)
        }
        guard let url = URL(string: "reverbqso://\(route)") else { return }
        UIApplication.shared.open(url)
    }
}
#endif
