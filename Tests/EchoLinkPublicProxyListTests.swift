// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class EchoLinkPublicProxyListTests: XCTestCase {
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
