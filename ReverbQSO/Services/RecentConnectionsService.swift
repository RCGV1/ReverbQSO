// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Persists the last 20 QSO sessions so users can quickly reconnect.
@MainActor
final class RecentConnectionsService: ObservableObject {

    // MARK: - Published State

    @Published var recents: [RecentConnection] = []

    // MARK: - Storage

    private static let storageKey = "recentConnections"
    private static let maxEntries = 20

    private let productionDefaults: UserDefaults
    private var defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.productionDefaults = defaults
        self.defaults = defaults
        load()
    }

    func setDemoMode(_ enabled: Bool) {
        defaults = enabled ? UserDefaults(suiteName: "com.benjaminfaershtein.ReverbQSO.demo")! : productionDefaults
        load()
    }

    // MARK: - Public API

    /// Record a completed QSO session.
    func record(station: Station, duration: TimeInterval) {
        let entry = RecentConnection(station: station, date: Date(), duration: duration)
        recents.insert(entry, at: 0)
        if recents.count > Self.maxEntries {
            recents = Array(recents.prefix(Self.maxEntries))
        }
        save()
    }

    /// Remove a single entry.
    func remove(at offsets: IndexSet) {
        recents.remove(atOffsets: offsets)
        save()
    }

    /// Remove all entries.
    func clear() {
        recents.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([RecentConnection].self, from: data) else {
            recents = []
            return
        }
        recents = decoded
    }
}
