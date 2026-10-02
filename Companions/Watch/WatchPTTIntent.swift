// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import Foundation

struct TimedWatchPTTIntent: AppIntent {
    static let title: LocalizedStringResource = "Transmit for 30 Seconds"
    static let description = IntentDescription("Transmit for up to 30 seconds on the current EchoLink QSO.")
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        try WatchPTTIntentBridge.shared.beginTimedPTT()
        return .result()
    }
}

struct ReverbQSOWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TimedWatchPTTIntent(),
            phrases: ["Transmit for 30 seconds with \(.applicationName)"],
            shortTitle: "30s Transmit",
            systemImageName: "mic.fill"
        )
    }
}

@MainActor
final class WatchPTTIntentBridge {
    static let shared = WatchPTTIntentBridge()
    weak var model: WatchAppModel?

    func beginTimedPTT() throws {
        guard let model else { throw WatchPTTIntentError.appNotReady }
        try model.beginTimedPTT()
    }
}

enum WatchPTTIntentError: LocalizedError {
    case appNotReady
    case transmitUnavailable

    var errorDescription: String? {
        switch self {
        case .appNotReady: "Open ReverbQSO and connect before transmitting."
        case .transmitUnavailable: "Connect first and wait for the other station to finish transmitting."
        }
    }
}
