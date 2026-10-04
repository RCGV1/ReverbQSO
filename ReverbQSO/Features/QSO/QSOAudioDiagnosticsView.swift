// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Sample only this detail screen, rather than invalidating the whole QSO.
struct QSOAudioDiagnosticsView: View {
    let connectionService: EchoLinkConnectionService
    @State private var snapshot = QSOAudioDiagnosticsSnapshot()
    @State private var rates = QSOAudioBitrates()
    @State private var sampler = QSOAudioBitrateSampler()

    var body: some View {
        Form {
            Section("Encoding") {
                metric("Transmit", snapshot.txCodec)
                metric("Receive", snapshot.rxCodec ?? "Waiting for audio")
                metric("Voice format", "8 kHz · mono")
                metric("Transport", snapshot.transport)
            }
            Section {
                metric("TX bitrate", bitrate(rates.txKilobitsPerSecond))
                metric("RX bitrate", bitrate(rates.rxKilobitsPerSecond))
                metric("RX loss estimate", snapshot.estimatedRXLossPercent.map {
                    String(format: "%.1f%%", $0)
                } ?? "—")
                metric("Buffered audio", milliseconds(snapshot.playbackBufferedMilliseconds))
                metric("Startup buffer", milliseconds(snapshot.startupBufferMilliseconds))
                metric("Playback speed", String(format: "%.1f%%", snapshot.playbackSpeedPercent))
                metric("Device output delay", milliseconds(snapshot.deviceOutputDelayMilliseconds))
            } header: {
                Text("Live")
            } footer: {
                Text("Bitrate measures voice payload; idle reads 0. Buffer time is local, not round-trip delay.")
            }
            Section {
                count("TX packets sent", snapshot.txPackets)
                count("RX packets accepted", snapshot.rxPackets)
                count("RX packets missing", snapshot.missingRXPackets)
                count("RX duplicate or late", snapshot.duplicateOrLateRXPackets)
                count("RX invalid or unsupported", snapshot.invalidRXPackets)
            } header: {
                Text("This QSO")
            } footer: {
                Text("Missing packets are estimated from sequence gaps after reordering. An em dash means no sequence data yet.")
            }
            Section {
                count("TX queue drops", snapshot.txQueueDrops)
                count("RX playback drops", snapshot.playbackRXDrops)
                count("Playback refills", snapshot.playbackRefills)
                count("Transport buffer drops", snapshot.transportRXDrops)
                count("TX queued", snapshot.txQueuedPackets)
                count("RX awaiting reordering", snapshot.rxQueuedPackets)
            } header: {
                Text("Local buffers")
            } footer: {
                Text("Refills rebuild a small audio buffer after playback runs empty.")
                if snapshot.transport == "Proxy" {
                    Text("Transport buffer counts cover the shared proxy connection.")
                }
            }
        }
        .navigationTitle("Audio Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                let next = await connectionService.audioDiagnosticsSnapshot()
                guard !Task.isCancelled else { return }
                snapshot = next
                rates = sampler.sample(next, now: next.sampledAt)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }

    private func count(_ title: String, _ value: Int) -> some View {
        LabeledContent(title) { Text(value, format: .number).monospacedDigit() }
    }

    private func bitrate(_ value: Double?) -> String {
        value.map { String(format: "%.1f kbps", $0) } ?? "—"
    }

    private func milliseconds(_ value: Double) -> String {
        String(format: "%.0f ms", value)
    }
}
