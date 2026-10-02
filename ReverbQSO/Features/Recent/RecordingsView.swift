// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation

struct RecordingsView: View {
    @StateObject private var recorder: QSORecordingService
    @StateObject private var playback: RecordingPlaybackModel
    @State private var pendingDelete: QSORecording?
    @State private var errorMessage: String?
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
                HStack(spacing: 12) {
                    Button { togglePlayback(recording) } label: {
                        Image(systemName: playback.isPlaying(recording) ? "stop.fill" : "play.fill")
                            .frame(width: 32, height: 40)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(playback.isPlaying(recording)
                        ? "Stop recording with \(recording.callsign)"
                        : "Play recording with \(recording.callsign)")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recording.callsign).font(.headline.monospaced())
                        Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Duration.seconds(recording.duration).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    #if !os(watchOS)
                    ShareLink(item: recording.url) {
                        Image(systemName: "square.and.arrow.up")
                    }.buttonStyle(.borderless).accessibilityLabel("Export recording")
                    #endif
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { pendingDelete = recording }
                }
                .contextMenu {
                    #if !os(watchOS)
                    ShareLink(item: recording.url)
                    #endif
                    Button("Delete", role: .destructive) { pendingDelete = recording }
                }
            }
        }
        .navigationTitle("Recordings")
        .onAppear { recorder.reload() }
        .onDisappear { playback.stop() }
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
        .alert("Recording", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
    private func togglePlayback(_ recording: QSORecording) {
        do { try playback.toggle(recording) }
        catch { errorMessage = "Could not play the recording: \(error.localizedDescription)" }
    }
}

@MainActor
private final class RecordingPlaybackModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    func isPlaying(_ recording: QSORecording) -> Bool {
        playingID == recording.id && player?.isPlaying == true
    }

    func toggle(_ recording: QSORecording) throws {
        if isPlaying(recording) {
            stop()
            return
        }
        stop()
        let next = try AVAudioPlayer(contentsOf: recording.url)
        next.delegate = self
        guard next.play() else { throw CocoaError(.fileReadUnknown) }
        player = next
        playingID = recording.id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
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
        Task { @MainActor [weak self] in
            guard self?.player.map(ObjectIdentifier.init) == identity else { return }
            self?.stop()
        }
    }
}
