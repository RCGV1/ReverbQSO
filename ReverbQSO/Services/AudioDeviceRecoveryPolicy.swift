// SPDX-License-Identifier: GPL-3.0-or-later

/// Converts audio-system events into explicit recovery effects.
///
/// The policy never resumes capture. A caller must receive a fresh transmit
/// request before keying a microphone after any disruptive event.
struct AudioDeviceRecoveryPolicy {
    enum Event: Equatable {
        case deviceChange
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case mediaReset
        case engineConfigurationChanged
        case categoryChange(inputUsable: Bool)
    }

    struct Plan: Equatable {
        let discardBufferedReceive: Bool
        let stopCapture: Bool
        let rebuildGraph: Bool
        let restartPlayback: Bool
        let prepareMicrophone: Bool

        static let none = Plan(
            discardBufferedReceive: false,
            stopCapture: false,
            rebuildGraph: false,
            restartPlayback: false,
            prepareMicrophone: false
        )
    }

    static func plan(
        for event: Event,
        playbackActive: Bool,
        captureRequested: Bool,
        preparingOrRecovering: Bool
    ) -> Plan {
        switch event {
        case .deviceChange:
            return disruptivePlan(
                playbackActive: playbackActive,
                captureRequested: captureRequested
            )

        case .interruptionBegan:
            return Plan(
                discardBufferedReceive: true,
                stopCapture: captureRequested,
                rebuildGraph: false,
                restartPlayback: false,
                prepareMicrophone: false
            )

        case .interruptionEnded(shouldResume: let shouldResume):
            guard shouldResume, playbackActive else { return .none }
            return Plan(
                discardBufferedReceive: false,
                stopCapture: false,
                rebuildGraph: false,
                restartPlayback: true,
                prepareMicrophone: true
            )

        case .mediaReset:
            return disruptivePlan(
                playbackActive: playbackActive,
                captureRequested: captureRequested
            )

        case .engineConfigurationChanged:
            guard !preparingOrRecovering else { return .none }
            return disruptivePlan(
                playbackActive: playbackActive,
                captureRequested: captureRequested
            )

        case .categoryChange(inputUsable: let inputUsable):
            guard !preparingOrRecovering, !inputUsable else { return .none }
            return Plan(
                discardBufferedReceive: false,
                stopCapture: captureRequested,
                rebuildGraph: false,
                restartPlayback: false,
                prepareMicrophone: true
            )
        }
    }

    private static func disruptivePlan(
        playbackActive: Bool,
        captureRequested: Bool
    ) -> Plan {
        Plan(
            discardBufferedReceive: true,
            stopCapture: captureRequested,
            rebuildGraph: true,
            restartPlayback: playbackActive,
            prepareMicrophone: playbackActive || captureRequested
        )
    }
}
