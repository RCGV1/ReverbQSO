// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Tab view showing recently completed QSO sessions.
struct RecentView: View {

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject var recentsService: RecentConnectionsService

    @State private var reconnectError: String?
    @State private var showingClearConfirmation = false

    var body: some View {
        StandaloneNavigationContainer {
            Group {
                if recentsService.recents.isEmpty {
                    emptyState
                } else {
                    recentsList
                }
            }
            .navigationTitle("Recents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { RecordingsView(demo: appState.isDemoMode) } label: { Label("Recordings", systemImage: "waveform") }
                }
                if !recentsService.recents.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear All", role: .destructive) {
                            showingClearConfirmation = true
                        }
                    }
                }
            }
            .alert("Cannot Reconnect", isPresented: Binding(
                get: { reconnectError != nil },
                set: { if !$0 { reconnectError = nil } }
            )) {
                Button("OK", role: .cancel) { reconnectError = nil }
            } message: {
                Text(reconnectError ?? "")
            }
            .confirmationDialog("Clear recent contacts?", isPresented: $showingClearConfirmation) {
                Button("Clear All", role: .destructive) { recentsService.clear() }
            } message: {
                Text("This removes the saved list of recent QSOs.")
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView(
            "No Recent Contacts",
            systemImage: "clock.arrow.circlepath",
            description: Text("Completed QSO sessions will appear here.")
        )
    }

    private var recentsList: some View {
        List {
            ForEach(recentsService.recents) { recent in
                Button {
                    reconnect(to: recent.station)
                } label: {
                    recentRow(recent)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Reconnect to this station")
            }
            .onDelete { offsets in
                recentsService.remove(at: offsets)
            }
        }
        .listStyle(.plain)
    }

    private func recentRow(_ recent: RecentConnection) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recent.station.callsign)
                    .font(.system(.body, design: .monospaced, weight: .bold))

                if !recent.station.description.isEmpty {
                    Text(recent.station.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("Ended \(recent.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(formattedDuration(recent.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func reconnect(to station: Station) {
        Task {
            let directoryService = appState.directoryService
            let didRefresh = await directoryService.refresh()
            guard didRefresh else {
                reconnectError = directoryService.error?.localizedDescription ?? "Directory refresh was interrupted. Try again."
                return
            }
            guard let current = StationEndpointResolver.resolveStored(station, from: directoryService.stations) else {
                reconnectError = "This station is no longer in the current directory."
                return
            }
            guard !current.isBusy else {
                reconnectError = "This station is busy. Try again later."
                return
            }
            await appState.connect(to: current)
            reconnectError = appState.qsoHub.lastError
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
