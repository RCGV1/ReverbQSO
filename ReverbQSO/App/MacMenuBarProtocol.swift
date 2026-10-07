// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Notification names shared by the Catalyst app and its macOS menu bar companion.
/// Shared files carry state and short-lived, validated commands between the apps.
enum MacMenuBarProtocol {
    static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "ReverbQSOAppGroupIdentifier") as? String
            ?? "FRFXFRT624.com.benjaminfaershtein.ReverbQSO"
    }
    static let state = Notification.Name("com.benjaminfaershtein.OpenEchoLink.menuBar.state")
    static let requestState = Notification.Name("com.benjaminfaershtein.OpenEchoLink.menuBar.requestState")
    static let releasePTT = Notification.Name("com.benjaminfaershtein.OpenEchoLink.menuBar.releasePTT")
    static let command = Notification.Name("com.benjaminfaershtein.OpenEchoLink.menuBar.command")

    static let stationKey = "station"
    static let connectedKey = "connected"
    static let hostingKey = "hosting"
    static let personalKey = "personal"
    static let incomingCallKey = "incomingCall"
    static let transmittingKey = "transmitting"
    static let receivingKey = "receiving"
    static let sessionCountKey = "sessionCount"
    static let updatedAtKey = "updatedAt"
    static let sessionsKey = "sessions"
    static let hostPeerCountKey = "hostPeerCount"
    static let talkerKey = "talker"
    static let pendingCallIDKey = "pendingCallID"
    static let commandTypeKey = "type"
    static let commandIDKey = "id"

    static var sharedDirectory: URL {
        #if os(macOS) || targetEnvironment(macCatalyst)
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        #else
        let group: URL? = nil
        #endif
        return directory(groupContainer: group, home: NSHomeDirectory())
    }

    static func directory(groupContainer: URL?, home: String) -> URL {
        (groupContainer ?? URL(fileURLWithPath: home, isDirectory: true))
            .appendingPathComponent("Library/Application Support/ReverbQSO", isDirectory: true)
    }

    static func isBundledLoginItem(bundleURL: URL) -> Bool {
        bundleURL.path.contains(".app/Contents/Library/LoginItems/")
    }

    enum CommandType: String, Codable {
        case selectSession, disconnectSession, toggleMuteSession
        case holdPTT, releaseHeldPTT, answerCall, declineCall
    }

    struct Command: Codable {
        let type: CommandType
        let id: UUID
        let createdAt: Date
    }

    static func writeCommand(_ type: CommandType, id: UUID,
                             directory: URL = sharedDirectory, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("menu-command.plist")
        let data = try PropertyListEncoder().encode(Command(type: type, id: id, createdAt: now))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func consumeCommand(directory: URL = sharedDirectory, now: Date = Date()) -> Command? {
        let url = directory.appendingPathComponent("menu-command.plist")
        // Claim by rename so cleanup cannot delete a newer command that the
        // companion publishes while this one is being read.
        let claimed = directory.appendingPathComponent("menu-command-\(UUID().uuidString).claimed")
        do { try FileManager.default.moveItem(at: url, to: claimed) }
        catch { return nil }
        defer { try? FileManager.default.removeItem(at: claimed) }
        guard let data = try? Data(contentsOf: claimed), data.count <= 4096 else { return nil }
        guard let command = try? PropertyListDecoder().decode(Command.self, from: data),
              (0...1.5).contains(now.timeIntervalSince(command.createdAt)) else { return nil }
        return command
    }

    static var stateFile: URL { sharedDirectory.appendingPathComponent("menu-state.plist") }
    static var releaseFile: URL { sharedDirectory.appendingPathComponent("release-ptt") }
}
