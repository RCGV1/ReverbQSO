// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class EchoLinkRegistrationClientTests: XCTestCase {
    func testRegistrationRequestUsesNativeFormContract() throws {
        let request = try EchoLinkRegistrationClient(softwareTag: "0123456789ABCDEF012345").makeRequest(
            callsign: " n0call ", email: " OP@example.org ", password: "pass5word"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://www.echolink.org/validation/registerNode.jsp")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = try XCTUnwrap(request.httpBody)
        let form = try XCTUnwrap(String(data: body, encoding: .utf8))
        let fields = try XCTUnwrap(URLComponents(string: "https://example.org/?\(form)")?.queryItems)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") }), [
            "callsign": "N0CALL", "password": "PASS5WORD", "location": "ReverbQSO User",
            "swtag": "0123456789ABCDEF012345", "email": "op@example.org", "apiver": "2"
        ])
    }

    func testSoftwareTagIsStableForAnInstallation() throws {
        let suiteName = "registration-tag-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = EchoLinkRegistrationClient.loadOrCreateSoftwareTag(defaults: defaults)
        let second = EchoLinkRegistrationClient.loadOrCreateSoftwareTag(defaults: defaults)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 22)
        XCTAssertTrue(first.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) })
    }

    func testRegistrationPlainTextResultSeparatesSuccessFromServerError() throws {
        let client = EchoLinkRegistrationClient()
        let url = try XCTUnwrap(URL(string: "https://www.echolink.org/validation/registerNode.jsp"))
        let http = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))

        XCTAssertEqual(try client.parseResponse(Data("OK".utf8), response: http),
                       "Check your email for EchoLink's validation instructions.")
        XCTAssertEqual(try client.parseResponse(Data("Validated".utf8), response: http),
                       "Your callsign is validated. You can sign in now.")
        for result in ["Callsign already registered", "Callsign already registered. Check your validation status."] {
            XCTAssertEqual(try client.parseResponse(Data(result.utf8), response: http),
                           "Your callsign is already registered. Sign in if it is validated, or continue EchoLink validation.")
        }
        XCTAssertThrowsError(try client.parseResponse(Data("<html>Oops</html>".utf8), response: http))
    }

    func testRegistrationValidatesBaseCallsignAndPreservesStationSuffix() throws {
        let client = EchoLinkRegistrationClient()
        for callsign in ["W1AW", "A1B-L", "N0CALL-R", "3DA0AA", "AA00AA"] {
            let request = try client.makeRequest(callsign: callsign, email: "op@example.org", password: "valid5")
            let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
            let items = try XCTUnwrap(URLComponents(string: "https://example.org/?\(body)")?.queryItems)
            XCTAssertEqual(items.first(where: { $0.name == "callsign" })?.value, callsign)
        }
        for callsign in ["AB12", "NOCALL", "*ECHOTEST*", "W1AW-X", "1234A"] {
            XCTAssertThrowsError(try client.makeRequest(callsign: callsign, email: "op@example.org", password: "valid5"))
        }
    }

    func testRegistrationRejectsMalformedLocalInputBeforeSending() {
        let client = EchoLinkRegistrationClient()
        XCTAssertThrowsError(try client.makeRequest(callsign: "bad call", email: "op@example.org", password: "valid5"))
        for email in ["invalid", "x@@example.org", "@example.org", "x@", "x\t@example.org"] {
            XCTAssertThrowsError(try client.makeRequest(callsign: "N0CALL", email: email, password: "valid5"))
        }
        XCTAssertThrowsError(try client.makeRequest(callsign: "N0CALL", email: "op@example.org", password: "x"))
        XCTAssertThrowsError(try client.makeRequest(callsign: "N0CALL", email: "op@example.org", password: "pássword"))
    }
}
