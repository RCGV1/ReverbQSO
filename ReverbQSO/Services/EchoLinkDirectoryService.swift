// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import os

enum DirectoryPublicProxyRetryPolicy {
    static func shouldRetry(
        configuration: EchoLinkProxyConfiguration,
        error: Error,
        rejectedCandidateCount: Int
    ) -> Bool {
        guard configuration.mode == .publicProxy,
              rejectedCandidateCount < EchoLinkPublicProxyListClient.defaultCandidateLimit,
              let proxyError = error as? EchoLinkProxyClient.ClientError else {
            return false
        }
        return proxyError.isCandidateRejection
    }
}

/// Service that manages the EchoLink directory: login, station list retrieval,
/// filtering, and periodic refresh.
@MainActor
final class EchoLinkDirectoryService: ObservableObject {

    // MARK: - Published State

    @Published var stations: [Station] = []
    @Published var filteredStations: [Station] = []
    @Published var searchText: String = "" {
        didSet { applyFilter() }
    }
    @Published var isLoading = false
    @Published var isLoggedIn = false
    @Published private(set) var registeredThroughProxy = false
    @Published private(set) var isAvailableForCalls = false
    @Published private(set) var lastSuccessfulSnapshotAt: Date?
    @Published var error: Error?

    // MARK: - Filter

    @Published var typeFilter: Station.StationType? = nil {
        didSet { applyFilter() }
    }

    // MARK: - Private State

    @Published private(set) var effectiveTransport: EchoLinkEffectiveTransport?
    private let transportSelector: EchoLinkAutomaticTransportSelector
    private let configurationProvider: @MainActor () -> EchoLinkProxyConfiguration

    private let saveCredentials: @MainActor (String, String, Bool) -> Bool
    private let client: DirectoryClient
    private let proxySessionStore: EchoLinkProxySessionStore
    private let fetchStationsForRefresh: (@MainActor () async throws -> [Station])?
    private let localDemoAccount: String?
    private let logger = Logger(subsystem: "org.reverbqso.app", category: "DirectoryService")
    private var keepAliveTask: Task<Void, Never>?
    private var availabilityTask: Task<Bool, Never>?
    private var proxyRecoveryTask: Task<Void, Error>?
    private var proxyRecoveryID: UUID?
    private var authenticatedCallsign = ""
    private var foregroundRefreshTask: Task<Void, Never>?
    private var lifecycleGeneration = DirectoryLifecycleGeneration()
    private var refreshGeneration = DirectoryLifecycleGeneration()
    private var keepAliveFailures = DirectoryKeepAliveFailureTracker()
    private var pendingCQSocketPair: DirectCQSocketPair?
    private var pendingCQSocketExpiryTask: Task<Void, Never>?

    init(
        fetchStationsForRefresh: (@MainActor () async throws -> [Station])? = nil,
        localDemoAccount: String? = nil,
        proxySessionStore: EchoLinkProxySessionStore = EchoLinkProxySessionStore(),
        transportSelector: EchoLinkAutomaticTransportSelector = EchoLinkAutomaticTransportSelector(),
        configurationProvider: @escaping @MainActor () -> EchoLinkProxyConfiguration = { EchoLinkProxyConfiguration.load() },
        client: DirectoryClient = DirectoryClient(),
        saveCredentials: @escaping @MainActor (String, String, Bool) -> Bool = {
            KeychainService.save(callsign: $0, password: $1, makeActive: $2)
        }
    ) {
        self.transportSelector = transportSelector
        self.configurationProvider = configurationProvider
        self.client = client
        self.saveCredentials = saveCredentials
        self.localDemoAccount = localDemoAccount.flatMap {
            LocalDemoAccount.isDemoUsername($0) ? LocalDemoAccount.normalizedUsername($0) : nil
        }
        if self.localDemoAccount == nil {
            self.fetchStationsForRefresh = fetchStationsForRefresh
        } else {
            self.fetchStationsForRefresh = { @MainActor in LocalDemoAccount.stations }
        }
        self.proxySessionStore = proxySessionStore
        if self.localDemoAccount != nil {
            isLoggedIn = true
            stations = LocalDemoAccount.stations
            lastSuccessfulSnapshotAt = .now
            effectiveTransport = LocalDemoAccount.transport
            applyFilter()
        }
    }

    // MARK: - Public API

    func advertiseRelay(address: String) async throws {
        guard isLoggedIn else { throw DirectoryClientError.notConnected }
        if localDemoAccount != nil { return }
        if effectiveTransport?.preference.mode == .automatic {
            guard effectiveTransport?.relayAddress == address else {
                throw DirectoryClientError.unexpectedResponse("Relay does not match this login's selected transport")
            }
            return
        }
        try await client.advertiseRelay(address: address)
    }

    func stopAdvertisingRelay(address: String) async {
        if localDemoAccount != nil { return }
        // Automatic selection remains registered for the entire login session.
        guard effectiveTransport?.preference.mode != .automatic else { return }
        await client.stopAdvertisingRelay(address: address)
    }

    /// Re-register immediately so the public directory reflects whether the
    /// app currently has an inbound listener and capacity for a call.
    @discardableResult
    func setAvailableForCalls(_ available: Bool) async -> Bool {
        guard isLoggedIn else { return false }
        let generation = lifecycleGeneration.current
        let predecessor = availabilityTask
        let task = Task { [weak self] in
            _ = await predecessor?.value
            guard let self, self.lifecycleGeneration.matches(generation), self.isLoggedIn else {
                return false
            }
            guard self.isAvailableForCalls != available else { return true }
            do {
                if self.fetchStationsForRefresh == nil {
                    try await self.withProxyRecovery {
                        try await self.client.setAvailableForCalls(available)
                    }
                }
                guard self.lifecycleGeneration.matches(generation), self.isLoggedIn else { return false }
                self.isAvailableForCalls = available
                self.error = nil
                return true
            } catch {
                guard self.lifecycleGeneration.matches(generation) else { return false }
                self.error = error
                return false
            }
        }
        availabilityTask = task
        return await task.value
    }

    /// Log in to the EchoLink directory server using stored or provided credentials.
    func login(callsign: String? = nil, password: String? = nil, persistAsActive: Bool = true, retainingTransport: EchoLinkEffectiveTransport? = nil) async {
        if let localDemoAccount {
            guard LocalDemoAccount.normalizedUsername(callsign ?? localDemoAccount) == localDemoAccount,
                  password == LocalDemoAccount.password else {
                error = DirectoryClientError.connectionFailed("Incorrect callsign or password.")
                return
            }
            isLoggedIn = true
            effectiveTransport = LocalDemoAccount.transport
            _ = await refresh()
            return
        }
        // Reserved on-device identities must never reach a real directory,
        // even if a future caller skips the app's authentication coordinator.
        if let callsign, LocalDemoAccount.isDemoUsername(callsign) {
            error = DirectoryClientError.connectionFailed("Incorrect callsign or password.")
            return
        }
        let generation = beginLifecycleOperation()
        let cs = callsign ?? KeychainService.loadCallsign() ?? ""
        let pw = password ?? KeychainService.loadPassword() ?? ""
        guard !LocalDemoAccount.isDemoUsername(cs) else {
            error = DirectoryClientError.connectionFailed("Incorrect callsign or password.")
            return
        }
        logger.debug("Login requested callsign=\(cs, privacy: .public) hasPassword=\(!pw.isEmpty)")

        clearPublishedLoginState()
        isLoading = true
        error = nil
        defer {
            if lifecycleGeneration.matches(generation) {
                isLoading = false
            }
        }

        await client.logout()
        guard lifecycleGeneration.matches(generation) else { return }

        guard !cs.isEmpty, !pw.isEmpty else {
            error = DirectoryClientError.connectionFailed("Callsign and password are required.")
            return
        }

        do {
            let selection: EchoLinkEffectiveTransport
            if let retainingTransport { selection = retainingTransport }
            else { selection = try await transportSelector.select(configurationProvider()) }
            try Task.checkCancellation()
            guard lifecycleGeneration.matches(generation) else { return }
            effectiveTransport = selection
            var excludedProxyCandidates: [EchoLinkProxyConfiguration] = []
            var initialStations: [Station] = []
            var registeredWithProxy = false
            while true {
                let proxySession = try await proxySessionStore.session(
                    callsign: cs,
                    configuration: selection.configuration,
                    excluding: excludedProxyCandidates
                )
                try Task.checkCancellation()
                guard lifecycleGeneration.matches(generation) else { return }
                await client.setProxySession(proxySession)
                do {
                    try await client.login(callsign: cs, password: pw, relayAddress: selection.relayAddress)
                    guard lifecycleGeneration.matches(generation) else { return }
                    initialStations = try await client.fetchStations()
                    try Task.checkCancellation()
                    guard lifecycleGeneration.matches(generation) else { return }
                    registeredWithProxy = proxySession != nil
                    break
                } catch {
                    guard let proxySession else { throw error }
                    let rejectedConfiguration = proxySession.configuration
                    let rejectedCount = excludedProxyCandidates.count + 1
                    guard DirectoryPublicProxyRetryPolicy.shouldRetry(
                        configuration: selection.configuration,
                        error: error,
                        rejectedCandidateCount: rejectedCount
                    ) else {
                        throw error
                    }
                    excludedProxyCandidates.append(rejectedConfiguration)
                    await client.setProxySession(nil)
                    logger.warning(
                        "Public proxy rejected first directory command; retrying another candidate"
                    )
                }
            }

            authenticatedCallsign = cs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            stations = initialStations
            lastSuccessfulSnapshotAt = .now
            applyFilter()
            if !saveCredentials(cs, pw, persistAsActive) {
                logger.warning("Directory login succeeded but credential storage failed")
            }
            isLoggedIn = true
            registeredThroughProxy = registeredWithProxy
            keepAliveFailures.recordSuccess()
            startKeepAlive(for: generation)
            logger.debug("Login and initial refresh succeeded stationCount=\(initialStations.count)")
        } catch {
            guard lifecycleGeneration.matches(generation) else { return }
            logger.error("Login failed error='\(error.localizedDescription, privacy: .public)'")
            await client.logout()
            guard lifecycleGeneration.matches(generation) else { return }
            clearPublishedLoginState()
            self.error = error
        }
    }

    /// Refresh the station list from the directory server.
    @discardableResult
    func refresh() async -> Bool {
        guard isLoggedIn else { return false }
        let lifecycle = lifecycleGeneration.current
        let refresh = refreshGeneration.advance()
        logger.debug("Refresh requested")

        isLoading = true
        error = nil
        defer {
            if lifecycleGeneration.matches(lifecycle), refreshGeneration.matches(refresh) {
                isLoading = false
            }
        }

        do {
            let refreshedStations: [Station]
            if let fetchStationsForRefresh {
                refreshedStations = try await fetchStationsForRefresh()
            } else {
                refreshedStations = try await withProxyRecovery { try await self.client.fetchStations() }
            }
            guard !Task.isCancelled,
                  lifecycleGeneration.matches(lifecycle), refreshGeneration.matches(refresh) else { return false }

            stations = refreshedStations
            lastSuccessfulSnapshotAt = .now
            logger.debug("Refresh fetched stationCount=\(refreshedStations.count)")
            applyFilter()
            return true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  lifecycleGeneration.matches(lifecycle), refreshGeneration.matches(refresh) else { return false }
            logger.error("Refresh failed error='\(error.localizedDescription, privacy: .public)'")
            if DirectoryRegistrationFailurePolicy.shouldRetireImmediately(error) {
                await retireDirectorySession(with: error)
                return false
            }
            self.error = error
            return false
        }
    }

    /// Search the station list by callsign or description.
    func search(query: String) {
        searchText = query
    }

    /// Disconnect from the directory server.
    func logout() async {
        let generation = beginLifecycleOperation()
        stopForegroundRefreshing()
        clearPublishedLoginState()
        isLoading = false
        error = nil

        if localDemoAccount == nil { await client.logout() }
        guard lifecycleGeneration.matches(generation) else { return }
        clearPublishedLoginState()
    }

    /// Refresh the directory at a bounded cadence while the app is active.
    /// Each iteration awaits the previous fetch, so refreshes never overlap.
    func startForegroundRefreshing(interval: Duration = .seconds(60)) {
        guard foregroundRefreshTask == nil, isLoggedIn else { return }
        let generation = lifecycleGeneration.current
        foregroundRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.lifecycleGeneration.matches(generation), self.isLoggedIn {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                _ = await self.refresh()
            }
            if self.lifecycleGeneration.matches(generation) {
                self.foregroundRefreshTask = nil
            }
        }
    }

    func stopForegroundRefreshing() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
    }

    /// Returns the directory's authenticated proxy tunnel for QSO traffic.
    /// Re-authenticate an unusable tunnel using this login's frozen transport,
    /// so directory TCP and QSO UDP keep the same route for this callsign.
    func prepareProxySession(callsign: String) async throws -> EchoLinkProxySession? {
        if localDemoAccount != nil { return nil }
        guard let selection = effectiveTransport, selection.configuration.isEnabled else { return nil }
        if let current = await proxySessionStore.currentSession(callsign: callsign, configuration: selection.configuration) { return current }

        guard let password = KeychainService.loadPassword(for: callsign), !password.isEmpty else {
            throw DirectoryClientError.connectionFailed("Callsign and password are required.")
        }
        await login(callsign: callsign, password: password, persistAsActive: false, retainingTransport: selection)
        guard isLoggedIn, let current = await proxySessionStore.currentSession(callsign: callsign, configuration: selection.configuration) else {
            throw error ?? DirectoryClientError.connectionFailed("Proxy directory login did not complete.")
        }
        return current
    }

    /// Creates a CQ matcher without exposing the stored account password to UI code.
    func makeLiveCallCQBackend(
        callsign: String,
        preferences: CallCQPreferences,
        recentCallsigns: [String],
        policy: CallAccessPolicy
    ) throws -> LiveCallCQBackend {
        guard isLoggedIn, let transport = effectiveTransport,
              let password = KeychainService.loadPassword(for: callsign), !password.isEmpty else {
            throw CallCQBackendError.authenticatedTransportUnavailable
        }
        let registration = try CallCQRegistration.make(
            callsign: callsign,
            preferences: preferences,
            policy: policy,
            recentCallsigns: recentCallsigns,
            transport: transport
        )
        return LiveCallCQBackend(
            registration: registration,
            password: password,
            directory: self,
            policy: policy,
            usesDirectSockets: transport.configuration.mode == .direct
        )
    }

    func reserveDirectCQSocketPair() throws -> DirectCQSocketPair {
        clearPendingCQSocketPair()
        return try DirectCQSocketPair()
    }

    func holdMatchedCQSocketPair(_ pair: DirectCQSocketPair) {
        clearPendingCQSocketPair()
        pendingCQSocketPair = pair
        pendingCQSocketExpiryTask = Task { [weak self, weak pair] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let pair,
                  self.pendingCQSocketPair === pair else { return }
            self.clearPendingCQSocketPair()
        }
    }

    func consumePendingCQSocketPair() -> DirectCQSocketPair? {
        pendingCQSocketExpiryTask?.cancel()
        pendingCQSocketExpiryTask = nil
        defer { pendingCQSocketPair = nil }
        return pendingCQSocketPair
    }

    func clearPendingCQSocketPair() {
        pendingCQSocketExpiryTask?.cancel()
        pendingCQSocketExpiryTask = nil
        pendingCQSocketPair?.close()
        pendingCQSocketPair = nil
    }

    func closeProxySession() async {
        await proxySessionStore.close()
    }

    // MARK: - Private

    private func withProxyRecovery<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        let generation = lifecycleGeneration.current
        do { return try await operation() }
        catch {
            try Task.checkCancellation()
            guard lifecycleGeneration.matches(generation), isLoggedIn,
                  effectiveTransport?.configuration.isEnabled == true,
                  Self.isRecoverableProxyFailure(error) else { throw error }
            try await recoverProxy(for: generation)
            try Task.checkCancellation()
            guard lifecycleGeneration.matches(generation), isLoggedIn else { throw CancellationError() }
            return try await operation()
        }
    }

    private static func isRecoverableProxyFailure(_ error: Error) -> Bool {
        if let error = error as? EchoLinkProxySession.SessionError {
            switch error {
            case .directoryClosed, .directoryOpenFailed, .timedOut: return true
            case .directoryBusy: return false
            }
        }
        if let error = error as? EchoLinkProxyClient.ClientError {
            switch error {
            case .connectionClosed, .connectionFailed, .authenticationTimedOut, .allCandidatesFailed: return true
            default: return false
            }
        }
        return false
    }

    private func recoverProxy(for generation: UInt64) async throws {
        if let proxyRecoveryTask { return try await proxyRecoveryTask.value }
        guard let selection = effectiveTransport, !authenticatedCallsign.isEmpty,
              let failed = await client.activeProxySession() else { throw CancellationError() }
        // Another caller may already have repaired the tunnel before this
        // queued failure reached us. Keep that fresh connection.
        if await failed.isUsable() { return }
        // Both actor lookups above can suspend. Share any recovery another
        // refresh started in the meantime instead of replacing its tunnel.
        if let proxyRecoveryTask { return try await proxyRecoveryTask.value }
        guard lifecycleGeneration.matches(generation), isLoggedIn else { throw CancellationError() }
        let callsign = authenticatedCallsign
        let recoveryID = UUID()
        let task = Task { [weak self] in
            guard let self, self.lifecycleGeneration.matches(generation) else { throw CancellationError() }
            let exclusions = selection.configuration.mode == .publicProxy ? [failed.configuration] : []
            guard let replacement = try await self.proxySessionStore.session(
                callsign: callsign, configuration: selection.configuration, excluding: exclusions
            ) else { throw EchoLinkProxySession.SessionError.directoryClosed }
            try Task.checkCancellation()
            guard self.lifecycleGeneration.matches(generation) else { throw CancellationError() }
            try await self.client.recoverProxySession(replacement, replacing: failed)
            guard self.lifecycleGeneration.matches(generation) else { throw CancellationError() }
            self.logger.info("Reconnected proxy after a failed directory request")
        }
        proxyRecoveryTask = task
        proxyRecoveryID = recoveryID
        defer {
            if proxyRecoveryID == recoveryID {
                proxyRecoveryTask = nil
                proxyRecoveryID = nil
            }
        }
        try await task.value
    }

    @discardableResult
    private func beginLifecycleOperation() -> UInt64 {
        let generation = lifecycleGeneration.advance()
        proxyRecoveryTask?.cancel()
        proxyRecoveryTask = nil
        proxyRecoveryID = nil
        _ = refreshGeneration.advance()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        availabilityTask?.cancel()
        availabilityTask = nil
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        keepAliveFailures.recordSuccess()
        return generation
    }

    private func retireDirectorySession(with terminalError: Error) async {
        let terminalGeneration = lifecycleGeneration.advance()
        proxyRecoveryTask?.cancel()
        proxyRecoveryTask = nil
        proxyRecoveryID = nil
        _ = refreshGeneration.advance()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        keepAliveFailures.recordSuccess()
        isLoading = false
        clearPublishedLoginState()

        await client.logout()
        guard lifecycleGeneration.matches(terminalGeneration) else { return }
        error = terminalError
    }

    private func clearPublishedLoginState() {
        authenticatedCallsign = ""
        clearPendingCQSocketPair()
        effectiveTransport = nil
        isLoggedIn = false
        isAvailableForCalls = false
        registeredThroughProxy = false
        lastSuccessfulSnapshotAt = nil
        stations = []
        filteredStations = []
    }

    private func applyFilter() {
        var result = stations

        let normalizedQuery = normalizeSearch(searchText)
        let collapsedQuery = collapseForSearch(searchText)
        if !normalizedQuery.isEmpty {
            let tokens = normalizedQuery
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)

            result = result.filter { station in
                let haystack = searchableText(for: station)
                let collapsedHaystack = collapsedSearchableText(for: station)
                let tokenMatch = tokens.allSatisfy(haystack.contains)
                let collapsedMatch = !collapsedQuery.isEmpty && collapsedHaystack.contains(collapsedQuery)
                return tokenMatch || collapsedMatch
            }
        }

        if let type = typeFilter {
            result = result.filter { $0.type == type }
        }

        filteredStations = result
        logger.debug(
            "Filter applied search='\(self.searchText, privacy: .public)' typeFilter='\(self.typeFilter?.displayName ?? "All", privacy: .public)' sourceCount=\(self.stations.count) resultCount=\(self.filteredStations.count)"
        )
    }

    private func searchableText(for station: Station) -> String {
        let callsign = station.callsign
        let compactCallsign = callsign
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "-R", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "-L", with: "", options: [.caseInsensitive])
        let pieces: [String] = [
            callsign,
            compactCallsign,
            station.description,
            station.type.displayName,
            station.type == .user ? "user individual" : "",
            String(station.nodeNumber)
        ]
        return normalizeSearch(pieces.joined(separator: " "))
    }

    private func collapsedSearchableText(for station: Station) -> String {
        let pieces: [String] = [
            station.callsign,
            station.description,
            station.type.displayName,
            station.type == .user ? "user individual" : "",
            String(station.nodeNumber)
        ]
        return collapseForSearch(pieces.joined(separator: ""))
    }

    private func normalizeSearch(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collapseForSearch(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func startKeepAlive(for generation: UInt64) {
        keepAliveTask?.cancel()
        // EchoLink directory requires re-registration every 5 minutes (REGISTRATION_REFRESH_TIME)
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5 * 60))
                } catch {
                    break
                }
                guard let self, self.lifecycleGeneration.matches(generation) else { break }
                guard await self.performKeepAlive(for: generation) else { break }
            }
        }
    }

    private func performKeepAlive(for generation: UInt64) async -> Bool {
        guard lifecycleGeneration.matches(generation), isLoggedIn else { return false }

        do {
            try await withProxyRecovery { try await self.client.sendKeepAlive() }
            guard lifecycleGeneration.matches(generation) else { return false }

            keepAliveFailures.recordSuccess()
            error = nil
            return true
        } catch {
            guard lifecycleGeneration.matches(generation) else { return false }

            let retireImmediately = DirectoryRegistrationFailurePolicy.shouldRetireImmediately(error)
            let terminal = retireImmediately || keepAliveFailures.recordFailure()
            self.error = error
            logger.warning(
                "Directory keepalive failed consecutiveFailures=\(self.keepAliveFailures.consecutiveFailures) error='\(error.localizedDescription, privacy: .public)'"
            )
            guard terminal else { return true }

            await retireDirectorySession(with: error)
            return false
        }
    }
}
