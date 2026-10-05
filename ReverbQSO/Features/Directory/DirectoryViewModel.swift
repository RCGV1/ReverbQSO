// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import os

/// View model for the Directory feature, wrapping the EchoLinkDirectoryService.
@MainActor
final class DirectoryViewModel: ObservableObject {

    struct CountryOption: Identifiable, Hashable {
        let code: String
        let name: String

        var id: String { code }
    }

    struct RegionSection: Identifiable {
        let region: StationRegion?
        let stations: [Station]

        var id: String { region?.rawValue ?? "other" }
        var title: String { region?.rawValue ?? "Other stations" }
    }

    enum BrowseGroup: String, CaseIterable, Identifiable {
        case nodes = "Nodes"
        case people = "People"

        var id: Self { self }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case callsign = "Callsign"
        case nodeNumber = "Node number"
        case region = "Region"

        var id: Self { self }
    }

    // MARK: - Published State (forwarded from service)

    @Published var stations: [Station] = []
    @Published var isLoading = false
    @Published var searchText = "" {
        didSet { applyLocalFilter() }
    }
    @Published var errorMessage: String?
    @Published var selectedStation: Station?
    @Published var browseGroup: BrowseGroup = .nodes {
        didSet { rebuildAvailableCountries(); applyLocalFilter() }
    }
    @Published var typeFilter: Station.StationType? {
        didSet { rebuildAvailableCountries(); applyLocalFilter() }
    }
    /// Empty means all countries. Values are ISO 3166 codes derived from the
    /// station callsign's ITU allocation, matching EchoLink's Locations list.
    @Published var countryFilter = "" {
        didSet {
            if !countryFilter.isEmpty, let regionFilter,
               StationRegion.forCountry(countryFilter) != regionFilter {
                self.regionFilter = nil
            }
            rebuildAvailableCountries(); applyLocalFilter()
        }
    }
    @Published var regionFilter: StationRegion? {
        didSet {
            if let regionFilter, !countryFilter.isEmpty,
               StationRegion.forCountry(countryFilter) != regionFilter {
                countryFilter = ""
            }
            rebuildAvailableCountries(); applyLocalFilter()
        }
    }
    @Published private(set) var regionSections: [RegionSection] = []
    @Published private(set) var availableCountries: [CountryOption] = []
    @Published var sortOrder: SortOrder = .callsign {
        didSet { applyLocalFilter() }
    }

    // MARK: - Dependencies

    private let directoryService: EchoLinkDirectoryService
    private var cancellables = Set<AnyCancellable>()
    private var allStations: [Station] = []
    private var indexedStations: [IndexedStation] = []
    private var stableIDs: [StationKey: UUID] = [:]
    private var lastRefreshAt: Date?
    private let logger = Logger(subsystem: "org.reverbqso.app", category: "DirectorySearch")
    private static let enableSearchDebugLogging = ProcessInfo.processInfo.environment["OEL_SEARCH_DEBUG"] == "1"

    private struct IndexedStation {
        let station: Station
        let countryCode: String?
        let countryName: String?
        let region: StationRegion?
        let searchBlob: String
        let compactBlob: String
    }

    private struct StationKey: Hashable {
        let callsign: String
        let nodeNumber: Int
        let occurrence: Int
    }

    init(directoryService: EchoLinkDirectoryService) {
        self.directoryService = directoryService
        lastRefreshAt = directoryService.lastSuccessfulSnapshotAt
        bindToService()
    }

    // MARK: - Actions

    var hasActiveFilters: Bool {
        regionFilter != nil || !countryFilter.isEmpty || (browseGroup == .nodes && typeFilter != nil)
    }

    var countryFilterTitle: String {
        countryFilter.isEmpty ? "All countries" :
            (availableCountries.first { $0.code == countryFilter }?.name ?? countryFilter)
    }

    var nodeTypeTitle: String {
        switch typeFilter {
        case .link: "Links"
        case .repeater: "Repeaters"
        case .conference: "Conferences"
        default: "All nodes"
        }
    }

    var filterSummary: String {
        let group = browseGroup == .people ? "People" : nodeTypeTitle
        return [group, regionFilter?.rawValue, countryFilterTitle].compactMap { $0 }.joined(separator: " · ")
    }

    func clearFilters() {
        if browseGroup == .nodes { typeFilter = nil }
        countryFilter = ""
        regionFilter = nil
    }

    func refresh() async {
        if await directoryService.refresh() {
            lastRefreshAt = directoryService.lastSuccessfulSnapshotAt ?? .now
        }
    }

    func refreshIfNeeded(now: Date = .now) async {
        guard directoryService.isLoggedIn, !directoryService.isLoading else { return }
        guard lastRefreshAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        await refresh()
    }

    func station(id: UUID) -> Station? {
        allStations.first { $0.id == id }
    }

    func search(query: String) {
        searchText = query
    }

    // MARK: - Binding

    private func bindToService() {
        directoryService.$stations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stations in
                self?.ingest(stations)
            }
            .store(in: &cancellables)

        directoryService.$isLoading
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLoading)

        directoryService.$error
            .receive(on: DispatchQueue.main)
            .map { $0?.localizedDescription }
            .removeDuplicates()
            .assign(to: &$errorMessage)

        directoryService.$lastSuccessfulSnapshotAt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastRefreshAt = $0 }
            .store(in: &cancellables)

    }

    func ingest(_ incoming: [Station]) {
        var occurrences: [String: Int] = [:]
        allStations = incoming.map { station in
            let callsign = station.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let base = "\(callsign)#\(station.nodeNumber)"
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            let key = StationKey(callsign: callsign, nodeNumber: station.nodeNumber, occurrence: occurrence)
            let id = stableIDs[key] ?? station.id
            stableIDs[key] = id
            return Station(
                id: id,
                callsign: station.callsign,
                description: station.description,
                ipAddress: station.ipAddress,
                port: station.port,
                type: station.type,
                isBusy: station.isBusy,
                nodeNumber: station.nodeNumber
            )
        }
        rebuildIndex()
        rebuildAvailableCountries()
        applyLocalFilter()
    }

    private func applyLocalFilter() {
        let query = normalized(searchText)
        let collapsedQuery = collapsed(searchText)
        let selectedCountry = countryFilter
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let typeFilterLabel = typeFilter?.displayName ?? "All"

        if Self.enableSearchDebugLogging {
            logger.debug(
                "Search start query='\(self.searchText, privacy: .public)' normalized='\(query, privacy: .public)' collapsed='\(collapsedQuery, privacy: .public)' group='\(self.browseGroup.rawValue, privacy: .public)' typeFilter='\(typeFilterLabel, privacy: .public)' sourceCount=\(self.allStations.count) indexCount=\(self.indexedStations.count)"
            )
        }

        let filtered = indexedStations.filter { indexed in
            let station = indexed.station
            switch browseGroup {
            case .nodes:
                guard station.type != .user else { return false }
                if let typeFilter, station.type != typeFilter { return false }
            case .people:
                guard station.type == .user else { return false }
            }
            if let regionFilter, indexed.region != regionFilter { return false }
            if !selectedCountry.isEmpty, indexed.countryCode != selectedCountry {
                return false
            }
            guard !query.isEmpty else {
                return true
            }

            let tokens = query.split(whereSeparator: \.isWhitespace)
            let tokenMatch = tokens.allSatisfy { indexed.searchBlob.contains(String($0)) }
            let compactMatch = !collapsedQuery.isEmpty && indexed.compactBlob.contains(collapsedQuery)

            return tokenMatch || compactMatch
        }

        let sorted = filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .region:
                let leftRank = lhs.region?.sortIndex ?? Int.max
                let rightRank = rhs.region?.sortIndex ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                let countryOrder = (lhs.countryName ?? "").localizedStandardCompare(rhs.countryName ?? "")
                if countryOrder != .orderedSame { return countryOrder == .orderedAscending }
            case .nodeNumber:
                if lhs.station.nodeNumber != rhs.station.nodeNumber { return lhs.station.nodeNumber < rhs.station.nodeNumber }
            case .callsign: break
            }
            let result = lhs.station.callsign.localizedStandardCompare(rhs.station.callsign)
            if result != .orderedSame { return result == .orderedAscending }
            if lhs.station.nodeNumber != rhs.station.nodeNumber { return lhs.station.nodeNumber < rhs.station.nodeNumber }
            return lhs.station.id.uuidString < rhs.station.id.uuidString
        }
        stations = sorted.map(\.station)
        // Build section membership once per filter/snapshot update, preserving
        // the sort order and IDs instead of regrouping inside SwiftUI's body.
        if sortOrder == .region {
            var groups: [StationRegion: [Station]] = [:]
            var other: [Station] = []
            for indexed in sorted {
                if let region = indexed.region { groups[region, default: []].append(indexed.station) }
                else { other.append(indexed.station) }
            }
            regionSections = StationRegion.allCases.compactMap { region in
                groups[region].map { RegionSection(region: region, stations: $0) }
            }
            if !other.isEmpty { regionSections.append(RegionSection(region: nil, stations: other)) }
        } else {
            regionSections = []
        }

        let sample = stations.prefix(3).map(\.callsign).joined(separator: ",")
        if Self.enableSearchDebugLogging {
            logger.debug(
                "Search end resultCount=\(self.stations.count) sample='\(sample, privacy: .public)'"
            )
        }
    }

    private func rebuildIndex() {
        var localizedNames: [String: String] = [:]
        indexedStations = allStations.map { station in
            let countryCode = station.callSignCountryCode
            let region = StationRegion.forCountry(countryCode)
            let countryName = countryCode.map { code in
                if let cached = localizedNames[code] { return cached }
                let resolved = Self.localizedCountryName(code) ?? code
                localizedNames[code] = resolved
                return resolved
            }
            let stationBlob = [
                station.callsign,
                station.description,
                countryCode ?? "",
                countryName ?? "",
                region?.rawValue ?? "",
                station.type.displayName,
                station.type == .user ? "user individual" : "",
                String(station.nodeNumber)
            ].joined(separator: " ")

            return IndexedStation(
                station: station,
                countryCode: countryCode,
                countryName: countryName,
                region: region,
                searchBlob: normalized(stationBlob),
                compactBlob: collapsed(stationBlob)
            )
        }

        if Self.enableSearchDebugLogging {
            logger.debug(
                "Search index rebuilt stationCount=\(self.allStations.count) indexedCount=\(self.indexedStations.count)"
            )
        }
    }

    private func rebuildAvailableCountries() {
        var namesByCode = indexedStations.reduce(into: [String: String]()) { result, indexed in
            if browseGroup == .people {
                guard indexed.station.type == .user else { return }
            } else {
                guard indexed.station.type != .user else { return }
                if let typeFilter, indexed.station.type != typeFilter { return }
            }
            if let regionFilter, indexed.region != regionFilter { return }
            guard let code = indexed.countryCode, let name = indexed.countryName else { return }
            result[code] = name
        }
        if !countryFilter.isEmpty, namesByCode[countryFilter] == nil {
            namesByCode[countryFilter] = Self.localizedCountryName(countryFilter) ?? countryFilter
        }
        availableCountries = namesByCode.map {
            CountryOption(code: $0.key, name: $0.value)
        }.sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            return result == .orderedSame ? $0.code < $1.code : result == .orderedAscending
        }
    }

    private static func localizedCountryName(_ code: String) -> String? {
        Locale.current.localizedString(forRegionCode: code)
            ?? Locale(identifier: "en_US").localizedString(forRegionCode: code)
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collapsed(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
