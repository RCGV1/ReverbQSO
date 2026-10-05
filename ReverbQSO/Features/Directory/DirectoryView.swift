// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The main directory view showing all EchoLink stations.
struct DirectoryView: View {

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject var connectionService: EchoLinkConnectionService
    @StateObject private var viewModel: DirectoryViewModel
    @EnvironmentObject private var favoritesVM: FavoritesViewModel

    @State private var detailStation: Station?
    @State private var callCQService: CallCQService?
    @State private var showingCountryFilter = false

    init(directoryService: EchoLinkDirectoryService) {
        _viewModel = StateObject(wrappedValue: DirectoryViewModel(directoryService: directoryService))
    }

    var body: some View {
        StandaloneNavigationContainer {
            VStack(spacing: 0) {
                Picker("Browse directory", selection: $viewModel.browseGroup) {
                    ForEach(DirectoryViewModel.BrowseGroup.allCases) { group in
                        Text(group.rawValue).tag(group)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if viewModel.hasActiveFilters {
                    activeFilters
                }

                stationList
            }
            .navigationTitle("Directory")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    DirectoryFiltersMenu(viewModel: viewModel) {
                        showingCountryFilter = true
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentCallCQ()
                    } label: {
                        Label("Call CQ", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(!appState.isLoggedIn || !appState.qsoHub.entries.isEmpty)
                    .accessibilityIdentifier("directory-call-cq")
                }
            }
            .task { await viewModel.refreshIfNeeded() }
            #if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
            .onAppear {
                if SimulatorDemoData.isEnabled && SimulatorDemoData.screen == "station" {
                    detailStation = SimulatorDemoData.stations[1]
                }
                if SimulatorDemoData.isEnabled
                    && ProcessInfo.processInfo.arguments.contains("--simulator-demo-people") {
                    viewModel.browseGroup = .people
                }
            }
            #endif
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: viewModel.browseGroup == .nodes
                    ? "Callsign, node, or description"
                    : "Callsign or operator description"
            )
            .sheet(item: $detailStation) { station in
                let liveStation = viewModel.station(id: station.id)
                let currentStation = liveStation ?? station
                StationDetailSheet(
                    station: currentStation,
                    isOnline: liveStation != nil,
                    isFavorite: favoritesVM.isFavorite(currentStation),
                    currentCallsign: appState.currentUser,
                    savedCallsigns: appState.savedAccounts,
                    onFavoriteToggle: { favoritesVM.toggleFavorite(currentStation) },
                    onConnect: { callsign in
                        guard let latestStation = viewModel.station(id: station.id) else {
                            viewModel.errorMessage = "This station is no longer in the directory. Refresh and try again."
                            return
                        }
                        connectToStation(latestStation, as: callsign)
                    }
                )
            }
            .sheet(item: $callCQService) { service in
                CallCQView(service: service) { station in
                    Task {
                        await appState.connectToCallCQMatch(station)
                        viewModel.errorMessage = appState.qsoHub.lastError
                    }
                }
            }
            .sheet(isPresented: $showingCountryFilter) {
                CountryFilterView(
                    countries: viewModel.availableCountries,
                    selectedCode: $viewModel.countryFilter
                )
            }
            .alert("Error", isPresented: Binding(
                get: {
                    guard !appState.isAutoLoggingIn else { return false }
                    if let error = appState.directoryService.error,
                       !appState.directoryService.isLoggedIn,
                       !DirectoryRegistrationFailurePolicy.requiresUserSignIn(error),
                       viewModel.errorMessage == error.localizedDescription { return false }
                    return viewModel.errorMessage != nil
                },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var activeFilters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { activeFilterButtons }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) { activeFilterButtons }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var activeFilterButtons: some View {
        if let region = viewModel.regionFilter {
            Button { viewModel.regionFilter = nil } label: {
                removableFilter(region.rawValue)
            }
            .accessibilityLabel("Remove region filter, \(region.rawValue)")
        }
        if viewModel.browseGroup == .nodes, viewModel.typeFilter != nil {
            Button { viewModel.typeFilter = nil } label: {
                removableFilter(viewModel.nodeTypeTitle)
            }
            .accessibilityLabel("Remove node type filter, \(viewModel.nodeTypeTitle)")
        }
        if !viewModel.countryFilter.isEmpty {
            Button { viewModel.countryFilter = "" } label: {
                removableFilter([CountryFlag.emoji(for: viewModel.countryFilter), viewModel.countryFilterTitle]
                    .compactMap { $0 }.joined(separator: " "))
            }
            .accessibilityLabel("Remove country filter, \(viewModel.countryFilterTitle)")
        }
    }

    private func removableFilter(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "xmark")
                .imageScale(.small)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Station List

    private var stationList: some View {
        List {
            if viewModel.sortOrder == .region {
                ForEach(viewModel.regionSections) { section in
                    Section(section.title) {
                        ForEach(section.stations) { station in stationRow(station) }
                    }
                }
            } else {
                ForEach(viewModel.stations) { station in stationRow(station) }
            }
        }
        .listStyle(.plain)
        .refreshable { await viewModel.refresh() }
        .overlay { listOverlay }
    }

    private func stationRow(_ station: Station) -> some View {
        StationRow(
            station: station,
            isFavorite: favoritesVM.isFavorite(station),
            onSelect: { detailStation = station },
            onFavoriteTap: { favoritesVM.toggleFavorite(station) }
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    // MARK: - Empty / Loading Overlay

    @ViewBuilder
    private var listOverlay: some View {
        if viewModel.isLoading && viewModel.stations.isEmpty {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.3)
                Text("Loading stations...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if !viewModel.searchText.isEmpty && viewModel.stations.isEmpty {
            VStack {
                ContentUnavailableView.search(text: viewModel.searchText)
                if viewModel.hasActiveFilters {
                    Button("Clear Filters") { viewModel.clearFilters() }
                        .buttonStyle(.bordered)
                }
            }
        } else if viewModel.stations.isEmpty {
            ContentUnavailableView {
                Label(viewModel.browseGroup == .nodes ? "No Nodes" : "No People",
                      systemImage: viewModel.browseGroup == .nodes
                          ? "antenna.radiowaves.left.and.right.slash" : "person.slash")
            } description: {
                Text(viewModel.hasActiveFilters ? "No matches for these filters." : "Pull down to refresh.")
            } actions: {
                if viewModel.hasActiveFilters {
                    Button("Clear Filters") { viewModel.clearFilters() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func connectToStation(_ station: Station, as callsign: String) {
        Task {
            await appState.connect(to: station, as: callsign)
            viewModel.errorMessage = appState.qsoHub.lastError
        }
    }

    private func presentCallCQ() {
        callCQService = CallCQService(
            backendFactory: { preferences in await appState.makeCallCQBackend(preferences: preferences) }
        )
    }

}
