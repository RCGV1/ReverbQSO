// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI

/// View model for the Settings screen.
///
/// Loads and automatically persists the selected connection method.
@MainActor
final class SettingsViewModel: ObservableObject {

    // MARK: - EchoLink Proxy

    @Published var networkMode: EchoLinkNetworkMode = .direct
    @Published private(set) var activeNetworkMode: EchoLinkNetworkMode = .direct
    @Published var proxyHost = ""
    @Published var proxyPort = String(EchoLinkProxyConfiguration.defaultPort)
    @Published var proxyPassword = ""
    @Published var proxySettingsError: String?
    @Published var publicProxies: [EchoLinkPublicProxy] = []
    @Published var selectedPublicProxyID = ""
    @Published var isLoadingPublicProxies = false
    private var pendingSave: Task<Void, Never>?
    private var isLocalDemo = false
    private var hasLoadedSettings = false

    // MARK: - App Info

    let appVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }()

    let githubURL = URL(string: "https://github.com/RCGV1/ReverbQSO")!

    // MARK: - Lifecycle

    init(loadSettings: Bool = true) {
        #if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            return
        }
        #endif
        if loadSettings { loadProxySettings(); hasLoadedSettings = true }
    }

    func setDemoMode(_ enabled: Bool) {
        guard enabled != isLocalDemo || !hasLoadedSettings else { return }
        pendingSave?.cancel()
        pendingSave = nil
        isLocalDemo = enabled
        hasLoadedSettings = true
        publicProxies = []
        proxySettingsError = nil
        if enabled {
            networkMode = .direct
            activeNetworkMode = .direct
            proxyHost = ""
            proxyPassword = ""
            proxyPort = String(EchoLinkProxyConfiguration.defaultPort)
            selectedPublicProxyID = ""
        } else {
            loadProxySettings()
        }
    }

    // MARK: - Actions

    func scheduleProxySettingsSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.saveProxySettings()
        }
    }

    func flushPendingSettingsSave() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        saveProxySettings()
    }

    private func saveProxySettings() {
        if isLocalDemo {
            activeNetworkMode = networkMode
            proxySettingsError = nil
            pendingSave = nil
            return
        }
        #if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            activeNetworkMode = networkMode
            proxySettingsError = nil
            return
        }
        #endif
        let trimmedHost = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if networkMode == .customProxy,
           trimmedHost.isEmpty || (UInt16(proxyPort).map { $0 != 0 } != true) || proxyPassword.isEmpty {
            proxySettingsError = nil
            return
        }

        let publicProxy = publicProxies.first(where: { $0.id == selectedPublicProxyID && $0.isReady })
        guard ProxySettingsPersistence.save(
            mode: networkMode,
            host: trimmedHost,
            port: UInt16(proxyPort) ?? EchoLinkProxyConfiguration.defaultPort,
            publicProxy: publicProxy,
            password: proxyPassword,
            defaults: .standard,
            savePassword: KeychainService.saveProxyPassword
        ) else {
            proxySettingsError = "The proxy password could not be saved to Keychain."
            return
        }

        proxyHost = trimmedHost
        activeNetworkMode = networkMode
        proxySettingsError = nil
        pendingSave = nil
    }

    func refreshPublicProxies() async {
        if isLocalDemo {
            publicProxies = [EchoLinkPublicProxy(name: "Community Proxy", host: "192.0.2.20", port: 8100, isReady: true)]
            proxySettingsError = nil
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            publicProxies = []
            proxySettingsError = "Public proxy lookup is disabled in simulator demo mode."
            return
        }
#endif
        isLoadingPublicProxies = true
        defer { isLoadingPublicProxies = false }
        do {
            let proxies = try await EchoLinkPublicProxyListClient.fetch()
            publicProxies = proxies.sorted {
                if $0.isReady != $1.isReady { return $0.isReady && !$1.isReady }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if !publicProxies.contains(where: { $0.id == selectedPublicProxyID && $0.isReady }) {
                selectedPublicProxyID = ""
            }
            proxySettingsError = nil
        } catch {
            proxySettingsError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func loadProxySettings() {
        let configuration = EchoLinkProxyConfiguration.load()
        let defaults = UserDefaults.standard
        networkMode = configuration.mode
        activeNetworkMode = configuration.mode
        proxyHost = defaults.string(forKey: EchoLinkProxyConfiguration.hostKey) ?? ""
        let storedCustomPort = UInt16(exactly: defaults.integer(forKey: EchoLinkProxyConfiguration.portKey))
        proxyPort = String(storedCustomPort.flatMap { $0 == 0 ? nil : $0 } ?? EchoLinkProxyConfiguration.defaultPort)
        proxyPassword = KeychainService.loadProxyPassword() ?? ""
        if configuration.mode == .publicProxy {
            selectedPublicProxyID = "\(configuration.host):\(configuration.port)"
        }
    }
}

enum ProxySettingsPersistence {
    static func save(
        mode: EchoLinkNetworkMode,
        host: String,
        port: UInt16,
        publicProxy: EchoLinkPublicProxy?,
        password: String,
        defaults: UserDefaults,
        savePassword: (String) -> Bool
    ) -> Bool {
        if mode == .customProxy && !savePassword(password) { return false }

        defaults.set(mode.rawValue, forKey: EchoLinkProxyConfiguration.modeKey)
        defaults.set(mode == .publicProxy || mode == .customProxy, forKey: EchoLinkProxyConfiguration.enabledKey)
        defaults.set(host, forKey: EchoLinkProxyConfiguration.hostKey)
        defaults.set(Int(port), forKey: EchoLinkProxyConfiguration.portKey)
        if mode == .publicProxy {
            defaults.set(publicProxy?.host ?? "", forKey: EchoLinkProxyConfiguration.publicHostKey)
            defaults.set(Int(publicProxy?.port ?? EchoLinkProxyConfiguration.defaultPort),
                         forKey: EchoLinkProxyConfiguration.publicPortKey)
        }
        return true
    }
}
