// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct EchoLinkPublicProxy: Identifiable, Equatable, Hashable, Sendable, Codable {
    var id: String { "\(host):\(port)" }
    let name: String
    let host: String
    let port: UInt16
    let isReady: Bool
}

enum EchoLinkPublicProxyListParser {
    static func parse(_ data: Data) -> [EchoLinkPublicProxy] {
        guard let html = String(data: data, encoding: .utf8),
              let rowExpression = try? NSRegularExpression(
                pattern: #"<tr\s+class\s*=\s*[\"']normal-row[\"'][^>]*>(.*?)</tr>"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
              ),
              let cellExpression = try? NSRegularExpression(
                pattern: #"<td[^>]*>(.*?)</td>"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
              ) else { return [] }

        let htmlRange = NSRange(html.startIndex..., in: html)
        return rowExpression.matches(in: html, range: htmlRange).compactMap { rowMatch -> EchoLinkPublicProxy? in
            guard let rowRange = Range(rowMatch.range(at: 1), in: html) else { return nil }
            let row = String(html[rowRange])
            let cells = cellExpression.matches(in: row, range: NSRange(row.startIndex..., in: row)).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: row) else { return nil }
                return plainText(String(row[range]))
            }
            guard cells.count >= 5,
                  !cells[0].isEmpty,
                  isValidHost(cells[1]),
                  let port = UInt16(cells[2]), port != 0 else { return nil }
            return EchoLinkPublicProxy(
                name: cells[0],
                host: cells[1],
                port: port,
                isReady: cells[4].localizedCaseInsensitiveCompare("Ready") == .orderedSame
            )
        }
    }

    private static func plainText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
    }
}

enum EchoLinkPublicProxyListClient {
    static let listURL = URL(string: "https://www.echolink.org/proxylist.jsp?lang=en")!
    static let defaultCandidateLimit = 3
    private static let cacheKey = "network.publicProxyListCache"
    private static let cacheLifetime: TimeInterval = 24 * 60 * 60

    private struct CachedList: Codable {
        let fetchedAt: Date
        let proxies: [EchoLinkPublicProxy]
    }

    enum ListError: Swift.Error, LocalizedError, Equatable {
        case invalidResponse
        case noReadyProxies

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The EchoLink public proxy list could not be downloaded."
            case .noReadyProxies: return "The EchoLink public proxy list has no ready servers."
            }
        }
    }

    static func fetch(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) async throws -> [EchoLinkPublicProxy] {
        do {
            // Bound discovery separately from proxy authentication. A network
            // change must not leave launch waiting on URLSession's long default.
            let request = URLRequest(url: listURL, timeoutInterval: 10)
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw ListError.invalidResponse
            }
            let proxies = EchoLinkPublicProxyListParser.parse(data)
            guard !proxies.isEmpty else { throw ListError.invalidResponse }
            if proxies.contains(where: \.isReady),
               let encoded = try? JSONEncoder().encode(CachedList(fetchedAt: now, proxies: proxies)) {
                defaults.set(encoded, forKey: cacheKey)
            }
            return proxies
        } catch {
            // Endpoints come only from a successfully verified HTTPS response.
            // Keep certificate checks intact; never fall back to plain HTTP.
            try Task.checkCancellation()
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled,
                  let data = defaults.data(forKey: cacheKey),
                  let cached = try? JSONDecoder().decode(CachedList.self, from: data),
                  (0...cacheLifetime).contains(now.timeIntervalSince(cached.fetchedAt)),
                  cached.proxies.contains(where: \.isReady) else { throw error }
            return cached.proxies
        }
    }

    static func selectReadyProxy(
        preferredHost: String?,
        session: URLSession = .shared
    ) async throws -> EchoLinkPublicProxy {
        let ready = try await fetch(session: session).filter(\.isReady)
        if let preferredHost,
           let preferred = ready.first(where: { $0.host == preferredHost }) {
            return preferred
        }
        guard let proxy = ready.first else { throw ListError.noReadyProxies }
        return proxy
    }

    static func readyCandidates(
        from proxies: [EchoLinkPublicProxy],
        preferredHost: String?,
        limit: Int = defaultCandidateLimit
    ) throws -> [EchoLinkPublicProxy] {
        guard limit > 0 else { throw ListError.noReadyProxies }
        let ready = proxies.filter(\.isReady)
        guard !ready.isEmpty else { throw ListError.noReadyProxies }

        var ordered: [EchoLinkPublicProxy] = []
        if let preferredHost,
           let preferred = ready.first(where: { $0.host == preferredHost }) {
            ordered.append(preferred)
        }
        ordered.append(contentsOf: ready.filter { proxy in
            !ordered.contains(where: { $0.id == proxy.id })
        })
        return Array(ordered.prefix(limit))
    }

    static func fetchReadyCandidates(
        preferredHost: String?,
        limit: Int = defaultCandidateLimit,
        session: URLSession = .shared
    ) async throws -> [EchoLinkPublicProxy] {
        try readyCandidates(
            from: await fetch(session: session),
            preferredHost: preferredHost,
            limit: limit
        )
    }
}
