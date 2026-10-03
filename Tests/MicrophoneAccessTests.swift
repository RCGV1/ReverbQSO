// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class MicrophoneAccessTests: XCTestCase {
    func testAutomaticPreparationNeverRequestsUndeterminedPermission() {
        XCTAssertFalse(MicrophoneAccess.shouldRequest(
            status: .notDetermined,
            reason: .automaticPreparation
        ))
    }

    func testUserActionRequestsUndeterminedPermission() {
        XCTAssertTrue(MicrophoneAccess.shouldRequest(
            status: .notDetermined,
            reason: .userInitiated
        ))
    }

    func testResolvedPermissionIsNeverRequestedAgain() {
        for status in [MicrophoneAuthorizationState.granted, .denied] {
            XCTAssertFalse(MicrophoneAccess.shouldRequest(status: status, reason: .userInitiated))
            XCTAssertFalse(MicrophoneAccess.shouldRequest(status: status, reason: .automaticPreparation))
        }
    }
}
