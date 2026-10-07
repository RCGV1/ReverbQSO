// SPDX-License-Identifier: GPL-3.0-or-later

#if targetEnvironment(macCatalyst)
import Combine
import Foundation
import ServiceManagement

/// Manages the native menu bar login item bundled inside the Catalyst app.
@MainActor
final class MacMenuBarLaunchService: ObservableObject {
    static let helperBundleIdentifier = "com.benjaminfaershtein.OpenEchoLink.menubar"

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?

    private let service = SMAppService.loginItem(identifier: helperBundleIdentifier)

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool { status == .requiresApproval }

    init() {
        refresh()
    }

    func refresh() {
        status = service.status
        if status != .notFound { errorMessage = nil }
        if status == .notFound {
            errorMessage = "The bundled menu bar app could not be found."
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                if service.status == .notRegistered { try service.register() }
            } else if service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        status = service.status
        if status == .requiresApproval {
            errorMessage = "Allow ReverbQSO Menu Bar in System Settings to finish enabling it."
        } else if status == .notFound {
            errorMessage = "The bundled menu bar app could not be found."
        }
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
#endif
