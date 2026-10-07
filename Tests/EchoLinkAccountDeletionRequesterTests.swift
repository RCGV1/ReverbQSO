// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class EchoLinkAccountDeletionRequesterTests: XCTestCase {
    func testRequestTargetsOfficialHTTPSFormAndContainsDeletionDetails() throws {
        let request = EchoLinkAccountDeletionRequester.makeRequest(
            callsign: "N0TEST",
            email: "operator@example.com"
        )

        XCTAssertEqual(request.url, ReverbQSOLinks.echoLinkSupportSubmission)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let fields = try XCTUnwrap(URLComponents(string: "?" + String(decoding: body, as: UTF8.self))?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: fields.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(values["Callsign"], "N0TEST")
        XCTAssertEqual(values["field399"], "operator@example.com")
        XCTAssertEqual(values["Category"], "general")
        XCTAssertTrue(values["Question"]?.contains("delete my EchoLink account") == true)
    }

    func testRedirectPolicyAllowsOnlySameHostHTTPS() {
        let original = ReverbQSOLinks.echoLinkSupportSubmission

        XCTAssertTrue(EchoLinkSupportRedirectPolicy.allows(
            originalURL: original,
            redirectURL: URL(string: "https://secure.echolink.org/support_done.jsp")
        ))
        XCTAssertFalse(EchoLinkSupportRedirectPolicy.allows(
            originalURL: original,
            redirectURL: URL(string: "http://secure.echolink.org/support_done.jsp")
        ))
        XCTAssertFalse(EchoLinkSupportRedirectPolicy.allows(
            originalURL: original,
            redirectURL: URL(string: "https://example.com/collect")
        ))
    }

    func testServerValidationFailureIsRejected() async {
        let session = makeSession(
            statusCode: 200,
            body: "No e-mail address was provided. Please click Back."
        )
        defer { session.invalidateAndCancel() }

        do {
            try await EchoLinkAccountDeletionRequester(session: session).submit(
                callsign: "N0TEST",
                email: "operator@example.com"
            )
            XCTFail("A server-side form validation error must not be reported as submitted")
        } catch {
            XCTAssertEqual(error.localizedDescription, EchoLinkAccountDeletionRequester.RequestError.rejected.localizedDescription)
        }
    }

    func testOfficialConfirmationAcknowledgementIsAccepted() async throws {
        let session = makeSession(
            statusCode: 200,
            body: "<html><head><title>Support Confirmation</title></head><body>Your message has been sent.</body></html>"
        )
        defer { session.invalidateAndCancel() }

        try await EchoLinkAccountDeletionRequester(session: session).submit(
            callsign: "N0TEST",
            email: "operator@example.com"
        )
    }

    func testBlankUnknownAndCaptchaResponsesAreNotAcknowledgements() {
        XCTAssertFalse(EchoLinkAccountDeletionRequester.isConfirmedSubmissionResponse(""))
        XCTAssertFalse(EchoLinkAccountDeletionRequester.isConfirmedSubmissionResponse(
            "<html><title>Maintenance</title><body>Please try later.</body></html>"
        ))
        XCTAssertFalse(EchoLinkAccountDeletionRequester.isConfirmedSubmissionResponse(
            "<html><title>Support Confirmation</title><body>Complete this CAPTCHA. Your message has been sent.</body></html>"
        ))
    }

    private func makeSession(statusCode: Int, body: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountDeletionURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            "X-Deletion-Test-Status": String(statusCode),
            "X-Deletion-Test-Body": body
        ]
        return URLSession(configuration: configuration)
    }
}

private final class AccountDeletionURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let statusCode = Int(request.value(forHTTPHeaderField: "X-Deletion-Test-Status") ?? "500") ?? 500
        let body = request.value(forHTTPHeaderField: "X-Deletion-Test-Body") ?? ""
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
