// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Notification names shared by the Catalyst app and its macOS menu bar companion.
/// The companion can observe radio state and request only non-transmitting actions.
enum MacMenuBarProtocol {
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
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/ReverbQSO", isDirectory: true)
    }

    static var stateFile: URL { sharedDirectory.appendingPathComponent("menu-state.plist") }
    static var releaseFile: URL { sharedDirectory.appendingPathComponent("release-ptt") }
}
