// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class CallCQWireTests: XCTestCase {
    func testRegisterRequestUsesCanonicalPasswordAuthAndDocumentedFields() throws {
        let registration = CallCQRegistration(
            callsign: "N0TST", nodeType: "U", internetAddress: nil,
            countryCode: "US", isReachable: true,
            acceptCountryCodes: [], acceptLanguageCodes: ["en"],
            declineCallsigns: ["K1OLD"], acceptNodeTypes: ["U", "L", "R"]
        )

        let request = try CallCQRequestFactory.request(
            operation: .register(registration), password: "s3cr3t!"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://www.echolink.org/cqqserver/cqq/register")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-EchoLink-Auth"), "czNjcjN0IQ==")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["callsign"] as? String, "N0TST")
        XCTAssertEqual(json["isReachable"] as? Bool, true)
        XCTAssertNil(json["internetAddress"])
        XCTAssertEqual(json["acceptNodeTypes"] as? [String], ["U", "L", "R"])
    }

    func testResponseParserDistinguishesWaitingIncompleteMatchAndTerminalError() throws {
        XCTAssertEqual(try CallCQResponseParser.parse(Data(#"{"error":"No match"}"#.utf8)), .waiting)
        XCTAssertEqual(try CallCQResponseParser.parse(Data(#"{"matchedCallsign":"K7MOCK-L"}"#.utf8)), .waiting)
        XCTAssertEqual(
            try CallCQResponseParser.parse(Data(#"{"matchedCallsign":"K7MOCK-L","matchedInternetAddress":"198.51.100.27"}"#.utf8)),
            .matched(callsign: "K7MOCK-L", internetAddress: "198.51.100.27")
        )
        XCTAssertThrowsError(try CallCQResponseParser.parse(Data(#"{"error":"synthetic failure"}"#.utf8)))
    }

    func testEffectiveRegistrationAppliesGlobalRestrictions() throws {
        var policy = CallAccessPolicy()
        policy.allowedTypes = [.user, .repeater]
        policy.blockedCallsigns = ["K1BLOCK"]
        policy.blockedCountries = ["CA"]
        var preferences = CallCQPreferences.default
        preferences.countryCodes = ["US", "CA"]

        let effective = try CallCQRegistration.make(
            callsign: "N0TST", preferences: preferences, policy: policy,
            recentCallsigns: ["K1OLD"], transport: .explicit(
                EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "")
            )
        )

        XCTAssertEqual(effective.acceptNodeTypes, ["U", "R"])
        XCTAssertEqual(effective.acceptCountryCodes, ["US"])
        XCTAssertEqual(Set(effective.declineCallsigns), ["K1BLOCK", "K1OLD"])
    }

    func testAllowListPreventsCallingCQ() {
        var policy = CallAccessPolicy()
        policy.useAllowList = true
        XCTAssertThrowsError(try CallCQRegistration.make(
            callsign: "N0TST", preferences: .default, policy: policy,
            recentCallsigns: [], transport: .explicit(
                EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "")
            )
        ))
    }

    func testDisabledOutgoingPolicyDoesNotConstrainCQ() throws {
        var policy = CallAccessPolicy()
        policy.applyToOutgoing = false
        policy.useAllowList = true
        policy.allowedTypes = [.user]
        policy.blockedCountries = ["US"]
        policy.blockedCallsigns = ["K1BLOCK"]
        var preferences = CallCQPreferences.default
        preferences.countryCodes = ["US"]

        let registration = try CallCQRegistration.make(
            callsign: "N0TST", preferences: preferences, policy: policy,
            recentCallsigns: ["K1OLD"], transport: .explicit(
                EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "")
            )
        )

        XCTAssertEqual(registration.acceptNodeTypes, ["U", "L", "R"])
        XCTAssertEqual(registration.acceptCountryCodes, ["US"])
        XCTAssertEqual(registration.declineCallsigns, ["K1OLD"])
    }

    func testRecentCallsignsAreIncludedOnlyWhenPreferenceIsEnabled() throws {
        let transport = EchoLinkEffectiveTransport.explicit(
            EchoLinkProxyConfiguration(mode: .direct, host: "", port: 8100, password: "")
        )
        let enabled = try CallCQRegistration.make(
            callsign: "N0TST", preferences: .default, policy: CallAccessPolicy(),
            recentCallsigns: ["K1OLD"], transport: transport
        )
        var disabledPreferences = CallCQPreferences.default
        disabledPreferences.avoidRecentContacts = false
        let disabled = try CallCQRegistration.make(
            callsign: "N0TST", preferences: disabledPreferences, policy: CallAccessPolicy(),
            recentCallsigns: ["K1OLD"], transport: transport
        )

        XCTAssertTrue(enabled.declineCallsigns.contains("K1OLD"))
        XCTAssertFalse(disabled.declineCallsigns.contains("K1OLD"))
    }
}
