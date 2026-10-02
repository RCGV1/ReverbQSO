// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// View model managing the user's favorite (bookmarked) stations.
///
/// Persists favorites in UserDefaults as a JSON-encoded array of Station objects.
@MainActor
final class FavoritesViewModel: ObservableObject {

    // MARK: - Published State

    @Published var favorites: [Station] = []

    // MARK: - Storage

    private static let storageKey = "org.OpenEchoLink.favorites"
    private let productionDefaults: UserDefaults
    private var defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.productionDefaults = defaults
        loadFavorites()
    }

    /// Reloads persisted favorites so multiple views sharing the store stay current.
    func reload() {
        loadFavorites()
    }

    func setDemoMode(_ enabled: Bool) {
        defaults = enabled ? UserDefaults(suiteName: "com.benjaminfaershtein.ReverbQSO.demo")! : productionDefaults
        loadFavorites()
    }

    // MARK: - CRUD

    /// Add a station to favorites.
    func add(_ station: Station) {
        guard !favorites.contains(where: { $0.callsign == station.callsign }) else { return }
        favorites.append(station)
        saveFavorites()
    }

    /// Remove a station from favorites.
    func remove(_ station: Station) {
        favorites.removeAll { $0.callsign == station.callsign }
        saveFavorites()
    }

    /// Remove stations at the given index offsets.
    func remove(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        saveFavorites()
    }

    /// Move stations within the list.
    func move(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        saveFavorites()
    }

    /// Check if a station is in the favorites list.
    func isFavorite(_ station: Station) -> Bool {
        favorites.contains { $0.callsign == station.callsign }
    }

    /// Toggle a station's favorite status.
    func toggleFavorite(_ station: Station) {
        if isFavorite(station) {
            remove(station)
        } else {
            add(station)
        }
    }

    // MARK: - Persistence

    private func saveFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func loadFavorites() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Station].self, from: data) else {
            favorites = []
            return
        }
        favorites = decoded
    }
}
