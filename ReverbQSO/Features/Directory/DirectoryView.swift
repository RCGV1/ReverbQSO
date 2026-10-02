// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The main directory view showing all EchoLink stations.
struct DirectoryView: View {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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

                HStack(spacing: 12) {
                    if viewModel.browseGroup == .nodes {
                        typeFilterPicker
                    }
                    Button { showingCountryFilter = true } label: {
                        if horizontalSizeClass == .compact {
                            Label(countryFilterTitle, systemImage: "globe").labelStyle(.iconOnly)
                        } else {
                            Label(countryFilterTitle, systemImage: "globe").lineLimit(1)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.countryFilter.isEmpty ? Color.primary : .accentColor)
                    .accessibilityLabel("Country: \(countryFilterTitle)")
                    Spacer()
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing directory")
                    }
                    Picker(selection: $viewModel.sortOrder) {
                        ForEach(DirectoryViewModel.SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    } label: {
                        Label(viewModel.sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Sort stations")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                stationList
            }
            .navigationTitle("Directory")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
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
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var countryFilterTitle: String {
        viewModel.countryFilter.isEmpty ? "All countries" :
            (viewModel.availableCountries.first { $0.code == viewModel.countryFilter }?.name ?? viewModel.countryFilter)
    }

    // MARK: - Type Filter Picker

    private var typeFilterPicker: some View {
        Picker(selection: $viewModel.typeFilter) {
            Text("All nodes").tag(Station.StationType?.none)
            Text("Links").tag(Station.StationType?.some(.link))
            Text("Repeaters").tag(Station.StationType?.some(.repeater))
            Text("Conferences").tag(Station.StationType?.some(.conference))
        } label: {
            Label(viewModel.typeFilter?.displayName ?? "All nodes", systemImage: "line.3.horizontal.decrease")
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Filter stations by type")
    }

    // MARK: - Station List

    private var stationList: some View {
        List {
            ForEach(viewModel.stations) { station in
                StationRow(
                    station: station,
                    isFavorite: favoritesVM.isFavorite(station),
                    onSelect: { detailStation = station },
                    onFavoriteTap: { favoritesVM.toggleFavorite(station) }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain)
        .refreshable { await viewModel.refresh() }
        .overlay { listOverlay }
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
            ContentUnavailableView.search(text: viewModel.searchText)
        } else if viewModel.stations.isEmpty {
            ContentUnavailableView(
                viewModel.browseGroup == .nodes ? "No Nodes" : "No People",
                systemImage: viewModel.browseGroup == .nodes
                    ? "antenna.radiowaves.left.and.right.slash"
                    : "person.slash",
                description: Text(viewModel.browseGroup == .nodes
                    ? "Try a different node filter or pull down to refresh."
                    : "Pull down to refresh the operator directory.")
            )
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
