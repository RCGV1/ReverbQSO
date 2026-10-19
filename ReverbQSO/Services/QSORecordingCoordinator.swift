// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

enum RecordingPreferences {
    static func alwaysRecordKey(demo: Bool = false) -> String {
        demo ? "recording.alwaysRecord.demo" : "recording.alwaysRecord"
    }
}

@MainActor
final class QSORecordingCoordinator: ObservableObject {
    @Published private(set) var isRecordingClip = false
    @Published private(set) var isAutomaticallyRecording = false
    @Published private(set) var errorMessage: String?

    private let automaticRecorder: QSORecordingService
    private let clipRecorder: QSORecordingService
    private let defaults: UserDefaults
    private let preferenceKey: String
    private var callsign: String?
    private var lastAutomaticPreference = false
    private var automaticStartError: String?

    init(folder: URL? = nil, demo: Bool = false, defaults: UserDefaults = .standard) {
        automaticRecorder = QSORecordingService(folder: folder, demo: demo, rotatesAtLimit: true)
        clipRecorder = QSORecordingService(folder: folder, demo: demo)
        self.defaults = defaults
        preferenceKey = RecordingPreferences.alwaysRecordKey(demo: demo)
    }

    func startSession(callsign: String) {
        guard self.callsign == nil else { return }
        self.callsign = callsign
        errorMessage = nil
        automaticStartError = nil
        lastAutomaticPreference = false
        refreshAutomaticRecording()
    }

    func refreshAutomaticRecording() {
        guard let callsign else { return }
        let shouldRecord = defaults.bool(forKey: preferenceKey)

        if !shouldRecord {
            if automaticRecorder.isRecording { automaticRecorder.stop() }
            lastAutomaticPreference = false
        } else if !lastAutomaticPreference {
            do {
                try automaticRecorder.start(callsign: callsign, kind: .qso)
                lastAutomaticPreference = true
                if let automaticStartError, errorMessage == automaticStartError { errorMessage = nil }
                automaticStartError = nil
            } catch {
                let message = "Could not start automatic recording: \(error.localizedDescription)"
                automaticStartError = message
                errorMessage = message
                lastAutomaticPreference = false
            }
        }
        updateState()
    }

    func toggleClip() {
        if clipRecorder.isRecording {
            clipRecorder.stop()
        } else if let callsign {
            do {
                try clipRecorder.start(callsign: callsign, kind: .clip)
            } catch {
                errorMessage = "Could not start clip recording: \(error.localizedDescription)"
            }
        }
        updateState()
    }

    func append(_ samples: [Int16]) {
        automaticRecorder.append(samples)
        clipRecorder.append(samples)
        updateState()
    }

    func stopSession() {
        automaticRecorder.stop()
        clipRecorder.stop()
        callsign = nil
        lastAutomaticPreference = false
        updateState()
    }

    private func updateState() {
        isAutomaticallyRecording = automaticRecorder.isRecording
        isRecordingClip = clipRecorder.isRecording
        errorMessage = automaticRecorder.errorMessage ?? clipRecorder.errorMessage ?? errorMessage
    }
}
