// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation
#if !os(watchOS)
import UniformTypeIdentifiers
#endif

struct RecordingsView: View {
    @StateObject private var recorder: QSORecordingService
    @StateObject private var playback: RecordingPlaybackModel
    @State private var pendingDelete: QSORecording?
    @State private var errorMessage: String?
#if !os(watchOS)
    @State private var exportDocument: RecordingFileDocument?
    @State private var isExporting = false
    @State private var exportFilename = "recording.wav"
#endif
    init(demo: Bool = false) {
        _recorder = StateObject(wrappedValue: QSORecordingService(demo: demo))
        _playback = StateObject(wrappedValue: RecordingPlaybackModel())
    }
    var body: some View {
        List {
            if recorder.recordings.isEmpty {
                ContentUnavailableView("No Recordings", systemImage: "waveform", description: Text("Record a contact from the QSO controls."))
            }
            ForEach(recorder.recordings) { recording in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                    Button { togglePlayback(recording) } label: {
                        Image(systemName: playback.isPlaying(recording) ? "pause.fill" : "play.fill")
                            .frame(width: 32, height: 40)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(playback.isPlaying(recording)
                        ? "Pause recording with \(recording.callsign)"
                        : (playback.isActive(recording)
                            ? "Resume recording with \(recording.callsign)"
                            : "Play recording with \(recording.callsign)"))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(recording.callsign).font(.headline.monospaced())
                            Text(recording.kind == .clip ? "Clip" : "QSO")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                        Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Duration.seconds(recording.duration).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if playback.isActive(recording) {
                        Button { playback.stop() } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Stop recording playback")
                    }
                    #if !os(watchOS)
                    Menu {
                        ShareLink(item: recording.url) {
                            Label("Share recording", systemImage: "square.and.arrow.up")
                        }
                        Button { prepareExport(recording) } label: {
                            Label("Save to Files", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Recording actions")
                    #endif
                    }
                    if playback.isActive(recording) {
                        HStack(spacing: 6) {
                            Slider(value: Binding(
                                get: { playback.currentTime },
                                set: { playback.seek(to: $0) }
                            ), in: 0...max(playback.duration, 0.01))
                            Text(Duration.seconds(playback.currentTime).formatted(.time(pattern: .minuteSecond)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Playback position")
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { pendingDelete = recording }
                }
                .contextMenu {
                    #if !os(watchOS)
                    ShareLink(item: recording.url)
                    Button { prepareExport(recording) } label: {
                        Label("Save to Files", systemImage: "folder")
                    }
                    #endif
                    Button("Delete", role: .destructive) { pendingDelete = recording }
                }
            }
        }
        .navigationTitle("Recordings")
        .onAppear { recorder.reload() }
        .onDisappear { playback.stop() }
#if !os(watchOS)
        .fileExporter(isPresented: $isExporting, document: exportDocument,
                      contentType: .wav, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result {
                errorMessage = "Could not save the recording: \(error.localizedDescription)"
            }
            exportDocument = nil
        }
#endif
        .confirmationDialog("Delete this recording?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete Recording", role: .destructive) {
                guard let item = pendingDelete else { return }
                if item.id == playback.playingID { playback.stop() }
                do { try recorder.delete(item) } catch { errorMessage = error.localizedDescription }
                pendingDelete = nil
            }
        }
        .alert("Recording", isPresented: Binding(
            get: { errorMessage != nil || playback.errorMessage != nil },
            set: { if !$0 { errorMessage = nil; playback.clearError() } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil; playback.clearError() }
        } message: { Text(errorMessage ?? playback.errorMessage ?? "") }
    }
    private func togglePlayback(_ recording: QSORecording) {
        do { try playback.toggle(recording) }
        catch { errorMessage = "Could not play the recording: \(error.localizedDescription)" }
    }

#if !os(watchOS)
    private func prepareExport(_ recording: QSORecording) {
        guard FileManager.default.fileExists(atPath: recording.url.path) else {
            errorMessage = "The recording file is no longer available."
            recorder.reload()
            return
        }
        exportFilename = recordingExportFilename(recording)
        exportDocument = RecordingFileDocument(url: recording.url)
        isExporting = true
    }

    private func recordingExportFilename(_ recording: QSORecording) -> String {
        let callsign = recording.callsign
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let date = formatter.string(from: recording.startedAt)
        let kind = recording.kind == .clip ? "clip" : "QSO"
        let name = String(callsign).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(name.isEmpty ? "recording" : name)-\(date)-\(kind).wav"
    }
#endif
}

#if !os(watchOS)
/// A file-backed document so exporting a long recording does not first copy its audio into Data.
private struct RecordingFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    let url: URL

    init(url: URL) { self.url = url }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: [])
    }
}
#endif

@MainActor
private final class RecordingPlaybackModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    private var player: AVAudioPlayer?
    private let playbackID = UUID()
    private var timer: Timer?

    func isPlaying(_ recording: QSORecording) -> Bool {
        playingID == recording.id && player?.isPlaying == true
    }

    func isActive(_ recording: QSORecording) -> Bool {
        playingID == recording.id && player != nil
    }

    func toggle(_ recording: QSORecording) throws {
        errorMessage = nil
        if isActive(recording) {
            if isPlaying(recording) { pause() } else { resume() }
            return
        }
        stop()
        let next = try AVAudioPlayer(contentsOf: recording.url)
        next.delegate = self
        try RecordingAudioSession.shared.beginPlayback(id: playbackID) { [weak self] in self?.stop() }
        guard next.play() else {
            RecordingAudioSession.shared.endPlayback(id: playbackID)
            throw CocoaError(.fileReadUnknown)
        }
        player = next
        playingID = recording.id
        duration = next.duration
        currentTime = 0
        startTimer()
    }

    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        updateProgress()
        stopTimer()
    }

    func resume() {
        guard let player, !player.isPlaying else { return }
        guard player.play() else {
            errorMessage = "Could not resume the recording."
            stop()
            return
        }
        updateProgress()
        startTimer()
    }

    func seek(to value: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(value, 0), player.duration)
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
        currentTime = 0
        duration = 0
        stopTimer()
        RecordingAudioSession.shared.endPlayback(id: playbackID)
    }

    func clearError() { errorMessage = nil }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateProgress()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateProgress() {
        guard let player else { stopTimer(); return }
        currentTime = player.currentTime
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard self?.player.map(ObjectIdentifier.init) == identity else { return }
            self?.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        let message = "Could not decode the recording: \(error?.localizedDescription ?? "Unknown audio error")"
        Task { @MainActor [weak self] in
            guard self?.player.map(ObjectIdentifier.init) == identity else { return }
            self?.stop()
            self?.errorMessage = message
        }
    }
}
