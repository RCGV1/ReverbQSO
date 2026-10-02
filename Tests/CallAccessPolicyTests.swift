// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

final class CallAccessPolicyTests: XCTestCase {
    private let person = Station(callsign: "KO6CNT", ipAddress: "192.0.2.1")

    func testDefaultAllowsEveryStation() {
        XCTAssertNil(CallAccessPolicy().rejection(for: person, direction: .incoming, countryCode: "US"))
    }

    func testDirectionAndExactCallsignAreRespected() {
        var policy = CallAccessPolicy()
        policy.blockedCallsigns = [" ko6cnt "]
        policy.applyToOutgoing = false
        XCTAssertNotNil(policy.rejection(for: person, direction: .incoming, countryCode: "US"))
        XCTAssertNil(policy.rejection(for: person, direction: .outgoing, countryCode: "US"))
        var repeater = person
        repeater.callsign = "KO6CNT-R"
        repeater.type = .repeater
        XCTAssertNil(policy.rejection(for: repeater, direction: .incoming, countryCode: "US"))
    }

    func testCountryAndTypeFiltersDoNotGuessUnknownCountries() {
        var policy = CallAccessPolicy()
        policy.blockedCountries = ["us"]
        XCTAssertNotNil(policy.rejection(for: person, direction: .outgoing, countryCode: "US"))
        XCTAssertNil(policy.rejection(for: person, direction: .outgoing, countryCode: nil))
        policy.allowedTypes.remove(.user)
        XCTAssertNotNil(policy.rejection(for: person, direction: .incoming, countryCode: nil))
    }

    func testAllowListCannotBeBypassedByDenyListOrCase() {
        var policy = CallAccessPolicy()
        policy.useAllowList = true
        XCTAssertNotNil(policy.rejection(for: person, direction: .outgoing, countryCode: "US"))
        policy.allowedCallsigns = ["ko6cnt"]
        XCTAssertNil(policy.rejection(for: person, direction: .outgoing, countryCode: "US"))
        policy.blockedCallsigns = ["KO6CNT"]
        XCTAssertNotNil(policy.rejection(for: person, direction: .incoming, countryCode: "US"))
    }

    @MainActor func testSettingsPersistAndDemoIsIsolated() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = CallAccessPolicyStore(defaults: defaults)
        store.policy.blockedCallsigns = ["K6BLOCK"]
        XCTAssertEqual(CallAccessPolicyStore.load(defaults: defaults).blockedCallsigns, ["K6BLOCK"])
        let demo = CallAccessPolicyStore(defaults: defaults, demo: true)
        XCTAssertTrue(demo.policy.blockedCallsigns.isEmpty)
        demo.policy.blockedCallsigns = ["DEMO2"]
        XCTAssertEqual(CallAccessPolicyStore.load(defaults: defaults).blockedCallsigns, ["K6BLOCK"])
    }
}
