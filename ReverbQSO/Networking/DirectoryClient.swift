// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Network
import os

// MARK: - Errors

enum DirectoryClientError: LocalizedError {
    case connectionFailed(String)
    case loginDenied
    case loginInUse
    case accountNotValidated
    case accountNotFound
    case callsignBarred
    case timeout
    case unexpectedResponse(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let r): return "Connection failed: \(r)"
        case .loginDenied:            return "Login denied. Check your callsign and password."
        case .loginInUse:             return "Callsign already in use on another EchoLink session."
        case .accountNotValidated:    return "This EchoLink callsign has not been validated yet."
        case .accountNotFound:        return "This callsign was not found in the EchoLink directory."
        case .callsignBarred:         return "This callsign is barred from the EchoLink directory."
        case .timeout:                return "Connection timed out."
        case .unexpectedResponse(let m): return "Unexpected server response: \(m)"
        case .notConnected:           return "Not connected to directory server."
        }
    }
}

enum DirectoryEnhancedLoginResponseValidator {
    static func fields(from response: String) throws -> [String: String] {
        let lines = response.split(whereSeparator: \.isNewline)
        guard lines.first?.trimmingCharacters(in: .whitespaces).uppercased() == "LOGIN-RESULT" else {
            throw DirectoryClientError.unexpectedResponse(String(response.prefix(200)))
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return fields
    }

    static func validateFinal(_ response: String) throws {
        if DirectoryLoginResponseValidator.isSuccessResponse(response) { return }
        let fields = try fields(from: response)
        if fields["result"]?.lowercased() == "success" { return }
        let reason = fields["reason"] ?? "EchoLink rejected directory registration"
        let normalized = reason.lowercased().filter(\.isLetter)
        if normalized.contains("badpassword") || normalized.contains("incorrectpassword") {
            throw DirectoryClientError.loginDenied
        }
        if normalized.contains("notvalidated") {
            throw DirectoryClientError.accountNotValidated
        }
        if normalized.contains("notfound") {
            throw DirectoryClientError.accountNotFound
        }
        if normalized.contains("barred") {
            throw DirectoryClientError.callsignBarred
        }
        if normalized.contains("inuse") {
            throw DirectoryClientError.loginInUse
        }
        throw DirectoryClientError.unexpectedResponse(reason)
    }
}

enum DirectoryLoginResponseValidator {
    static func isSuccessResponse(_ response: String) -> Bool {
        let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercase = normalized.uppercased()
        guard uppercase.hasPrefix("OK") else { return false }

        let version = uppercase.dropFirst(2)
        return version.isEmpty
            || (version.first?.isNumber == true
                && version.allSatisfy { $0.isNumber || $0 == "." })
    }

    static func validate(_ response: String) throws {
        let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercase = normalized.uppercased()

        guard !normalized.isEmpty else {
            throw DirectoryClientError.unexpectedResponse("Empty login response")
        }

        if isSuccessResponse(normalized) {
            return
        }
        if uppercase.contains("IN-USE") || uppercase.contains("IN USE") {
            throw DirectoryClientError.loginInUse
        }
        if uppercase.contains("INCORRECT") || uppercase.contains("DENIED") {
            throw DirectoryClientError.loginDenied
        }

        throw DirectoryClientError.unexpectedResponse(String(normalized.prefix(200)))
    }
}

enum DirectoryRegistrationFailurePolicy {
    /// Losing server presence is different from losing the saved account.
    /// Transport failures and another active client can recover without asking
    /// the user to enter the same password again.
    static func requiresUserSignIn(_ error: Error?) -> Bool {
        guard let error = error as? DirectoryClientError else { return false }
        switch error {
        case .loginDenied, .accountNotValidated, .accountNotFound, .callsignBarred: return true
        case .loginInUse, .connectionFailed, .timeout, .unexpectedResponse, .notConnected: return false
        }
    }

    static func shouldRetireImmediately(_ error: Error) -> Bool {
        guard let directoryError = error as? DirectoryClientError else { return false }

        switch directoryError {
        case .loginDenied, .loginInUse, .accountNotValidated, .accountNotFound,
             .callsignBarred, .unexpectedResponse, .notConnected:
            return true
        case .connectionFailed, .timeout:
            return false
        }
    }
}

enum DirectoryEnhancedLoginPayloadBuilder {
    static func build(
        callsign: String,
        status: String,
        clientAddress: String?,
        location: String,
        timeHHMM: String,
        passwordHash: String?
    ) -> Data {
        var lines = [
            "-LOGIN",
            "callsign: \(callsign)",
            "status: \(status)"
        ]
        if let clientAddress { lines.append("client-addr: \(clientAddress)") }
        lines.append(contentsOf: [
            "rtp-port: 0",
            "rtcp-port: 0",
            "client-version: 1.0",
            "location: \(location)",
            "local-time: \(timeHHMM)",
            "code-page: none",
            "sw-tag: ReverbQSO"
        ])
        if let passwordHash { lines.append("hashed-password: \(passwordHash)") }
        return Data((lines.joined(separator: "\n") + "\n\n").utf8)
    }
}

struct DirectoryLifecycleGeneration {
    private(set) var current: UInt64 = 0

    mutating func advance() -> UInt64 {
        current &+= 1
        return current
    }

    func matches(_ generation: UInt64) -> Bool {
        current == generation
    }
}

struct DirectoryKeepAliveFailureTracker {
    static let defaultLimit = 3

    let limit: Int
    private(set) var consecutiveFailures = 0

    init(limit: Int = DirectoryKeepAliveFailureTracker.defaultLimit) {
        precondition(limit > 0)
        self.limit = limit
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        return consecutiveFailures >= limit
    }
}

private final class DirectoryContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isCompleted = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    @discardableResult
    func resume(returning value: Value) -> Bool {
        complete(.success(value))
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        complete(.failure(error))
    }

    private func complete(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return false
        }
        isCompleted = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return true
        }
        if pendingResult == nil {
            pendingResult = result
            lock.unlock()
            return true
        }
        lock.unlock()
        return false
    }
}

// MARK: - DirectoryClient

/// Actor-isolated client for the EchoLink directory server (TCP 5200).
///
/// Directory registration uses the challenge-based mobile protocol. The
/// password itself is never included in a directory request.
///
///   LOGIN
///   ─────
///   Client → Server: -LOGIN fields terminated by a blank line.
///   Server → Client: LOGIN-RESULT with a challenge.
///   Client → Server: the same fields plus uppercase hexadecimal
///                    MD5(uppercase(password) + challenge).
///
///   GET STATION LIST
///   ─────────────────
///   Client → Server:  "s"
///
///   Server → Client:
///     "@@@\n"
///     "<count>\n"
///     For each station (repeated <count> times):
///       "<callsign>\n"
///       "<description>\n"
///       "<nodeID>\n"
///       "<ip>\n"
///     "+++"
///
///   RE-REGISTRATION (keep-alive)
///   ─────────────────────────────
///   Re-send the login command every 5 minutes to stay in the directory.
actor DirectoryClient {

    static let defaultHost = "iphone1.echolink.org"
    static let defaultPort: UInt16 = 5200
    static let echoLinkAudioPort: UInt16 = 5198

    private static let chunkSize = 131_072
    private static let readinessTimeout: TimeInterval = 10
    private static let sendTimeout: TimeInterval = 10

    private var connection: NWConnection?
    private var proxySession: EchoLinkProxySession?
    private var lifecycleGeneration = DirectoryLifecycleGeneration()
    private var lastHost: String = DirectoryClient.defaultHost
    private var lastPort: UInt16 = DirectoryClient.defaultPort
    private var loggedInCallsign: String = ""
    private var loggedInPassword: String = ""
    private var loggedInDescription: String = ""
    private var isAvailableForCalls = false
    private var relayExternalAddress: String?
    private let relayDirectoryHosts: [String]
    private let relayDirectoryPort: UInt16
    private let loginHosts: [String]
    var isLoggedIn = false
    private let logger = Logger(subsystem: "org.reverbqso.app", category: "DirectoryClient")

    // MARK: - Public API

    init(host: String = DirectoryClient.defaultHost, port: UInt16 = DirectoryClient.defaultPort,
         relayDirectoryHosts: [String] = ["iphone1.echolink.org", "iphone2.echolink.org"],
         relayDirectoryPort: UInt16 = DirectoryClient.defaultPort) {
        self.lastHost = host
        self.lastPort = port
        self.relayDirectoryHosts = relayDirectoryHosts
        self.relayDirectoryPort = relayDirectoryPort
        if host == DirectoryClient.defaultHost {
            self.loginHosts = ([host] + relayDirectoryHosts).reduce(into: []) { result, candidate in
                if !result.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                    result.append(candidate)
                }
            }
        } else {
            self.loginHosts = [host]
        }
    }

    func setProxySession(_ session: EchoLinkProxySession?) {
        proxySession = session
    }

    func activeProxySession() -> EchoLinkProxySession? { proxySession }

    /// Move the remembered registration to a proxy without reading credentials
    /// again or advertising the previously selected relay's source address.
    func switchToPublicProxy(_ replacement: EchoLinkProxySession, callsign: String) async throws {
        guard isLoggedIn, loggedInCallsign == callsign.uppercased() else {
            throw DirectoryClientError.notConnected
        }
        let previousProxy = proxySession
        let previousRelay = relayExternalAddress
        let generation = beginLifecycleOperation(clearCredentials: false)
        proxySession = replacement
        relayExternalAddress = nil
        do {
            try await registerWithFallback(generation: generation, markLoggedIn: true)
            try ensureCurrent(generation)
        } catch is CancellationError {
            if lifecycleGeneration.matches(generation), proxySession === replacement {
                proxySession = previousProxy
                relayExternalAddress = previousRelay
                isLoggedIn = true
                // The remote directory may have accepted the proxy registration
                // immediately before cancellation became visible. Restore the
                // original advertised route from a fresh, non-cancelled task.
                let compensation = Task {
                    if let previousRelay {
                        try await self.registerThroughRelay(address: previousRelay, generation: generation)
                    } else {
                        try await self.registerWithFallback(generation: generation, markLoggedIn: true)
                    }
                    try self.ensureCurrent(generation)
                }
                do {
                    try await compensation.value
                } catch {
                    if lifecycleGeneration.matches(generation), proxySession === previousProxy,
                       relayExternalAddress == previousRelay {
                        clearLocalRegistration()
                    }
                }
            }
            throw CancellationError()
        } catch {
            if lifecycleGeneration.matches(generation), proxySession === replacement {
                proxySession = previousProxy
                relayExternalAddress = previousRelay
                isLoggedIn = true
            }
            throw error
        }
    }

    /// A reconnect reuses the credentials and availability already acknowledged
    /// for this directory login. An obsolete recovery cannot replace a new login.
    func recoverProxySession(_ replacement: EchoLinkProxySession, replacing failed: EchoLinkProxySession) async throws {
        guard proxySession === failed, isLoggedIn else { throw CancellationError() }
        let generation = lifecycleGeneration.current
        proxySession = replacement
        try await sendKeepAlive()
        try ensureCurrent(generation)
    }

    func login(
        callsign: String,
        password: String,
        description: String = "",
        host: String? = nil,
        port: UInt16? = nil,
        relayAddress: String? = nil
    ) async throws {
        let generation = beginLifecycleOperation()
        if let host { self.lastHost = host }
        if let port { self.lastPort = port }
        logger.debug("Login connect host=\(self.lastHost, privacy: .public) port=\(Int(self.lastPort)) callsign=\(callsign, privacy: .public)")

        loggedInCallsign    = callsign.uppercased().trimmingCharacters(in: .whitespaces)
        loggedInPassword    = password.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        loggedInDescription = String(description.prefix(27))
        relayExternalAddress = relayAddress

        isAvailableForCalls = false
        do {
            if let relayAddress {
                guard Self.isIPv4Address(relayAddress) else {
                    throw DirectoryClientError.unexpectedResponse("Invalid relay address")
                }
                try await registerThroughRelay(address: relayAddress, generation: generation)
                try ensureCurrent(generation)
                isLoggedIn = true
            } else {
                try await registerWithFallback(generation: generation, markLoggedIn: true)
            }
            try ensureCurrent(generation)
            logger.debug("Login completed successfully")
        } catch {
            if lifecycleGeneration.matches(generation) {
                clearLocalRegistration()
            }
            throw error
        }
    }

    /// Send "s" and parse the station list.
    func fetchStations() async throws -> [Station] {
        let generation = lifecycleGeneration.current
        guard isLoggedIn else {
            throw DirectoryClientError.notConnected
        }

        // Directory commands are request/response style; use a fresh socket for
        // each fetch to avoid stale/final-read streams.
        do {
            let stations = try await fetchStations(generation: generation)
            try ensureCurrent(generation)
            return stations
        } catch {
            try ensureCurrent(generation)
            if DirectoryRegistrationFailurePolicy.shouldRetireImmediately(error) {
                throw error
            }
            logger.debug("Directory fetch initial attempt failed; reconnecting and retrying once")
            let stations = try await fetchStations(generation: generation)
            try ensureCurrent(generation)
            return stations
        }
    }

    private func fetchStations(generation: UInt64) async throws -> [Station] {
        if let proxySession {
            try ensureCurrent(generation)
            let raw = try await proxySession.serializedDirectoryRequest(
                Data("s".utf8), host: lastHost, boundary: .marker(Data("+++".utf8))
            )
            try ensureCurrent(generation)
            return try parseStationList(raw: raw)
        }
        return try await withFreshConnection(generation: generation) { conn in
            try await send(Data("s".utf8), via: conn)
            try ensureCurrent(generation)
            let stations = try await parseStationList(from: conn)
            try ensureCurrent(generation)
            return stations
        }
    }

    private func parseStationList(from conn: NWConnection) async throws -> [Station] {
        logger.debug("Directory fetch sent command='s'")

        let raw = try await readUntilMarker("+++", from: conn)
        guard !raw.isEmpty else {
            throw DirectoryClientError.connectionFailed("Directory server returned no data")
        }
        return try parseStationList(raw: raw)
    }

    private func parseStationList(raw: Data) throws -> [Station] {
        guard !raw.isEmpty else {
            throw DirectoryClientError.connectionFailed("Directory server returned no data")
        }
        let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? ""
        let uppercase = text.uppercased()

        if uppercase.contains("INCORRECT PASSWORD") || uppercase.contains("DENIED") {
            logger.error("Directory fetch auth denied responseSnippet='\(String(text.prefix(200)), privacy: .public)'")
            throw DirectoryClientError.loginDenied
        }
        if uppercase.contains("IN-USE") {
            logger.error("Directory fetch login in-use responseSnippet='\(String(text.prefix(200)), privacy: .public)'")
            throw DirectoryClientError.loginInUse
        }

        let stations = StationParser.parseDirectory(raw: raw)
        logger.debug("Directory fetch rawBytes=\(raw.count) parsedStations=\(stations.count)")

        if stations.isEmpty && !StationParser.isValidEmptyCountedDirectory(raw: raw) {
            logger.error("Directory fetch parsed empty list; responseSnippet='\(String(text.prefix(300)), privacy: .public)'")
            throw DirectoryClientError.unexpectedResponse("Directory response could not be parsed")
        }

        return stations
    }

    /// Re-send the online registration to stay listed in the directory.
    func sendKeepAlive() async throws {
        let generation = lifecycleGeneration.current
        guard isLoggedIn else {
            throw DirectoryClientError.notConnected
        }

        if let relayExternalAddress {
            try await registerThroughRelay(address: relayExternalAddress, generation: generation)
        } else {
            try await sendEnhancedRegistration(generation: generation)
        }
        try ensureCurrent(generation)
    }

    func setAvailableForCalls(_ available: Bool) async throws {
        let generation = lifecycleGeneration.current
        guard isLoggedIn else { throw DirectoryClientError.notConnected }
        guard isAvailableForCalls != available else { return }
        let priorAvailability = isAvailableForCalls
        isAvailableForCalls = available
        do {
            if let relayExternalAddress {
                try await registerThroughRelay(address: relayExternalAddress, generation: generation)
            } else {
                try await sendEnhancedRegistration(generation: generation)
            }
            try ensureCurrent(generation)
        } catch {
            // Preserve the last acknowledged state so a retry sends a packet.
            isAvailableForCalls = priorAvailability
            throw error
        }
    }

    private var registrationStatus: String {
        isAvailableForCalls ? "ONLINE" : "BUSY"
    }

    /// Best-effort removal from the directory followed by local teardown.
    func logout() async {
        let callsign = loggedInCallsign
        let shouldSendLogoff = isLoggedIn && !callsign.isEmpty
        let generation = beginLifecycleOperation(clearCredentials: false)
        isLoggedIn = false

        if shouldSendLogoff {
            do {
                try await sendLogoff(callsign: callsign, generation: generation)
                try ensureCurrent(generation)
                logger.debug("Directory logoff completed successfully")
            } catch {
                if lifecycleGeneration.matches(generation) {
                    logger.warning("Directory logoff failed error='\(error.localizedDescription, privacy: .public)'")
                }
            }
        }

        guard lifecycleGeneration.matches(generation) else { return }
        clearLocalRegistration()
    }

    // MARK: - Registration

    /// Advertise the relay endpoint to peers before sending the first QSO packet.
    /// The legacy directory login cannot carry an alternate client address.
    func advertiseRelay(address: String) async throws {
        let generation = lifecycleGeneration.current
        guard isLoggedIn else { throw DirectoryClientError.notConnected }
        guard Self.isIPv4Address(address) else {
            throw DirectoryClientError.unexpectedResponse("Invalid relay address")
        }
        try await registerThroughRelay(address: address, generation: generation)
        try ensureCurrent(generation)
        relayExternalAddress = address
    }

    func stopAdvertisingRelay(address: String) async {
        guard relayExternalAddress == address else { return }
        relayExternalAddress = nil
        guard isLoggedIn else { return }
        let generation = lifecycleGeneration.current
        try? await sendEnhancedRegistration(generation: generation)
    }

    private func registerThroughRelay(address: String, generation: UInt64) async throws {
        var lastError: Error = DirectoryClientError.connectionFailed("EchoLink directory servers did not respond")
        for host in relayDirectoryHosts {
            do {
                try await sendEnhancedRegistration(
                    host: host,
                    port: relayDirectoryPort,
                    clientAddress: address,
                    generation: generation
                )
                try ensureCurrent(generation)
                lastHost = host
                logger.info("Directory advertised relay address=\(address, privacy: .public)")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if DirectoryRegistrationFailurePolicy.shouldRetireImmediately(error) { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private func registerWithFallback(generation: UInt64, markLoggedIn: Bool) async throws {
        let hosts = loginHosts.contains(where: { $0.caseInsensitiveCompare(lastHost) == .orderedSame })
            ? loginHosts : [lastHost]
        var lastError: Error = DirectoryClientError.connectionFailed("EchoLink directory servers did not respond")
        for host in hosts {
            do {
                try await sendEnhancedRegistration(
                    host: host,
                    port: lastPort,
                    generation: generation,
                    markLoggedIn: markLoggedIn
                )
                lastHost = host
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if DirectoryRegistrationFailurePolicy.shouldRetireImmediately(error) { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private func enhancedLoginPayload(clientAddress: String?, hash: String?) -> Data {
        let location = loggedInDescription.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return DirectoryEnhancedLoginPayloadBuilder.build(
            callsign: loggedInCallsign,
            status: registrationStatus,
            clientAddress: clientAddress,
            location: location,
            timeHHMM: currentTimeHHMM(),
            passwordHash: hash
        )
    }

    private func sendEnhancedRegistration(
        host: String? = nil,
        port: UInt16? = nil,
        clientAddress: String? = nil,
        generation: UInt64,
        markLoggedIn: Bool = false
    ) async throws {
        let targetHost = host ?? lastHost
        let targetPort = port ?? lastPort
        let initial = try await enhancedDirectoryRequest(
            host: targetHost,
            port: targetPort,
            payload: enhancedLoginPayload(clientAddress: clientAddress, hash: nil),
            generation: generation
        )
        try ensureCurrent(generation)

        if DirectoryLoginResponseValidator.isSuccessResponse(initial) {
            if markLoggedIn { isLoggedIn = true }
            return
        }

        let fields = try DirectoryEnhancedLoginResponseValidator.fields(from: initial)
        if fields["result"]?.lowercased() == "success" {
            if markLoggedIn { isLoggedIn = true }
            return
        }
        guard let challenge = fields["challenge"], !challenge.isEmpty else {
            try DirectoryEnhancedLoginResponseValidator.validateFinal(initial)
            throw DirectoryClientError.unexpectedResponse("EchoLink directory did not send an authentication challenge")
        }
        let input = Data((loggedInPassword.uppercased() + challenge).utf8)
        let hash = Insecure.MD5.hash(data: input).map { String(format: "%02X", $0) }.joined()
        let final = try await enhancedDirectoryRequest(
            host: targetHost,
            port: targetPort,
            payload: enhancedLoginPayload(clientAddress: clientAddress, hash: hash),
            generation: generation
        )
        try DirectoryEnhancedLoginResponseValidator.validateFinal(final)
        try ensureCurrent(generation)
        if markLoggedIn { isLoggedIn = true }
    }

    private func enhancedDirectoryRequest(
        host: String,
        port: UInt16,
        payload: Data,
        generation: UInt64
    ) async throws -> String {
        try ensureCurrent(generation)
        let response: String
        if let proxySession {
            let raw = try await proxySession.serializedDirectoryRequest(
                payload,
                host: host,
                boundary: .marker(Data("\n\n".utf8)),
                timeout: .seconds(5)
            )
            response = String(data: raw, encoding: .utf8) ?? ""
        } else {
            response = try await withFreshConnection(
                host: host,
                port: port,
                generation: generation
            ) { conn in
                try await send(payload, via: conn)
                try ensureCurrent(generation)
                return try await readEnhancedLoginResponse(from: conn, timeout: 5)
            }
        }
        try ensureCurrent(generation)
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DirectoryClientError.unexpectedResponse("Empty directory registration response")
        }
        return response
    }

    private func sendLogoff(callsign: String, generation: UInt64) async throws {
        let payload = Data("z\(callsign)\r".utf8)
        let response: String
        if let proxySession {
            let raw = try await proxySession.serializedDirectoryRequest(
                payload, host: lastHost, boundary: .line, timeout: .seconds(5)
            )
            response = String(data: raw, encoding: .utf8) ?? ""
        } else {
            response = try await withFreshConnection(generation: generation) { conn in
                try await send(payload, via: conn)
                return try await readLine(from: conn, timeout: 5)
            }
        }
        try DirectoryLoginResponseValidator.validate(response)
        try ensureCurrent(generation)
    }

    private static func isIPv4Address(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    private func beginLifecycleOperation(clearCredentials: Bool = true) -> UInt64 {
        let generation = lifecycleGeneration.advance()
        connection?.cancel()
        connection = nil
        isLoggedIn = false
        if clearCredentials {
            loggedInCallsign = ""
            loggedInPassword = ""
            loggedInDescription = ""
        }
        return generation
    }

    private func clearLocalRegistration() {
        connection?.cancel()
        connection = nil
        isLoggedIn = false
        loggedInCallsign = ""
        loggedInPassword = ""
        loggedInDescription = ""
        isAvailableForCalls = false
        relayExternalAddress = nil
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        guard lifecycleGeneration.matches(generation), !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func currentTimeHHMM() -> String {
        let c = Calendar.current
        let h = c.component(.hour,   from: Date())
        let m = c.component(.minute, from: Date())
        return String(format: "%02d:%02d", h, m)
    }

    private func withFreshConnection<T>(
        host: String? = nil,
        port: UInt16? = nil,
        generation: UInt64,
        _ operation: (NWConnection) async throws -> T
    ) async throws -> T {
        try ensureCurrent(generation)
        let conn = NWConnection(
            to: .hostPort(
                host: .init(host ?? lastHost),
                port: .init(rawValue: port ?? lastPort)!
            ),
            using: .tcp
        )
        connection = conn
        defer {
            conn.cancel()
            if self.connection === conn {
                self.connection = nil
            }
        }
        try await waitForReady(conn)
        try ensureCurrent(generation)
        return try await operation(conn)
    }

    // MARK: - TCP Helpers

    private func readEnhancedLoginResponse(
        from conn: NWConnection,
        timeout: TimeInterval
    ) async throws -> String {
        var bytes = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let chunk = try await receiveChunk(
                    from: conn,
                    timeout: max(0.01, deadline.timeIntervalSinceNow)
                )
                bytes.append(chunk)
                guard bytes.count <= 16_384 else {
                    throw DirectoryClientError.unexpectedResponse("Oversized directory registration response")
                }
            } catch is CancellationError {
                try Task.checkCancellation()
                if bytes.isEmpty { throw DirectoryClientError.connectionFailed("Directory server returned no data") }
                break
            }

            if bytes.range(of: Data("\n\n".utf8)) != nil
                || bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                break
            }
            if let candidate = String(data: bytes, encoding: .utf8),
               DirectoryLoginResponseValidator.isSuccessResponse(candidate) {
                break
            }
        }
        guard let response = String(data: bytes, encoding: .utf8), !response.isEmpty else {
            throw DirectoryClientError.timeout
        }
        return response
    }

    private func waitForReady(
        _ conn: NWConnection,
        timeout: TimeInterval = DirectoryClient.readinessTimeout
    ) async throws {
        let gate = DirectoryContinuationGate<Void>()

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)

                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if gate.resume(returning: ()) {
                            conn.stateUpdateHandler = nil
                        }
                    case .failed(let error):
                        if gate.resume(throwing: DirectoryClientError.connectionFailed(error.localizedDescription)) {
                            conn.stateUpdateHandler = nil
                        }
                    case .cancelled:
                        if gate.resume(throwing: CancellationError()) {
                            conn.stateUpdateHandler = nil
                        }
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))

                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                    if gate.resume(throwing: DirectoryClientError.timeout) {
                        conn.stateUpdateHandler = nil
                        conn.cancel()
                    }
                }
            }
        } onCancel: {
            if gate.resume(throwing: CancellationError()) {
                conn.stateUpdateHandler = nil
                conn.cancel()
            }
        }
    }

    private func send(_ data: Data, via conn: NWConnection) async throws {
        let gate = DirectoryContinuationGate<Void>()

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                conn.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        // EchoLink closes its short-lived command socket as soon as
                        // the response is queued. Network.framework can report that
                        // final close from the send completion even though the bytes
                        // were delivered and response data remains readable.
                        if Self.isFinalReadError(error) {
                            gate.resume(returning: ())
                        } else {
                            gate.resume(throwing: DirectoryClientError.connectionFailed(error.localizedDescription))
                        }
                    } else {
                        gate.resume(returning: ())
                    }
                })

                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + Self.sendTimeout
                ) {
                    if gate.resume(throwing: DirectoryClientError.timeout) {
                        conn.cancel()
                    }
                }
            }
        } onCancel: {
            if gate.resume(throwing: CancellationError()) {
                conn.cancel()
            }
        }
    }

    /// Read bytes until a newline and return as a String (strips trailing whitespace).
    private func readLine(from conn: NWConnection, timeout: TimeInterval = 30) async throws -> String {
        var buf = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw DirectoryClientError.timeout
            }

            let chunk: Data
            do {
                chunk = try await receiveChunk(from: conn, timeout: remaining)
            } catch is CancellationError {
                // Some directory servers close after a short response (e.g. "OK")
                // without a trailing newline. If we have buffered bytes, use them.
                if !buf.isEmpty {
                    return (String(data: buf, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                throw DirectoryClientError.timeout
            }
            buf.append(chunk)
            if let lineEnd = buf.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buf[buf.startIndex..<lineEnd]
                return (String(data: lineData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let candidate = (String(data: buf, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if DirectoryLoginResponseValidator.isSuccessResponse(candidate) {
                return candidate
            }
        }
        throw DirectoryClientError.timeout
    }

    /// Accumulate chunks until the byte sequence `marker` is present, then return everything.
    private func readUntilMarker(_ marker: String, from conn: NWConnection) async throws -> Data {
        var buf = Data()
        let markerBytes = Data(marker.utf8)
        let deadline = Date().addingTimeInterval(60)   // max 60 s for the full list

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            do {
                let chunk = try await receiveChunk(from: conn, timeout: remaining)
                buf.append(chunk)
            } catch {
                if buf.isEmpty {
                    throw error
                }
                break   // connection closed — return what we have
            }

            if buf.range(of: markerBytes) != nil { return buf }
            if buf.count > 4_000_000             { return buf }   // safety valve
        }

        if buf.isEmpty {
            throw DirectoryClientError.timeout
        }
        return buf
    }

    private func receiveChunk(from conn: NWConnection, timeout: TimeInterval) async throws -> Data {
        let gate = DirectoryContinuationGate<Data>()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                gate.install(continuation)

                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                    if gate.resume(throwing: DirectoryClientError.timeout) {
                        conn.cancel()
                    }
                }

                conn.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { content, _, isComplete, error in
                    // Network.framework may provide the final response bytes and a
                    // stream-close error together. Never discard valid content.
                    if let data = content, !data.isEmpty {
                        gate.resume(returning: data)
                    } else if let error {
                        if Self.isFinalReadError(error) {
                            gate.resume(throwing: CancellationError())
                            return
                        }
                        gate.resume(throwing: DirectoryClientError.connectionFailed(error.localizedDescription))
                    } else if isComplete {
                        gate.resume(throwing: CancellationError())
                    } else {
                        gate.resume(throwing: DirectoryClientError.unexpectedResponse("Empty chunk"))
                    }
                }
            }
        } onCancel: {
            if gate.resume(throwing: CancellationError()) {
                conn.cancel()
            }
        }
    }

    private static func isFinalReadError(_ error: Error) -> Bool {
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                // ENOMSG / final-read style stream closure can surface this way.
                return code == .ENOMSG
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.code == 96 {
            let domain = nsError.domain.lowercased()
            if domain.contains("network.nwerror") || domain.contains("nsposix") {
                return true
            }
        }
        let lower = error.localizedDescription.lowercased()
        return lower.contains("no message available on stream")
            || lower.contains("final read")
            || lower.contains("already delivered final read")
    }

}
