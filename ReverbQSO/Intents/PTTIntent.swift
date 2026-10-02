// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) && !targetEnvironment(macCatalyst)
import AppIntents
import Foundation

struct TogglePTTIntent: AppIntent {
    static let title: LocalizedStringResource = "Push to Talk"
    static let description = IntentDescription("Start or stop transmitting in the current EchoLink QSO.")
    static var openAppWhenRun: Bool { true }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        try PTTIntentBridge.shared.toggle()
        return .result()
    }
}

struct ReverbQSOShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TogglePTTIntent(),
            phrases: ["Push to talk with \(.applicationName)"],
            shortTitle: "Push to Talk",
            systemImageName: "mic.fill"
        )
    }
}

@MainActor
final class PTTIntentBridge {
    static let shared = PTTIntentBridge()

    weak var qsoHub: QSOHub?

    var connectionService: EchoLinkConnectionService? { qsoHub?.activeService }
    private var timeoutTask: Task<Void, Never>?

    func toggle() throws {
        guard let service = connectionService,
              let session = service.session,
              session.state == .connected else {
            throw PTTIntentError.noActiveQSO
        }

        if session.isPTTActive {
            timeoutTask?.cancel()
            timeoutTask = nil
            service.sendPTT(active: false)
            return
        }

        guard service.canTransmit else {
            throw PTTIntentError.remoteStationTransmitting
        }
        service.sendPTT(active: true)
        let sessionID = session.id
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self, weak service] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard service?.session?.id == sessionID else { return }
            service?.sendPTT(active: false)
            self?.timeoutTask = nil
        }
    }
}

private enum PTTIntentError: LocalizedError {
    case noActiveQSO
    case remoteStationTransmitting

    var errorDescription: String? {
        switch self {
        case .noActiveQSO: "Connect to an EchoLink station before transmitting."
        case .remoteStationTransmitting: "Another station is transmitting. Try again when it finishes."
        }
    }
}
#endif
