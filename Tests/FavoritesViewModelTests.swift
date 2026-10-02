// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class FavoritesViewModelTests: XCTestCase {
    func testSecondViewModelCanReloadFavoritesWrittenByFirst() {
        let suite = "FavoritesViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let first = FavoritesViewModel(defaults: defaults)
        let second = FavoritesViewModel(defaults: defaults)
        let station = Station(callsign: "N0TEST-L", ipAddress: "192.0.2.1")

        first.add(station)
        second.reload()

        XCTAssertTrue(second.isFavorite(station))
    }
}
