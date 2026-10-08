// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// View showing the user's bookmarked favorite stations.
///
/// Supports swipe-to-delete and reordering. Tapping a station initiates a connection.
struct FavoritesView: View {

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var viewModel: FavoritesViewModel
    @State private var connectingID: UUID?
    @State private var reconnectError: String?

    var body: some View {
        StandaloneNavigationContainer {
            Group {
                if viewModel.favorites.isEmpty {
                    emptyState
                } else {
                    favoritesList
                }
            }
            .navigationTitle("Favorites")
            .toolbar {
                if !viewModel.favorites.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            }
            .alert("Cannot Connect", isPresented: Binding(
                get: { reconnectError != nil },
                set: { if !$0 { reconnectError = nil } }
            )) {
                Button("OK", role: .cancel) { reconnectError = nil }
            } message: {
                Text(reconnectError ?? "")
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView(
            "No Favorites",
            systemImage: "star",
            description: Text("Tap the star button on any station in the Directory to save it here.")
        )
    }

    private var favoritesList: some View {
        List {
            ForEach(viewModel.favorites, id: \.id) { station in
                let current = currentStation(for: station)
                HStack {
                    StationRow(
                        station: current,
                        isFavorite: true,
                        onSelect: current.isRelayOnly ? nil : { connect(to: station) },
                        onFavoriteTap: { viewModel.remove(station) },
                        selectionHint: current.isRelayOnly ? nil : "Connect to this station"
                    )
                    .disabled(connectingID != nil)
                    if connectingID == station.id { ProgressView().controlSize(.small) }
                }
            }
            .onDelete { viewModel.remove(at: $0) }
            .onMove   { viewModel.move(from: $0, to: $1) }
        }
        .listStyle(.plain)
    }

    private func connect(to station: Station) {
        guard connectingID == nil else { return }
        connectingID = station.id
        Task {
            defer { connectingID = nil }
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

    private func currentStation(for station: Station) -> Station {
        StationEndpointResolver.resolveStored(station, from: appState.directoryService.stations) ?? station
    }
}
