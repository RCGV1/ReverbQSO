// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class EchoLinkPublicProxyListTests: XCTestCase {
    func testTLSFailureUsesPreviouslyVerifiedProxyListAfterReload() async throws {
        let suite = "PublicProxyListTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstSession = proxyListSession("success")
        defer { firstSession.invalidateAndCancel() }
        let verified = try await EchoLinkPublicProxyListClient.fetch(session: firstSession, defaults: defaults)
        let reloadedSession = proxyListSession("tlsFailure")
        defer { reloadedSession.invalidateAndCancel() }
        let recovered = try await EchoLinkPublicProxyListClient.fetch(session: reloadedSession, defaults: defaults)
        XCTAssertEqual(recovered, verified)
    }

    func testTLSFailureWithoutVerifiedEndpointsStillFails() async {
        let suite = "PublicProxyListTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = proxyListSession("tlsFailure")
        defer { session.invalidateAndCancel() }
        do {
            _ = try await EchoLinkPublicProxyListClient.fetch(session: session, defaults: defaults)
            XCTFail("Do not invent endpoints or disable TLS verification")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .secureConnectionFailed)
        }
    }

    func testExpiredProxyListDoesNotHideTLSFailure() async throws {
        let suite = "PublicProxyListTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = proxyListSession("success")
        let failed = proxyListSession("tlsFailure")
        defer { good.invalidateAndCancel(); failed.invalidateAndCancel() }
        let now = Date()
        _ = try await EchoLinkPublicProxyListClient.fetch(session: good, defaults: defaults,
            now: now.addingTimeInterval(-25 * 60 * 60))
        do {
            _ = try await EchoLinkPublicProxyListClient.fetch(session: failed, defaults: defaults, now: now)
            XCTFail("Expired proxy endpoints must not be used indefinitely")
        } catch { XCTAssertEqual((error as? URLError)?.code, .secureConnectionFailed) }
    }

    func testCancellationDoesNotUseCachedProxyList() async throws {
        let suite = "PublicProxyListTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = proxyListSession("success")
        let cancelled = proxyListSession("cancelled")
        defer { good.invalidateAndCancel(); cancelled.invalidateAndCancel() }
        _ = try await EchoLinkPublicProxyListClient.fetch(session: good, defaults: defaults)
        do {
            _ = try await EchoLinkPublicProxyListClient.fetch(session: cancelled, defaults: defaults)
            XCTFail("Cancelled login must not resume using cached endpoints")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
    }

    private func proxyListSession(_ response: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyListURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Proxy-Test": response]
        return URLSession(configuration: configuration)
    }

    func testParsesReadyAndBusyRowsWithExplicitPorts() throws {
        let html = """
        <tr class="normal-row">
          <td>W1AW Proxy&nbsp;</td><td>192.0.2.10&nbsp;</td><td>8100&nbsp;</td>
          <td>12:30&nbsp;</td><td><font color="Green">Ready&nbsp;</font></td>
          <td>1.2.3&nbsp;</td><td>Public test &amp; demo&nbsp;</td>
        </tr>
        <tr class="normal-row">
          <td>K1ABC&nbsp;</td><td>198.51.100.20&nbsp;</td><td>443&nbsp;</td>
          <td>12:31&nbsp;</td><td><font color="Red">Busy&nbsp;</font></td>
          <td>1.2.3&nbsp;</td><td>Alternate port&nbsp;</td>
        </tr>
        """

        let proxies = EchoLinkPublicProxyListParser.parse(Data(html.utf8))

        XCTAssertEqual(proxies, [
            EchoLinkPublicProxy(name: "W1AW Proxy", host: "192.0.2.10", port: 8100, isReady: true),
            EchoLinkPublicProxy(name: "K1ABC", host: "198.51.100.20", port: 443, isReady: false),
        ])
    }

    func testIgnoresMalformedAndBlacklistedRows() {
        let html = """
        <tr class="blacklist-row"><td>Blocked</td><td>192.0.2.1</td><td>8100</td><td>x</td><td>Ready</td></tr>
        <tr class="normal-row"><td>Missing port</td><td>192.0.2.2</td><td></td><td>x</td><td>Ready</td></tr>
        <tr class="normal-row"><td>Bad host</td><td>not a host!</td><td>8100</td><td>x</td><td>Ready</td></tr>
        """

        XCTAssertTrue(EchoLinkPublicProxyListParser.parse(Data(html.utf8)).isEmpty)
    }

    func testReadyCandidatesPreferSavedHostThenBoundFallbacks() throws {
        let proxies = [
            EchoLinkPublicProxy(name: "First", host: "192.0.2.1", port: 8100, isReady: true),
            EchoLinkPublicProxy(name: "Busy", host: "192.0.2.2", port: 8100, isReady: false),
            EchoLinkPublicProxy(name: "Preferred", host: "192.0.2.3", port: 443, isReady: true),
            EchoLinkPublicProxy(name: "Third", host: "192.0.2.4", port: 8100, isReady: true),
            EchoLinkPublicProxy(name: "Beyond limit", host: "192.0.2.5", port: 8100, isReady: true),
        ]

        let candidates = try EchoLinkPublicProxyListClient.readyCandidates(
            from: proxies,
            preferredHost: "192.0.2.3",
            limit: 3
        )

        XCTAssertEqual(candidates.map(\.host), ["192.0.2.3", "192.0.2.1", "192.0.2.4"])
    }

    func testReadyCandidatesRejectEmptyReadySet() {
        let proxies = [
            EchoLinkPublicProxy(name: "Busy", host: "192.0.2.2", port: 8100, isReady: false),
        ]

        XCTAssertThrowsError(
            try EchoLinkPublicProxyListClient.readyCandidates(from: proxies, preferredHost: nil)
        ) { error in
            XCTAssertEqual(error as? EchoLinkPublicProxyListClient.ListError, .noReadyProxies)
        }
    }
}

private final class ProxyListURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.value(forHTTPHeaderField: "X-Proxy-Test") == "cancelled" {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if request.value(forHTTPHeaderField: "X-Proxy-Test") == "tlsFailure" {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<tr class=\"normal-row\"><td>Test</td><td>192.0.2.10</td><td>8100</td><td>x</td><td>Ready</td></tr>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
