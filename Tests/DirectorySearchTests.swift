// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

@MainActor
final class DirectorySearchTests: XCTestCase {

    func testFilterSummaryReflectsEffectiveFiltersWhenBrowsingPeople() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.typeFilter = .repeater
        XCTAssertTrue(viewModel.hasActiveFilters)
        XCTAssertEqual(viewModel.filterSummary, "Repeaters · All countries")

        viewModel.browseGroup = .people
        XCTAssertFalse(viewModel.hasActiveFilters)
        XCTAssertEqual(viewModel.filterSummary, "People · All countries")

        viewModel.countryFilter = "AU"
        XCTAssertTrue(viewModel.hasActiveFilters)
        XCTAssertEqual(viewModel.countryFilterTitle, Locale.current.localizedString(forRegionCode: "AU"))
        viewModel.browseGroup = .nodes
        XCTAssertTrue(viewModel.filterSummary.hasPrefix("Repeaters · "))
    }

    func testCountryChoicesFollowBrowseScopeAndKeepSelectedCountry() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.ingest([
            Station(callsign: "VK2ABC", ipAddress: "192.0.2.1", type: .user),
            Station(callsign: "F4ABC-R", ipAddress: "192.0.2.2", type: .repeater),
            Station(callsign: "K6ABC-L", ipAddress: "192.0.2.3", type: .link)
        ])
        XCTAssertEqual(Set(viewModel.availableCountries.map(\.code)), ["FR", "US"])
        viewModel.typeFilter = .repeater
        XCTAssertEqual(viewModel.availableCountries.map(\.code), ["FR"])
        viewModel.countryFilter = "FR"
        viewModel.browseGroup = .people
        XCTAssertEqual(Set(viewModel.availableCountries.map(\.code)), ["AU", "FR"])
        viewModel.clearFilters()
        XCTAssertEqual(viewModel.availableCountries.map(\.code), ["AU"])
        viewModel.browseGroup = .nodes
        XCTAssertEqual(viewModel.typeFilter, .repeater)
        XCTAssertEqual(viewModel.availableCountries.map(\.code), ["FR"])
    }

    func testClearFiltersRestoresMatchesAndPreservesSearchAndSort() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.ingest([
            Station(callsign: "VK2ABC-L", description: "Hilltop", ipAddress: "192.0.2.1", type: .link, nodeNumber: 2),
            Station(callsign: "F4ABC-R", description: "Hilltop", ipAddress: "192.0.2.2", type: .repeater, nodeNumber: 1)
        ])
        viewModel.searchText = "Hilltop"
        viewModel.sortOrder = .nodeNumber
        viewModel.typeFilter = .repeater
        viewModel.countryFilter = "AU"
        XCTAssertTrue(viewModel.stations.isEmpty)

        viewModel.clearFilters()
        XCTAssertFalse(viewModel.hasActiveFilters)
        XCTAssertNil(viewModel.typeFilter)
        XCTAssertEqual(viewModel.countryFilter, "")
        XCTAssertEqual(viewModel.searchText, "Hilltop")
        XCTAssertEqual(viewModel.sortOrder, .nodeNumber)
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["F4ABC-R", "VK2ABC-L"])
    }

    func testSupersededRefreshDoesNotReportSuccessOrExposeOldStationsForReconnect() async {
        let firstStarted = expectation(description: "first refresh started")
        let secondStarted = expectation(description: "second refresh started")
        var pending: [CheckedContinuation<[Station], Error>] = []
        let service = EchoLinkDirectoryService(fetchStationsForRefresh: {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                (pending.count == 1 ? firstStarted : secondStarted).fulfill()
            }
        })
        service.isLoggedIn = true
        service.stations = [Station(callsign: "K1ABC-R", ipAddress: "192.0.2.10", nodeNumber: 12345)]

        let first = Task { await service.refresh() }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { await service.refresh() }
        await fulfillment(of: [secondStarted], timeout: 2)

        pending[0].resume(returning: [Station(callsign: "K1ABC-R", ipAddress: "198.51.100.20", nodeNumber: 12345)])
        let firstSucceeded = await first.value
        XCTAssertFalse(firstSucceeded)
        XCTAssertEqual(service.stations[0].ipAddress, "192.0.2.10")
        XCTAssertNil(service.error)

        pending[1].resume(returning: [Station(callsign: "K1ABC-R", ipAddress: "203.0.113.30", nodeNumber: 12345)])
        let secondSucceeded = await second.value
        XCTAssertTrue(secondSucceeded)
        XCTAssertEqual(service.stations[0].ipAddress, "203.0.113.30")
    }

    func testViewModelRefreshesExistingDirectorySnapshotOnFirstAppearance() async {
        var refreshCount = 0
        let service = EchoLinkDirectoryService(fetchStationsForRefresh: {
            refreshCount += 1
            return [Station(callsign: "K6FRESH-R", ipAddress: "203.0.113.10", type: .repeater)]
        })
        service.isLoggedIn = true
        service.stations = [Station(callsign: "K6STALE-R", ipAddress: "192.0.2.10", type: .repeater)]
        let viewModel = DirectoryViewModel(directoryService: service)

        await viewModel.refreshIfNeeded(now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(service.stations.map(\.callsign), ["K6FRESH-R"])
    }

    func testViewModelKeepsStationIdentityAcrossRefresh() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        let first = Station(callsign: "K6ABC-R", description: "Old location", ipAddress: "10.0.0.1", type: .repeater, nodeNumber: 123)
        viewModel.ingest([first])
        let stableID = viewModel.stations[0].id

        let refreshed = Station(callsign: "K6ABC-R", description: "New location", ipAddress: "10.0.0.2", type: .repeater, isBusy: true, nodeNumber: 123)
        viewModel.ingest([refreshed])

        XCTAssertEqual(viewModel.stations[0].id, stableID)
        XCTAssertEqual(viewModel.station(id: stableID)?.ipAddress, "10.0.0.2")
        XCTAssertTrue(viewModel.stations[0].isBusy)
    }

    func testViewModelSortsAndFiltersWithoutChangingIdentity() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.ingest([
            Station(callsign: "W6Z", ipAddress: "10.0.0.1", type: .link, nodeNumber: 9),
            Station(callsign: "K6A-R", ipAddress: "10.0.0.2", type: .repeater, nodeNumber: 20),
            Station(callsign: "N6B", ipAddress: "10.0.0.3", type: .link, nodeNumber: 3)
        ])
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["K6A-R", "N6B", "W6Z"])
        let ids = Dictionary(uniqueKeysWithValues: viewModel.stations.map { ($0.callsign, $0.id) })

        viewModel.sortOrder = .nodeNumber
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["N6B", "W6Z", "K6A-R"])

        viewModel.typeFilter = .link
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["N6B", "W6Z"])
        XCTAssertEqual(viewModel.stations.map(\.id), ["N6B", "W6Z"].compactMap { ids[$0] })
    }

    func testSelectedCountryRemainsSelectableWhenItsLastStationGoesOffline() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.ingest([Station(callsign: "VK2ABC-L", ipAddress: "192.0.2.1", type: .link)])
        viewModel.countryFilter = "AU"
        viewModel.ingest([Station(callsign: "F4ABC-R", ipAddress: "192.0.2.2", type: .repeater)])
        XCTAssertEqual(viewModel.countryFilter, "AU")
        XCTAssertTrue(viewModel.stations.isEmpty)
        XCTAssertTrue(viewModel.availableCountries.contains { $0.code == "AU" && $0.name != "AU" })
        viewModel.countryFilter = ""
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["F4ABC-R"])
        XCTAssertEqual(viewModel.availableCountries.map(\.code), ["FR"])
    }

    func testCountryFilterUsesCallsignPrefixInsteadOfAdvertisedDescription() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.ingest([
            Station(callsign: "VK2ABC-L", description: "Paris, France", ipAddress: "10.0.0.1", type: .link),
            Station(callsign: "F4ABC-R", description: "Sydney, Australia", ipAddress: "10.0.0.2", type: .repeater),
            Station(callsign: "*ECHOTEST*", description: "United States", ipAddress: "10.0.0.3", type: .conference)
        ])

        XCTAssertEqual(viewModel.availableCountries.map(\.code), ["AU", "FR"])
        viewModel.countryFilter = "AU"
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["VK2ABC-L"])

        viewModel.countryFilter = ""
        XCTAssertEqual(Set(viewModel.stations.map(\.callsign)), ["VK2ABC-L", "F4ABC-R", "*ECHOTEST*"])
    }

    func testCountryFilterAndSortPreserveStableIdentityAcrossRefresh() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.ingest([
            Station(callsign: "VK2Z-L", ipAddress: "10.0.0.1", type: .link, nodeNumber: 9),
            Station(callsign: "VK2A-R", ipAddress: "10.0.0.2", type: .repeater, nodeNumber: 20),
            Station(callsign: "F4ABC-R", ipAddress: "10.0.0.3", type: .repeater, nodeNumber: 3)
        ])
        viewModel.countryFilter = "AU"
        viewModel.sortOrder = .nodeNumber
        let ids = Dictionary(uniqueKeysWithValues: viewModel.stations.map { ($0.callsign, $0.id) })

        viewModel.ingest([
            Station(callsign: "VK2Z-L", description: "Updated", ipAddress: "10.0.1.1", type: .link, nodeNumber: 9),
            Station(callsign: "VK2A-R", description: "Updated", ipAddress: "10.0.1.2", type: .repeater, nodeNumber: 20),
            Station(callsign: "DL1ABC-R", ipAddress: "10.0.1.3", type: .repeater, nodeNumber: 4)
        ])

        XCTAssertEqual(viewModel.countryFilter, "AU")
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["VK2Z-L", "VK2A-R"])
        XCTAssertEqual(viewModel.stations.map(\.id), ["VK2Z-L", "VK2A-R"].compactMap { ids[$0] })
        XCTAssertEqual(viewModel.availableCountries.map(\.code), ["AU", "DE"])
    }

    func testSearchMatchesPrecomputedCountryNameAndCode() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.ingest([
            Station(callsign: "VK2ABC-L", description: "Unrelated text", ipAddress: "10.0.0.1", type: .link),
            Station(callsign: "F4ABC-R", description: "Unrelated text", ipAddress: "10.0.0.2", type: .repeater)
        ])

        viewModel.searchText = "Australia"
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["VK2ABC-L"])
        viewModel.searchText = "FR"
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["F4ABC-R"])
    }

    func testViewModelFiltersUsersSeparatelyFromLinks() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.ingest([
            Station(callsign: "W6USER", ipAddress: "10.0.0.1", type: .user),
            Station(callsign: "K6LINK-L", ipAddress: "10.0.0.2", type: .link),
            Station(callsign: "K6REPEATER-R", ipAddress: "10.0.0.3", type: .repeater),
            Station(callsign: "*BAYNET*", ipAddress: "10.0.0.4", type: .conference)
        ])

        XCTAssertEqual(viewModel.browseGroup, .nodes)
        XCTAssertEqual(Set(viewModel.stations.map(\.callsign)), ["K6LINK-L", "K6REPEATER-R", "*BAYNET*"])

        viewModel.browseGroup = .people

        XCTAssertEqual(viewModel.stations.map(\.callsign), ["W6USER"])
    }

    func testSwitchingPeopleAndNodesPreservesSearchSortAndNodeFilter() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.ingest([
            Station(callsign: "K6OP", description: "Hilltop operator", ipAddress: "10.0.0.1", type: .user, nodeNumber: 10),
            Station(callsign: "K6LINK-L", description: "Hilltop link", ipAddress: "10.0.0.2", type: .link, nodeNumber: 30),
            Station(callsign: "K6OTHER-R", description: "Hilltop repeater", ipAddress: "10.0.0.3", type: .repeater, nodeNumber: 20)
        ])
        viewModel.searchText = "hilltop"
        viewModel.sortOrder = .nodeNumber
        viewModel.typeFilter = .link
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["K6LINK-L"])

        viewModel.browseGroup = .people
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["K6OP"])
        XCTAssertEqual(viewModel.searchText, "hilltop")

        viewModel.browseGroup = .nodes
        XCTAssertEqual(viewModel.typeFilter, .link)
        XCTAssertEqual(viewModel.sortOrder, .nodeNumber)
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["K6LINK-L"])
    }

    func testViewModelSearchUsesCurrentQueryImmediately() {
        let viewModel = DirectoryViewModel(directoryService: EchoLinkDirectoryService())
        viewModel.browseGroup = .people
        viewModel.ingest([
            Station(callsign: "K6ABC", ipAddress: "10.0.0.1"),
            Station(callsign: "W6XYZ", ipAddress: "10.0.0.2")
        ])

        viewModel.searchText = "K6"
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["K6ABC"])

        viewModel.searchText = "W6"
        XCTAssertEqual(viewModel.stations.map(\.callsign), ["W6XYZ"])
    }

    func testSearchMatchesCallsignAndDescription() {
        let service = EchoLinkDirectoryService()
        service.stations = [
            Station(callsign: "W6ABC-R", description: "Hilltop Repeater", ipAddress: "10.0.0.1", type: .repeater, nodeNumber: 12345),
            Station(callsign: "K6XYZ", description: "Portable Link", ipAddress: "10.0.0.2", type: .link, nodeNumber: 777)
        ]

        service.search(query: "hilltop")
        XCTAssertEqual(service.filteredStations.count, 1)
        XCTAssertEqual(service.filteredStations.first?.callsign, "W6ABC-R")

        service.search(query: "k6xyz")
        XCTAssertEqual(service.filteredStations.count, 1)
        XCTAssertEqual(service.filteredStations.first?.callsign, "K6XYZ")
    }

    func testSearchMatchesNodeAndCompactCallsign() {
        let service = EchoLinkDirectoryService()
        service.stations = [
            Station(callsign: "*BAYNET*", description: "Regional Conference", ipAddress: "10.0.0.10", type: .conference, nodeNumber: 654321),
            Station(callsign: "W6ABC-R", description: "Hilltop Repeater", ipAddress: "10.0.0.1", type: .repeater, nodeNumber: 12345)
        ]

        service.search(query: "654321")
        XCTAssertEqual(service.filteredStations.count, 1)
        XCTAssertEqual(service.filteredStations.first?.callsign, "*BAYNET*")

        service.search(query: "w6abc")
        XCTAssertEqual(service.filteredStations.count, 1)
        XCTAssertEqual(service.filteredStations.first?.callsign, "W6ABC-R")

        // Collapsed queries without punctuation should still match.
        service.search(query: "w6abcr")
        XCTAssertEqual(service.filteredStations.count, 1)
        XCTAssertEqual(service.filteredStations.first?.callsign, "W6ABC-R")
    }
}
