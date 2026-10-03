// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation

/// Keeps saved recording playback from changing the audio route of a live QSO.
@MainActor
final class RecordingAudioSession {
    static let shared = RecordingAudioSession()

    private final class Owner {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }
    private var liveOwners: [ObjectIdentifier: Owner] = [:]
    private var recordingID: UUID?
    private var stopRecording: (() -> Void)?
    private let activate: () throws -> Void
    private let deactivate: () -> Void

    init(activate: @escaping () throws -> Void = {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }, deactivate: @escaping () -> Void = {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }) {
        self.activate = activate
        self.deactivate = deactivate
    }

    func beginLiveAudio(owner: AnyObject) {
        liveOwners[ObjectIdentifier(owner)] = Owner(owner)
        let stop = stopRecording
        recordingID = nil
        stopRecording = nil
        stop?()
    }

    func endLiveAudio(owner: AnyObject) {
        liveOwners.removeValue(forKey: ObjectIdentifier(owner))
    }

    func beginPlayback(id: UUID, onStop: @escaping () -> Void) throws {
        liveOwners = liveOwners.filter { $0.value.value != nil }
        guard liveOwners.isEmpty else { throw PlaybackError.qsoActive }
        let stop = stopRecording
        recordingID = nil
        stopRecording = nil
        stop?()
        try activate()
        recordingID = id
        stopRecording = onStop
    }

    func endPlayback(id: UUID) {
        guard recordingID == id else { return }
        recordingID = nil
        stopRecording = nil
        deactivate()
    }

    enum PlaybackError: LocalizedError {
        case qsoActive
        var errorDescription: String? { "Leave the QSO before playing a saved recording." }
    }
}
