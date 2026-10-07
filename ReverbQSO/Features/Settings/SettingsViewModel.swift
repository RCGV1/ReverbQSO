// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI

enum ReverbQSOLinks {
    static let sourceCode = URL(string: "https://github.com/RCGV1/ReverbQSO")!
    static let privacyPolicy = URL(string: "https://gist.github.com/RCGV1/3dae4fde3b46ee1fd72e6bacf9b2e9b1")!
    static let echoLinkSupport = URL(string: "https://secure.echolink.org/support.htm")!
    static let echoLinkSupportSubmission = URL(string: "https://secure.echolink.org/support_confirm.jsp")!
}

enum EchoLinkSupportRedirectPolicy {
    static func allows(originalURL: URL?, redirectURL: URL?) -> Bool {
        originalURL?.host?.lowercased() == redirectURL?.host?.lowercased()
            && redirectURL?.scheme?.lowercased() == "https"
    }
}

private final class EchoLinkSupportURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            EchoLinkSupportRedirectPolicy.allows(
                originalURL: task.originalRequest?.url,
                redirectURL: request.url
            ) ? request : nil
        )
    }
}

struct EchoLinkAccountDeletionRequester {
    enum RequestError: LocalizedError {
        case invalidEmail
        case rejected

        var errorDescription: String? {
            switch self {
            case .invalidEmail:
                return "Enter the email address associated with your EchoLink account."
            case .rejected:
                return "EchoLink did not accept the request. You can try again or use the official support form."
            }
        }
    }

    let session: URLSession

    static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(
            configuration: configuration,
            delegate: EchoLinkSupportURLSessionDelegate(),
            delegateQueue: nil
        )
    }()

    init(session: URLSession = secureSession) {
        self.session = session
    }

    func submit(callsign: String, email: String) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            throw RequestError.invalidEmail
        }

        let request = Self.makeRequest(callsign: callsign, email: trimmedEmail)

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw RequestError.rejected
        }
        let responseText = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        guard Self.isConfirmedSubmissionResponse(responseText) else {
            throw RequestError.rejected
        }
    }

    static func isConfirmedSubmissionResponse(_ responseText: String) -> Bool {
        let isConfirmationPage = responseText.localizedCaseInsensitiveContains("<title>Support Confirmation</title>")
        let hasSentAcknowledgement = [
            "your message has been sent",
            "message was sent",
            "question or comment has been sent",
            "thank you for contacting EchoLink support"
        ].contains { responseText.localizedCaseInsensitiveContains($0) }
        let hasChallenge = responseText.localizedCaseInsensitiveContains("captcha")
            || responseText.localizedCaseInsensitiveContains("g-recaptcha")
        let hasValidationFailure = responseText.localizedCaseInsensitiveContains("please click back")
            || responseText.localizedCaseInsensitiveContains("no e-mail address was provided")
        return isConfirmationPage && hasSentAcknowledgement && !hasChallenge && !hasValidationFailure
    }

    static func makeRequest(callsign: String, email: String) -> URLRequest {
        let requestText = "Please delete my EchoLink account and registration for callsign \(callsign). Please confirm when the deletion is complete."
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "Callsign", value: callsign),
            URLQueryItem(name: "field399", value: email),
            URLQueryItem(name: "WinVer", value: "iOS"),
            URLQueryItem(name: "ELVer", value: "Other"),
            URLQueryItem(name: "Category", value: "general"),
            URLQueryItem(name: "Question", value: requestText),
            URLQueryItem(name: "B1", value: "Send This Message")
        ]

        var request = URLRequest(url: ReverbQSOLinks.echoLinkSupportSubmission)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return request
    }
}

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

    let githubURL = ReverbQSOLinks.sourceCode

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
