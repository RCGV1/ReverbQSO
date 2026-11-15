// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class CapturePreparationOwnershipTests: XCTestCase {
    func testRecoverySchedulingDuringServicePreparationDoesNotStrandOwnerWhenReplacementFinishesFirst() throws {
        try assertRecoverySchedulingDoesNotStrandOwner(replacementFinishesFirst: true)
    }

    func testRecoverySchedulingDuringServicePreparationDoesNotStrandOwnerWhenServiceFinishesFirst() throws {
        try assertRecoverySchedulingDoesNotStrandOwner(replacementFinishesFirst: false)
    }

    func testResetAllowsNewPreparationAndStaleCompletionCannotClearIt() throws {
        var ownership = CapturePreparationOwnership()
        let stale = try XCTUnwrap(ownership.begin())

        ownership.reset()

        XCTAssertFalse(ownership.isPreparing)
        XCTAssertFalse(ownership.isCurrent(stale))
        let current = try XCTUnwrap(ownership.begin())
        XCTAssertFalse(ownership.finish(generation: stale))
        XCTAssertTrue(ownership.isPreparing, "Completion from before stopAll must not clear a new owner")
        XCTAssertTrue(ownership.isCurrent(current))

        XCTAssertTrue(ownership.finish(generation: current))
        XCTAssertFalse(ownership.isPreparing)
    }

    func testCurrentPreparationCleanupAllowsRetryWithoutReset() throws {
        var ownership = CapturePreparationOwnership()
        let owner = try XCTUnwrap(ownership.begin())

        // Cancellation exits prepareCaptureInput through the same cleanup defer.
        XCTAssertTrue(ownership.finish(generation: owner))

        XCTAssertFalse(ownership.isPreparing)
        XCTAssertNotNil(ownership.begin(), "Preparation cleanup must allow a retry")
    }

    func testPendingEngineTaskPreventsAnotherScheduleFromInvalidatingItsOwner() throws {
        var ownership = CapturePreparationOwnership()
        let scheduled = try XCTUnwrap(ownership.schedule(hasPendingTask: false))
        let owner = try XCTUnwrap(ownership.begin())

        XCTAssertNil(ownership.schedule(hasPendingTask: true))

        XCTAssertTrue(ownership.isCurrent(scheduled))
        XCTAssertTrue(ownership.isCurrent(owner))
        XCTAssertTrue(ownership.finish(generation: owner))
        XCTAssertFalse(ownership.isPreparing)
    }

    func testResetRejectsStaleScheduledCompletionWhileReplacementOwnsPreparation() throws {
        var ownership = CapturePreparationOwnership()
        let staleSchedule = try XCTUnwrap(ownership.schedule(hasPendingTask: false))
        let staleOwner = try XCTUnwrap(ownership.begin())

        ownership.reset()
        let replacementSchedule = try XCTUnwrap(ownership.schedule(hasPendingTask: false))
        let replacementOwner = try XCTUnwrap(ownership.begin())

        XCTAssertFalse(ownership.isCurrent(staleSchedule), "A stale scheduled completion must not retire the replacement task")
        XCTAssertFalse(ownership.finish(generation: staleOwner))
        XCTAssertTrue(ownership.isPreparing)
        XCTAssertTrue(ownership.isCurrent(replacementSchedule))
        XCTAssertTrue(ownership.finish(generation: replacementOwner))
        XCTAssertFalse(ownership.isPreparing)
    }

    func testPreparationRejectsConcurrentCallerWithoutRetiringCurrentOwner() throws {
        var ownership = CapturePreparationOwnership()
        let owner = try XCTUnwrap(ownership.begin())

        XCTAssertNil(ownership.begin())

        XCTAssertTrue(ownership.isPreparing)
        XCTAssertTrue(ownership.isCurrent(owner))
        XCTAssertTrue(ownership.finish(generation: owner))
        XCTAssertFalse(ownership.isPreparing)
    }

    private func assertRecoverySchedulingDoesNotStrandOwner(
        replacementFinishesFirst: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var ownership = CapturePreparationOwnership()
        // Recovery is suspended when the service enters prepareCaptureInput.
        let serviceOwner = try XCTUnwrap(ownership.begin(), file: file, line: line)
        // Recovery resumes while the service is suspended in its retry delay.
        let scheduled = ownership.schedule(hasPendingTask: false)

        if replacementFinishesFirst {
            if scheduled != nil, let replacementOwner = ownership.begin() {
                ownership.finish(generation: replacementOwner)
            }
            ownership.finish(generation: serviceOwner)
        } else {
            ownership.finish(generation: serviceOwner)
            if scheduled != nil, let replacementOwner = ownership.begin() {
                ownership.finish(generation: replacementOwner)
            }
        }

        XCTAssertFalse(ownership.isPreparing,
                       "After both callers return, no completed task may retain preparation ownership",
                       file: file, line: line)
        XCTAssertNotNil(ownership.begin(), "Subsequent eligible preparation must be admitted", file: file, line: line)
    }
}
