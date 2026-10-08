// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct StationRFReport: Equatable, Sendable {
    let callsign: String
    let nodeNumber: Int
    let updatedAt: Date
    let status: String
    let comment: String
}

enum StationRFReportError: Error, Equatable {
    case invalidResponse
    case responseTooLarge
    case untrustedURL
    case malformedPage
}

enum StationRFReportParser {
    private static let maximumSize = 512 * 1024

    static func report(
        in data: Data,
        callsign: String,
        nodeNumber: Int,
        now: Date
    ) throws -> StationRFReport? {
        guard data.count <= maximumSize else { throw StationRFReportError.responseTooLarge }
        guard let html = String(data: data, encoding: .utf8),
              html.range(of: "<html", options: .caseInsensitive) != nil else {
            throw StationRFReportError.malformedPage
        }

        let requestedCallsign = normalizeCallsign(callsign)
        let serverAsOf = firstCapture(
            #"As\s+of:\s*([0-9]{1,2}/[0-9]{1,2}/[0-9]{4}\s+[0-9]{2}:[0-9]{2})\s+UTC"#,
            in: html
        ).flatMap(parseUTCDate)
        let referenceDate = min(serverAsOf ?? now, now)

        for row in matches(#"(?is)<tr\b[^>]*class\s*=\s*[\"']?(?:online|offline)[\"']?[^>]*>(.*?)(?=<tr\b|</table\s*>)"#, in: html) {
            let cells = matches(#"(?is)<td\b[^>]*>(.*?)(?=</td\s*>)"#, in: row)
            guard cells.count == 14 else { continue }

            let rowCallsign = plainText(cells[0])
            guard normalizeCallsign(rowCallsign) == requestedCallsign,
                  Int(plainText(cells[2])) == nodeNumber,
                  let updatedAt = parseUTCDate(plainText(cells[13])),
                  updatedAt <= referenceDate.addingTimeInterval(5 * 60) else { continue }

            return StationRFReport(
                callsign: rowCallsign,
                nodeNumber: nodeNumber,
                updatedAt: updatedAt,
                status: plainText(cells[11]),
                comment: plainText(cells[12])
            )
        }
        return nil
    }

    static func pageURL(in data: Data, for callsign: String, relativeTo baseURL: URL) throws -> URL? {
        guard data.count <= maximumSize,
              let html = String(data: data, encoding: .utf8),
              html.range(of: "<html", options: .caseInsensitive) != nil else {
            throw data.count > maximumSize
                ? StationRFReportError.responseTooLarge
                : StationRFReportError.malformedPage
        }

        let requested = normalizeCallsign(callsign)
        guard let navigation = firstCapture(
            #"(?is)Jump\s+to\s+page\s*:(.*?)(?:<br\s*/?>|<table\b)"#,
            in: html
        ) else { return nil }
        var selected: (marker: String, url: URL)?
        for anchor in anchors(in: navigation) {
            let marker = normalizeCallsign(plainText(anchor.text))
            guard !marker.isEmpty, marker <= requested,
                  let url = URL(string: decodeEntities(anchor.href), relativeTo: baseURL)?.absoluteURL,
                  url.path == "/links.jsp",
                  isJumpPageURL(url) else { continue }
            if selected == nil || marker > selected!.marker { selected = (marker, url) }
        }
        if let selected, !isTrusted(selected.url) { throw StationRFReportError.untrustedURL }
        return selected?.url
    }

    static func isTrusted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "www.echolink.org"
            && url.path == "/links.jsp"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    static func validatePage(_ data: Data) throws {
        guard data.count <= maximumSize else { throw StationRFReportError.responseTooLarge }
        guard let html = String(data: data, encoding: .utf8),
              html.range(of: "<html", options: .caseInsensitive) != nil,
              html.range(of: #"As\s+of\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil,
              html.range(of: #"Last\s*Update(?:\s*<br\s*/?>)?\s*\(UTC\)"#,
                         options: [.regularExpression, .caseInsensitive]) != nil else {
            throw StationRFReportError.malformedPage
        }
    }

    private static func isJumpPageURL(_ url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let offsetText = items.first(where: { $0.name.lowercased() == "offset" })?.value,
              let offset = Int(offsetText), offset > 0 else { return false }
        let values = Dictionary(grouping: items, by: { $0.name.lowercased() })
        let searchFields = [
            "gs", "city", "state", "country", "lat_fix", "lon_fix",
            "lat_deg", "lat_min", "lat_ns", "lon_deg", "lon_min", "lon_ew",
        ]
        guard !searchFields.contains(where: { field in
            values[field]?.contains(where: { !($0.value ?? "").isEmpty }) == true
        }) else { return false }
        if let d = values["d"]?.last?.value, d != "2" { return false }
        if let selection = values["sel"]?.last?.value?.lowercased(), selection != "all" { return false }
        return true
    }

    private static func normalizeCallsign(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func parseUTCDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "M/d/yyyy HH:mm"
        formatter.isLenient = false
        return formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func plainText(_ html: String) -> String {
        let breaks = html.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: " ", options: .regularExpression)
        let withoutTags = breaks.replacingOccurrences(of: #"(?s)<[^>]*>"#, with: "", options: .regularExpression)
        return decodeEntities(withoutTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(#(?:x[0-9A-Fa-f]+|[0-9]+)|[A-Za-z]+);"#) else { return input }
        var output = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let whole = Range(match.range(at: 0), in: input),
                  let bodyRange = Range(match.range(at: 1), in: input) else { continue }
            let body = String(input[bodyRange])
            let replacement: String?
            switch body.lowercased() {
            case "amp": replacement = "&"
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            case "nbsp": replacement = " "
            case "deg": replacement = "°"
            default:
                let radix = body.lowercased().hasPrefix("#x") ? 16 : 10
                let digits = body.dropFirst(radix == 16 ? 2 : 1)
                replacement = UInt32(digits, radix: radix).flatMap(UnicodeScalar.init).map(String.init)
            }
            if let replacement { output.replaceSubrange(whole, with: replacement) }
        }
        return output
    }

    private static func matches(_ pattern: String, in input: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap {
            guard $0.numberOfRanges > 1, let range = Range($0.range(at: 1), in: input) else { return nil }
            return String(input[range])
        }
    }

    private static func firstCapture(_ pattern: String, in input: String) -> String? {
        matches(pattern, in: input).first
    }

    private static func anchors(in input: String) -> [(href: String, text: String)] {
        let pattern = #"(?is)<a\b[^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap {
            guard let href = Range($0.range(at: 1), in: input),
                  let text = Range($0.range(at: 2), in: input) else { return nil }
            return (String(input[href]), String(input[text]))
        }
    }
}

private final class StationRFReportRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.flatMap(StationRFReportParser.isTrusted) == true ? request : nil)
    }
}

@MainActor
final class StationRFReportClient {
    static let shared = StationRFReportClient()

    private struct CacheEntry: Sendable {
        let data: Data
        let storedAt: Date
    }
    private struct ReportKey: Hashable {
        let callsign: String
        let nodeNumber: Int
    }
    private struct ReportCacheEntry: Sendable {
        let report: StationRFReport?
        let storedAt: Date
    }

    private static let firstPageURL = URL(string: "https://www.echolink.org/links.jsp")!
    private let session: URLSession
    private let now: () -> Date
    private let cacheTTL: TimeInterval
    private var pageCache: [URL: CacheEntry] = [:]
    private var reportCache: [ReportKey: ReportCacheEntry] = [:]
    private var inFlight: [ReportKey: Task<ReportCacheEntry, Error>] = [:]

    init(
        session: URLSession = StationRFReportClient.secureSession(),
        now: @escaping () -> Date = { Date() },
        cacheTTL: TimeInterval = 5 * 60
    ) {
        self.session = session
        self.now = now
        self.cacheTTL = cacheTTL
    }

    func report(for station: Station) async throws -> StationRFReport? {
        guard (station.type == .link || station.type == .repeater), station.nodeNumber > 0 else { return nil }
        let key = ReportKey(
            callsign: station.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            nodeNumber: station.nodeNumber
        )
        let currentTime = now()
        if let cached = reportCache[key], currentTime.timeIntervalSince(cached.storedAt) < cacheTTL {
            return cached.report
        }
        if let existing = inFlight[key] {
            let entry = try await existing.value
            return entry.report
        }

        let task = Task { try await self.loadReport(for: station, currentTime: currentTime) }
        inFlight[key] = task
        do {
            let entry = try await task.value
            reportCache[key] = entry
            inFlight[key] = nil
            return entry.report
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    private func loadReport(for station: Station, currentTime: Date) async throws -> ReportCacheEntry {
        let firstPage = try await data(from: Self.firstPageURL)
        let callsign = station.callsign
        let nodeNumber = station.nodeNumber
        let firstPageURL = Self.firstPageURL
        let pageURL = try await Task.detached(priority: .utility) {
            try StationRFReportParser.pageURL(
                in: firstPage.data, for: callsign, relativeTo: firstPageURL
            ) ?? firstPageURL
        }.value
        let selectedPage = pageURL == firstPageURL ? firstPage : try await data(from: pageURL)
        let report = try await Task.detached(priority: .utility) {
            try StationRFReportParser.report(
                in: selectedPage.data, callsign: callsign, nodeNumber: nodeNumber, now: currentTime
            )
        }.value
        return ReportCacheEntry(report: report, storedAt: selectedPage.storedAt)
    }

    private func data(from url: URL) async throws -> CacheEntry {
        guard StationRFReportParser.isTrusted(url) else { throw StationRFReportError.untrustedURL }
        if let cached = pageCache[url], now().timeIntervalSince(cached.storedAt) < cacheTTL { return cached }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard data.count <= 512 * 1024 else { throw StationRFReportError.responseTooLarge }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw StationRFReportError.invalidResponse }
        guard let finalURL = http.url, StationRFReportParser.isTrusted(finalURL) else {
            throw StationRFReportError.untrustedURL
        }
        try StationRFReportParser.validatePage(data)
        let entry = CacheEntry(data: data, storedAt: now())
        pageCache[url] = entry
        return entry
    }

    nonisolated private static func secureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: StationRFReportRedirectDelegate(), delegateQueue: nil)
    }
}
