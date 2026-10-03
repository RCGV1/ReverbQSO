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

    enum BrowseGroup: String, CaseIterable, Identifiable {
        case nodes = "Nodes"
        case people = "People"

        var id: Self { self }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case callsign = "Callsign"
        case nodeNumber = "Node number"

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
        didSet { rebuildAvailableCountries(); applyLocalFilter() }
    }
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
        !countryFilter.isEmpty || (browseGroup == .nodes && typeFilter != nil)
    }

    var countryFilterTitle: String {
        countryFilter.isEmpty ? "All countries" :
            (availableCountries.first { $0.code == countryFilter }?.name ?? countryFilter)
    }

    var filterSummary: String {
        let group: String
        if browseGroup == .people {
            group = "People"
        } else {
            switch typeFilter {
            case .link: group = "Links"
            case .repeater: group = "Repeaters"
            case .conference: group = "Conferences"
            default: group = "All nodes"
            }
        }
        return "\(group) · \(countryFilterTitle)"
    }

    func clearFilters() {
        if browseGroup == .nodes { typeFilter = nil }
        countryFilter = ""
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

        let filtered = indexedStations.compactMap { indexed -> Station? in
            let station = indexed.station
            switch browseGroup {
            case .nodes:
                guard station.type != .user else { return nil }
                if let typeFilter, station.type != typeFilter { return nil }
            case .people:
                guard station.type == .user else { return nil }
            }
            if !selectedCountry.isEmpty, indexed.countryCode != selectedCountry {
                return nil
            }
            guard !query.isEmpty else {
                return station
            }

            let tokens = query.split(whereSeparator: \.isWhitespace)
            let tokenMatch = tokens.allSatisfy { indexed.searchBlob.contains(String($0)) }
            let compactMatch = !collapsedQuery.isEmpty && indexed.compactBlob.contains(collapsedQuery)

            return (tokenMatch || compactMatch) ? station : nil
        }

        switch sortOrder {
        case .callsign:
            stations = filtered.sorted {
                let result = $0.callsign.localizedStandardCompare($1.callsign)
                if result != .orderedSame { return result == .orderedAscending }
                if $0.nodeNumber != $1.nodeNumber { return $0.nodeNumber < $1.nodeNumber }
                return $0.id.uuidString < $1.id.uuidString
            }
        case .nodeNumber:
            stations = filtered.sorted {
                if $0.nodeNumber != $1.nodeNumber { return $0.nodeNumber < $1.nodeNumber }
                let result = $0.callsign.localizedStandardCompare($1.callsign)
                return result == .orderedSame
                    ? $0.id.uuidString < $1.id.uuidString
                    : result == .orderedAscending
            }
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
                station.type.displayName,
                station.type == .user ? "user individual" : "",
                String(station.nodeNumber)
            ].joined(separator: " ")

            return IndexedStation(
                station: station,
                countryCode: countryCode,
                countryName: countryName,
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
