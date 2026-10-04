// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class AudioDeviceRecoveryPolicyTests: XCTestCase {
    func testUnchangedHealthyRouteFeedbackPreservesSpeechAndTransmit() {
        let plan = AudioDeviceRecoveryPolicy.plan(
            for: .routeConfigurationChanged(graphHealthy: true), playbackActive: true,
            captureRequested: true, preparingOrRecovering: false)
        XCTAssertEqual(plan, .none)
    }

    func testChangedOrStoppedRouteFeedbackStillDiscardsAndRebuilds() {
        let plan = AudioDeviceRecoveryPolicy.plan(
            for: .routeConfigurationChanged(graphHealthy: false), playbackActive: true,
            captureRequested: true, preparingOrRecovering: false)
        XCTAssertTrue(plan.discardBufferedReceive)
        XCTAssertTrue(plan.stopCapture)
        XCTAssertTrue(plan.rebuildGraph)
        XCTAssertTrue(plan.restartPlayback)
        XCTAssertTrue(plan.prepareMicrophone)
    }

    func testDisruptiveDeviceChangeClearsOldAudioAndCaptureBeforeRebuilding() {
        let plan = AudioDeviceRecoveryPolicy.plan(
            for: .deviceChange,
            playbackActive: true,
            captureRequested: true,
            preparingOrRecovering: false
        )

        XCTAssertEqual(plan, .init(
            discardBufferedReceive: true,
            stopCapture: true,
            rebuildGraph: true,
            restartPlayback: true,
            prepareMicrophone: true
        ))
    }

    func testInterruptionBeginningStopsAudioWithoutPlanningAutomaticResume() {
        let plan = AudioDeviceRecoveryPolicy.plan(
            for: .interruptionBegan,
            playbackActive: true,
            captureRequested: true,
            preparingOrRecovering: true
        )

        XCTAssertEqual(plan, .init(
            discardBufferedReceive: true,
            stopCapture: true,
            rebuildGraph: false,
            restartPlayback: false,
            prepareMicrophone: false
        ))
    }

    func testInterruptionEndRestartsOnlyPreviouslyActivePlaybackWhenRecommended() {
        XCTAssertEqual(
            AudioDeviceRecoveryPolicy.plan(
                for: .interruptionEnded(shouldResume: true),
                playbackActive: true,
                captureRequested: true,
                preparingOrRecovering: false
            ),
            .init(
                discardBufferedReceive: false,
                stopCapture: false,
                rebuildGraph: false,
                restartPlayback: true,
                prepareMicrophone: true
            )
        )

        XCTAssertEqual(
            AudioDeviceRecoveryPolicy.plan(
                for: .interruptionEnded(shouldResume: false),
                playbackActive: true,
                captureRequested: true,
                preparingOrRecovering: false
            ),
            .none
        )
        XCTAssertEqual(
            AudioDeviceRecoveryPolicy.plan(
                for: .interruptionEnded(shouldResume: true),
                playbackActive: false,
                captureRequested: true,
                preparingOrRecovering: false
            ),
            .none
        )
    }

    func testMediaResetAlwaysRebuildsEvenDuringRecovery() {
        let plan = AudioDeviceRecoveryPolicy.plan(
            for: .mediaReset,
            playbackActive: true,
            captureRequested: true,
            preparingOrRecovering: true
        )

        XCTAssertEqual(plan, .init(
            discardBufferedReceive: true,
            stopCapture: true,
            rebuildGraph: true,
            restartPlayback: true,
            prepareMicrophone: true
        ))
    }

    func testConfigurationFeedbackIsIgnoredDuringOwnedRecovery() {
        let events: [AudioDeviceRecoveryPolicy.Event] = [
            .engineConfigurationChanged,
            .categoryChange(inputUsable: false),
        ]

        for event in events {
            XCTAssertEqual(
                AudioDeviceRecoveryPolicy.plan(
                    for: event,
                    playbackActive: true,
                    captureRequested: true,
                    preparingOrRecovering: true
                ),
                .none
            )
        }
    }

    func testEngineConfigurationChangeRebuildsButNeverRekeysTransmit() {
        let plan = AudioDeviceRecoveryPolicy.plan(
            for: .engineConfigurationChanged,
            playbackActive: true,
            captureRequested: true,
            preparingOrRecovering: false
        )

        XCTAssertEqual(plan, .init(
            discardBufferedReceive: true,
            stopCapture: true,
            rebuildGraph: true,
            restartPlayback: true,
            prepareMicrophone: true
        ))
    }

    func testInvalidCategoryInputStopsCaptureAndRequestsPreparation() {
        let plan = AudioDeviceRecoveryPolicy.plan(
            for: .categoryChange(inputUsable: false),
            playbackActive: true,
            captureRequested: true,
            preparingOrRecovering: false
        )

        XCTAssertEqual(plan, .init(
            discardBufferedReceive: false,
            stopCapture: true,
            rebuildGraph: false,
            restartPlayback: false,
            prepareMicrophone: true
        ))
        XCTAssertEqual(
            AudioDeviceRecoveryPolicy.plan(
                for: .categoryChange(inputUsable: true),
                playbackActive: true,
                captureRequested: true,
                preparingOrRecovering: false
            ),
            .none
        )
    }
}
