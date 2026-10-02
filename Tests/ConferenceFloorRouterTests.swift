// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class ConferenceFloorRouterTests: XCTestCase {
    func testOneTalkerOwnsFloorUntilPauseThenAnotherTakesIt() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        var floor = ConferenceFloorRouter(holdInterval: 0.6)

        XCTAssertEqual(floor.listeners(for: first, activeIDs: [first, second, third], at: start), [second, third])
        XCTAssertEqual(floor.talkerID, first)
        XCTAssertTrue(floor.listeners(
            for: second, activeIDs: [first, second, third], at: start.addingTimeInterval(0.3)
        ).isEmpty)
        XCTAssertEqual(floor.listeners(
            for: first, activeIDs: [first, second, third], at: start.addingTimeInterval(0.4)
        ), [second, third])
        XCTAssertTrue(floor.listeners(
            for: second, activeIDs: [first, second, third], at: start.addingTimeInterval(0.9)
        ).isEmpty)
        XCTAssertEqual(floor.listeners(
            for: second, activeIDs: [first, second, third], at: start.addingTimeInterval(1.01)
        ), [first, third])
        XCTAssertEqual(floor.talkerID, second)
    }

    func testUnknownSourceCannotTakeFloorAndDisconnectReleasesIt() {
        let first = UUID()
        let second = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        var floor = ConferenceFloorRouter()

        XCTAssertTrue(floor.listeners(for: UUID(), activeIDs: [first, second], at: start).isEmpty)
        XCTAssertNil(floor.talkerID)
        XCTAssertEqual(floor.listeners(for: first, activeIDs: [first, second], at: start), [second])
        floor.remove(first)
        XCTAssertEqual(floor.listeners(for: second, activeIDs: [second], at: start), [])
        XCTAssertEqual(floor.talkerID, second)
        XCTAssertEqual(floor.expire(at: start.addingTimeInterval(0.6)), second)
        XCTAssertNil(floor.talkerID)
    }
}
