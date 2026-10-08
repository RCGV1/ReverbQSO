// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class StationRFReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_424_200) // 10/8/2026 01:50 UTC

    func testParsesRealStyleRowWithoutClosingTRAndDecodesPlainText() throws {
        let html = page(row: row(
            callsign: "K1ABC-R", node: "123456", status: "Online",
            comment: "John &amp; Jane&#39;s &quot;Hill&quot;", updated: "10/8/2026 01:45"
        ))

        let report = try StationRFReportParser.report(
            in: Data(html.utf8), callsign: " k1abc-r ", nodeNumber: 123456, now: now
        )

        XCTAssertEqual(report, StationRFReport(
            callsign: "K1ABC-R", nodeNumber: 123456,
            updatedAt: Date(timeIntervalSince1970: 1_791_423_900),
            status: "Online", comment: "John & Jane's \"Hill\""
        ))
    }

    func testRejectsNodeMismatchEvenWhenCallsignMatches() throws {
        let html = page(row: row(callsign: "K1ABC-R", node: "999999"))
        XCTAssertNil(try StationRFReportParser.report(
            in: Data(html.utf8), callsign: "K1ABC-R", nodeNumber: 123456, now: now
        ))
    }

    func testMalformedAndFutureDatesAreUnknown() throws {
        for updated in ["not a date", "10/8/2026 01:56"] {
            let html = page(row: row(callsign: "K1ABC-R", node: "123456", updated: updated))
            XCTAssertNil(try StationRFReportParser.report(
                in: Data(html.utf8), callsign: "K1ABC-R", nodeNumber: 123456, now: now
            ))
        }
    }

    func testServerAsOfConstrainsFutureDateAndUsesUTC() throws {
        let html = page(asOf: "10/8/2026 01:40", row: row(
            callsign: "K1ABC-R", node: "123456", updated: "10/8/2026 01:46"
        ))
        XCTAssertNil(try StationRFReportParser.report(
            in: Data(html.utf8), callsign: "K1ABC-R", nodeNumber: 123456,
            now: now.addingTimeInterval(3_600)
        ))
    }

    func testTrustAllowsDefaultTLSPortAndRejectsAlternatePort() {
        XCTAssertTrue(StationRFReportParser.isTrusted(URL(string: "https://www.echolink.org/links.jsp")!))
        XCTAssertTrue(StationRFReportParser.isTrusted(URL(string: "https://www.echolink.org:443/links.jsp")!))
        XCTAssertFalse(StationRFReportParser.isTrusted(URL(string: "https://www.echolink.org:444/links.jsp")!))
    }

    @MainActor
    func testUnsupportedStationReturnsNilWithoutNetworkRequest() async throws {
        let transport = RFReportURLProtocol.Transport { _, _ in throw URLError(.badURL) }
        let session = makeSession(transport)
        defer { session.invalidateAndCancel() }
        let client = StationRFReportClient(session: session, now: { self.now })

        let report = try await client.report(for: station(type: .user))

        XCTAssertNil(report)
        XCTAssertEqual(transport.requestCount, 0)
    }

    @MainActor
    func testSelectsOnlyMatchingAlphabeticalPage() async throws {
        let transport = RFReportURLProtocol.Transport { request, _ in
            if request.url?.query == nil {
                let index = self.indexPage.replacingOccurrences(
                    of: "<table>",
                    with: "<a href=\"links.jsp?d=2&amp;gs=K5ZZ&amp;sel=gridsq\">K5ZZ</a><table>"
                )
                return Self.response(request, index)
            }
            return Self.response(request, self.page(row: self.row(callsign: "K6ABC-R", node: "123456")))
        }
        let session = makeSession(transport)
        defer { session.invalidateAndCancel() }
        let client = StationRFReportClient(session: session, now: { self.now })

        let report = try await client.report(for: station(callsign: "K6ABC-R"))

        XCTAssertEqual(report?.nodeNumber, 123456)
        XCTAssertEqual(transport.requestCount, 2)
        let routedURL = try XCTUnwrap(transport.requestURLs.last)
        XCTAssertEqual(URLComponents(url: routedURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "offset" })?.value, "800")
    }

    @MainActor
    func testCachesPositiveAndNegativeReportsForTTL() async throws {
        var clock = now
        let transport = RFReportURLProtocol.Transport { request, _ in
            Self.response(request, self.page(row: ""))
        }
        let session = makeSession(transport)
        defer { session.invalidateAndCancel() }
        let client = StationRFReportClient(session: session, now: { clock }, cacheTTL: 300)

        let first = try await client.report(for: station())
        XCTAssertNil(first)
        clock.addTimeInterval(299)
        let cached = try await client.report(for: station())
        XCTAssertNil(cached)
        XCTAssertEqual(transport.requestCount, 1)
        clock.addTimeInterval(2)
        let expired = try await client.report(for: station())
        XCTAssertNil(expired)
        XCTAssertEqual(transport.requestCount, 2)
    }

    @MainActor
    func testReportCacheDoesNotExtendUnderlyingPageFreshness() async throws {
        var clock = now
        let rows = row(callsign: "2E0AAA-L", node: "123456")
            + row(callsign: "2E0BBB-L", node: "123456")
        let transport = RFReportURLProtocol.Transport { request, _ in
            Self.response(request, self.page(row: rows))
        }
        let session = makeSession(transport)
        defer { session.invalidateAndCancel() }
        let client = StationRFReportClient(session: session, now: { clock }, cacheTTL: 300)

        _ = try await client.report(for: station(callsign: "2E0AAA-L"))
        clock.addTimeInterval(299)
        _ = try await client.report(for: station(callsign: "2E0BBB-L"))
        XCTAssertEqual(transport.requestCount, 1)
        clock.addTimeInterval(2)
        _ = try await client.report(for: station(callsign: "2E0BBB-L"))
        XCTAssertEqual(transport.requestCount, 2)
    }

    @MainActor
    func testConcurrentRequestsAreCoalesced() async throws {
        let transport = RFReportURLProtocol.Transport { request, _ in
            Thread.sleep(forTimeInterval: 0.05)
            return Self.response(request, self.page(row: self.row(callsign: "K5XYZ-R", node: "123456")))
        }
        let session = makeSession(transport)
        defer { session.invalidateAndCancel() }
        let client = StationRFReportClient(session: session, now: { self.now })

        let requested = station(callsign: "2E0ENN-L")
        async let first = client.report(for: requested)
        async let second = client.report(for: requested)
        _ = try await (first, second)
        XCTAssertEqual(transport.requestCount, 1)
    }

    @MainActor
    func testFailureIsNotCached() async throws {
        let transport = RFReportURLProtocol.Transport { request, attempt in
            if attempt == 1 { throw URLError(.timedOut) }
            return Self.response(request, self.page(row: self.row(callsign: "2E0ENN-L", node: "123456")))
        }
        let session = makeSession(transport)
        defer { session.invalidateAndCancel() }
        let client = StationRFReportClient(session: session, now: { self.now })

        do {
            _ = try await client.report(for: station(callsign: "2E0ENN-L"))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let recovered = try await client.report(for: station(callsign: "2E0ENN-L"))
        XCTAssertNotNil(recovered)
        XCTAssertEqual(transport.requestCount, 2)
    }

    @MainActor
    func testMalformedPageIsNotCachedAndNextRequestCanRecover() async throws {
        let transport = RFReportURLProtocol.Transport { request, attempt in
            if attempt == 1 { return Self.response(request, "<html>temporary error</html>") }
            return Self.response(request, self.page(row: self.row(callsign: "2E0ENN-L", node: "123456")))
        }
        let session = makeSession(transport)
        defer { session.invalidateAndCancel() }
        let client = StationRFReportClient(session: session, now: { self.now })

        do {
            _ = try await client.report(for: station(callsign: "2E0ENN-L"))
            XCTFail("Expected malformed page")
        } catch {
            XCTAssertEqual(error as? StationRFReportError, .malformedPage)
        }
        let report = try await client.report(for: station(callsign: "2E0ENN-L"))
        XCTAssertNotNil(report)
        XCTAssertEqual(transport.requestCount, 2)
    }

    @MainActor
    func testHTTPFailureAndOversizedPageThrow() async throws {
        let statusTransport = RFReportURLProtocol.Transport { request, _ in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let statusSession = makeSession(statusTransport)
        defer { statusSession.invalidateAndCancel() }
        do {
            _ = try await StationRFReportClient(session: statusSession).report(for: station())
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error as? StationRFReportError, .invalidResponse)
        }

        let largeTransport = RFReportURLProtocol.Transport { request, _ in
            Self.response(request, String(repeating: "x", count: 512 * 1024 + 1))
        }
        let largeSession = makeSession(largeTransport)
        defer { largeSession.invalidateAndCancel() }
        do {
            _ = try await StationRFReportClient(session: largeSession).report(for: station())
            XCTFail("Expected size error")
        } catch {
            XCTAssertEqual(error as? StationRFReportError, .responseTooLarge)
        }
    }

    @MainActor
    func testOffDomainJumpTargetThrowsWithoutFollowingIt() async throws {
        let transport = RFReportURLProtocol.Transport { request, _ in
            Self.response(request, self.page(
                row: "",
                links: #"<a href="https://example.com/links.jsp?d=2&amp;sel=all&amp;offset=800">K5T</a>"#
            ))
        }
        let session = makeSession(transport)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await StationRFReportClient(session: session, now: { self.now })
                .report(for: station())
            XCTFail("Expected trust error")
        } catch {
            XCTAssertEqual(error as? StationRFReportError, .untrustedURL)
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    private var indexPage: String {
        page(row: "", links: """
        <a href="links.jsp?d=2&amp;offset=200">DB0</a>
        <a href="links.jsp?title=&amp;d=2&amp;sel=all&amp;lat_fix=&amp;lon_fix=&amp;lat_deg=&amp;lat_min=&amp;lat_NS=&amp;lon_deg=&amp;lon_min=&amp;lon_EW=&amp;gs=&amp;offset=800">K5T</a>
        <a href="links.jsp?d=2&amp;offset=1000">KB7</a>
        """)
    }

    private func station(callsign: String = "K5XYZ-R", type: Station.StationType = .repeater) -> Station {
        Station(callsign: callsign, ipAddress: "192.0.2.1", type: type, nodeNumber: 123456)
    }

    private func page(asOf: String = "10/8/2026 01:45", row: String, links: String = "") -> String {
        "<html>As of: \(asOf) UTC<p>Jump to page: \(links)<br><table><tr><th>Last Update<br>(UTC)</th></tr>\(row)</table></html>"
    }

    private func row(
        callsign: String, node: String, status: String = "Online",
        comment: String = "Ready", updated: String = "10/8/2026 01:45"
    ) -> String {
        """
        <tr class="online"><td><b><a>\(callsign)</a></b></td><td>Site</td><td>\(node)</td>
        <td>37&deg; N<br>122&deg; W</td><td>CM87</td><td>Town</td><td>146.52</td>
        <td>100.0</td><td>5</td><td>10</td><td>0dB<br>omni</td>
        <td><font color=green>\(status)</font></td><td>\(comment)</td><td>\(updated)</td>
        """
    }

    private func makeSession(_ transport: RFReportURLProtocol.Transport) -> URLSession {
        RFReportURLProtocol.transport = transport
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RFReportURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(_ request: URLRequest, _ body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
}

private final class RFReportURLProtocol: URLProtocol, @unchecked Sendable {
    final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var urls: [URL] = []
        let handler: (URLRequest, Int) throws -> (HTTPURLResponse, Data)

        init(handler: @escaping (URLRequest, Int) throws -> (HTTPURLResponse, Data)) { self.handler = handler }
        var requestCount: Int { lock.withLock { count } }
        var requestURLs: [URL] { lock.withLock { urls } }
        func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data) {
            let attempt = lock.withLock {
                count += 1
                if let url = request.url { urls.append(url) }
                return count
            }
            return try handler(request, attempt)
        }
    }

    nonisolated(unsafe) static var transport: Transport!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.transport.respond(to: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
