// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation

enum MicrophoneAuthorizationState: Equatable {
    case notDetermined
    case granted
    case denied
}

enum MicrophonePermissionRequestReason: Equatable {
    case userInitiated
    case automaticPreparation
}

@MainActor
enum MicrophoneAccess {
    static func shouldRequest(
        status: MicrophoneAuthorizationState,
        reason: MicrophonePermissionRequestReason
    ) -> Bool {
        status == .notDetermined && reason == .userInitiated
    }

    static var status: MicrophoneAuthorizationState {
        if #available(iOS 17.0, watchOS 10.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined: return .notDetermined
            case .granted: return .granted
            case .denied: return .denied
            @unknown default: return .denied
            }
        }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined: return .notDetermined
        case .granted: return .granted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    static func request(reason: MicrophonePermissionRequestReason = .userInitiated) async -> Bool {
        switch status {
        case .granted: return true
        case .denied: return false
        case .notDetermined:
            guard shouldRequest(status: status, reason: reason) else { return false }
        }

        if #available(iOS 17.0, watchOS 10.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
