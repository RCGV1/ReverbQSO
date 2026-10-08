// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class StationDirectoryObservationTests: XCTestCase {
    private let station = Station(callsign: "K1ABC-R", ipAddress: "192.0.2.1", nodeNumber: 123)

    func testConsecutiveListingsSurviveAddressAndUUIDChangesButCountDuplicatesOnce() throws {
        var tracker = StationDirectoryObservationTracker()
        let first = Date(timeIntervalSince1970: 100)
        let second = first.addingTimeInterval(60)
        tracker.record([station], at: first)
        var refreshed = Station(callsign: " k1abc-r ", ipAddress: "192.0.2.2", nodeNumber: 123)
        refreshed.isBusy = true
        tracker.record([refreshed, refreshed], at: second)
        let observed = try XCTUnwrap(tracker.observation(for: station))
        XCTAssertEqual(observed.firstSeenAt, first)
        XCTAssertEqual(observed.lastSeenAt, second)
        XCTAssertEqual(observed.consecutiveSnapshots, 2)
    }

    func testMissingStationResetsContinuityWhenItReappears() throws {
        var tracker = StationDirectoryObservationTracker()
        tracker.record([station], at: Date(timeIntervalSince1970: 100))
        tracker.record([], at: Date(timeIntervalSince1970: 200))
        XCTAssertNil(tracker.observation(for: station))
        let returnedAt = Date(timeIntervalSince1970: 300)
        tracker.record([station], at: returnedAt)
        XCTAssertEqual(tracker.observation(for: station), .init(firstSeenAt: returnedAt, lastSeenAt: returnedAt, consecutiveSnapshots: 1))
    }

    func testNodeIdentityChangeAndAccountResetNeverInheritObservations() {
        var tracker = StationDirectoryObservationTracker()
        tracker.record([station], at: Date(timeIntervalSince1970: 100))
        var reassigned = station
        reassigned.nodeNumber = 456
        XCTAssertNil(tracker.observation(for: reassigned))
        tracker.reset()
        XCTAssertNil(tracker.observation(for: station))
    }
}

@MainActor
final class StationDirectorySnapshotObservationTests: XCTestCase {
    func testFailedRefreshKeepsSuccessfulObservationWithoutCountingFailure() async throws {
        let station = Station(callsign: "K1ABC-R", ipAddress: "192.0.2.1", nodeNumber: 123)
        var shouldFail = false
        let service = EchoLinkDirectoryService(fetchStationsForRefresh: {
            if shouldFail { throw URLError(.timedOut) }
            return [station]
        })
        service.isLoggedIn = true
        let firstSucceeded = await service.refresh()
        XCTAssertTrue(firstSucceeded)
        let original = try XCTUnwrap(service.observation(for: station))
        shouldFail = true
        let secondSucceeded = await service.refresh()
        XCTAssertFalse(secondSucceeded)
        XCTAssertEqual(service.observation(for: station), original)
    }
}
