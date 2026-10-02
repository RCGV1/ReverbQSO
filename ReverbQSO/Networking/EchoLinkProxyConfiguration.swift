// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum EchoLinkNetworkMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case direct
    case relay
    case publicProxy
    case customProxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .direct: return "Direct"
        case .relay: return "Relay"
        case .publicProxy: return "Public Proxy"
        case .customProxy: return "Custom Proxy"
        }
    }
}

struct EchoLinkProxyConfiguration: Equatable, Sendable {
    static let defaultPort: UInt16 = 8100
    static let enabledKey = "echolinkProxyEnabled"
    static let modeKey = "echolinkNetworkMode"
    static let hostKey = "echolinkProxyHost"
    static let portKey = "echolinkProxyPort"
    static let publicHostKey = "echolinkPublicProxyHost"
    static let publicPortKey = "echolinkPublicProxyPort"

    let mode: EchoLinkNetworkMode
    let host: String
    let port: UInt16
    let password: String

    var isEnabled: Bool { mode == .publicProxy || mode == .customProxy }

    static func load(defaults: UserDefaults = .standard) -> EchoLinkProxyConfiguration {
        let mode = defaults.string(forKey: modeKey).flatMap(EchoLinkNetworkMode.init(rawValue:))
            ?? (defaults.bool(forKey: enabledKey) ? .customProxy : .direct)
        let isPublic = mode == .publicProxy || mode == .automatic
        let storedPort = defaults.integer(forKey: isPublic ? publicPortKey : portKey)
        let port = UInt16(exactly: storedPort).flatMap { $0 == 0 ? nil : $0 } ?? defaultPort
        return EchoLinkProxyConfiguration(
            mode: mode,
            host: defaults.string(forKey: isPublic ? publicHostKey : hostKey) ?? "",
            port: port,
            password: isPublic ? "PUBLIC" : (KeychainService.loadProxyPassword() ?? "")
        )
    }

    func resolvingPublicProxy() async throws -> EchoLinkProxyConfiguration {
        guard mode == .publicProxy else { return self }
        let proxy = try await EchoLinkPublicProxyListClient.selectReadyProxy(
            preferredHost: host.isEmpty ? nil : host
        )
        return EchoLinkProxyConfiguration(
            mode: .publicProxy,
            host: proxy.host,
            port: proxy.port,
            password: "PUBLIC"
        )
    }

    func resolvingProxyCandidates(limit: Int = EchoLinkPublicProxyListClient.defaultCandidateLimit) async throws -> [EchoLinkProxyConfiguration] {
        guard mode == .publicProxy else { return [self] }
        return try await EchoLinkPublicProxyListClient.fetchReadyCandidates(
            preferredHost: host.isEmpty ? nil : host,
            limit: limit
        ).map { proxy in
            EchoLinkProxyConfiguration(
                mode: .publicProxy,
                host: proxy.host,
                port: proxy.port,
                password: "PUBLIC"
            )
        }
    }
}
