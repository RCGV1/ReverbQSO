// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

actor EchoLinkProxySession {
    enum ResponseBoundary: Sendable {
        case line
        case marker(Data)
    }

    enum SessionError: LocalizedError {
        case directoryBusy
        case directoryOpenFailed
        case directoryClosed
        case timedOut

        var errorDescription: String? {
            switch self {
            case .directoryBusy: return "Another proxy directory request is already active."
            case .directoryOpenFailed: return "The proxy could not open the EchoLink directory connection."
            case .directoryClosed: return "The proxy directory connection closed before returning a response."
            case .timedOut: return "The proxy directory request timed out."
            }
        }
    }

    let configuration: EchoLinkProxyConfiguration
    let callsign: String

    private let client: EchoLinkProxyClient
    private var receiveTask: Task<Void, Never>?
    private var udpContinuation: AsyncThrowingStream<EchoLinkProxyMessage, Error>.Continuation?
    private var statusWaiter: (UUID, CheckedContinuation<Void, Error>)?
    private var responseWaiter: (UUID, ResponseBoundary, Data, CheckedContinuation<Data, Error>)?
    private var isDirectoryTransactionActive = false
    private var terminalError: Error?

    private init(client: EchoLinkProxyClient, configuration: EchoLinkProxyConfiguration, callsign: String) {
        self.client = client
        self.configuration = configuration
        self.callsign = callsign
    }

    static func connect(
        configurations: [EchoLinkProxyConfiguration],
        callsign: String
    ) async throws -> EchoLinkProxySession {
        let connected = try await EchoLinkProxyClient.connectFirstAvailable(
            configurations: configurations,
            callsign: callsign
        )
        let session = EchoLinkProxySession(
            client: connected.client,
            configuration: connected.configuration,
            callsign: callsign.uppercased()
        )
        await session.startReceiving()
        return session
    }

    func udpMessages() -> AsyncThrowingStream<EchoLinkProxyMessage, Error> {
        AsyncThrowingStream { continuation in
            if let terminalError {
                continuation.finish(throwing: terminalError)
                return
            }
            udpContinuation = continuation
        }
    }

    func isUsable() -> Bool {
        terminalError == nil
    }

    func sendAudio(_ data: Data, to host: String) async throws {
        try await client.sendAudio(data, to: host)
    }

    func sendControl(_ data: Data, to host: String) async throws {
        try await client.sendControl(data, to: host)
    }

    func directoryRequest(
        _ payload: Data,
        host: String,
        boundary: ResponseBoundary,
        timeout: Duration = .seconds(30)
    ) async throws -> Data {
        if let terminalError { throw terminalError }
        guard !isDirectoryTransactionActive else { throw SessionError.directoryBusy }
        isDirectoryTransactionActive = true
        defer { isDirectoryTransactionActive = false }
        let numericHost = try Self.resolveIPv4(host)
        do {
            try await awaitDirectoryOpen(host: numericHost, timeout: timeout)
        } catch {
            // Proxy frames have no transaction identifier. Once TCP_OPEN has
            // timed out, a late TCP_STATUS cannot be distinguished from the
            // status for a later request, so retire this authenticated socket.
            close()
            throw error
        }
        do {
            let response = try await awaitDirectoryResponse(payload, boundary: boundary, timeout: timeout)
            do {
                try await client.closeTCP()
            } catch {
                // Without a confirmed TCP_CLOSE send, the proxy may keep its
                // directory stream open and route later data into the next
                // logical request. Retire the uncorrelatable session.
                close()
                throw error
            }
            return response
        } catch {
            // A delayed TCP_DATA/TCP_CLOSE is just as uncorrelated as a delayed
            // TCP_STATUS. Retire the socket after any incomplete transaction.
            close()
            throw error
        }
    }

    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        client.close()
        failAll(SessionError.directoryClosed)
    }

    private func startReceiving() {
        let stream = client.messages()
        receiveTask = Task { [weak self] in
            do {
                for try await message in stream {
                    await self?.handle(message)
                }
                await self?.failAll(SessionError.directoryClosed)
            } catch {
                await self?.failAll(error)
            }
        }
    }

    private func handle(_ message: EchoLinkProxyMessage) {
        switch message.type {
        case .tcpStatus:
            guard let (id, continuation) = statusWaiter else { return }
            statusWaiter = nil
            if message.payload.count == 4, message.payload.allSatisfy({ $0 == 0 }) {
                continuation.resume()
            } else {
                continuation.resume(throwing: SessionError.directoryOpenFailed)
            }
            _ = id
        case .tcpData:
            guard let (id, boundary, existing, continuation) = responseWaiter else { return }
            var buffer = existing
            buffer.append(message.payload)
            if responseComplete(buffer, boundary: boundary) {
                responseWaiter = nil
                continuation.resume(returning: buffer)
            } else {
                responseWaiter = (id, boundary, buffer, continuation)
            }
        case .tcpClose:
            guard let (_, _, buffer, continuation) = responseWaiter else { return }
            responseWaiter = nil
            if buffer.isEmpty {
                continuation.resume(throwing: SessionError.directoryClosed)
            } else {
                continuation.resume(returning: buffer)
            }
        case .udpData, .udpControl, .system:
            udpContinuation?.yield(message)
        case .tcpOpen:
            break
        }
    }

    private func awaitDirectoryOpen(host: String, timeout: Duration) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            statusWaiter = (id, continuation)
            Task {
                do { try await client.openTCP(to: host) }
                catch { timeoutStatus(id: id, error: error) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                timeoutStatus(id: id, error: SessionError.timedOut)
            }
        }
    }

    private func awaitDirectoryResponse(
        _ payload: Data,
        boundary: ResponseBoundary,
        timeout: Duration
    ) async throws -> Data {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            responseWaiter = (id, boundary, Data(), continuation)
            Task {
                do { try await client.sendTCP(payload) }
                catch { timeoutResponse(id: id, error: error) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                timeoutResponse(id: id, error: SessionError.timedOut)
            }
        }
    }

    private func responseComplete(_ data: Data, boundary: ResponseBoundary) -> Bool {
        switch boundary {
        case .line:
            let candidate = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return data.contains(0x0A) || data.contains(0x0D)
                || DirectoryLoginResponseValidator.isSuccessResponse(candidate)
        case .marker(let marker):
            return data.range(of: marker) != nil
        }
    }

    private func timeoutStatus(id: UUID, error: Error) {
        guard let (current, continuation) = statusWaiter, current == id else { return }
        statusWaiter = nil
        continuation.resume(throwing: error)
    }

    private func timeoutResponse(id: UUID, error: Error) {
        guard let (current, _, _, continuation) = responseWaiter, current == id else { return }
        responseWaiter = nil
        continuation.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        terminalError = error
        if let (_, continuation) = statusWaiter { continuation.resume(throwing: error) }
        statusWaiter = nil
        if let (_, _, _, continuation) = responseWaiter { continuation.resume(throwing: error) }
        responseWaiter = nil
        udpContinuation?.finish(throwing: error)
        udpContinuation = nil
    }

    private static func resolveIPv4(_ host: String) throws -> String {
        var address = in_addr()
        if inet_pton(AF_INET, host, &address) == 1 { return host }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            throw DirectoryClientError.connectionFailed("Could not resolve the directory server.")
        }
        defer { freeaddrinfo(result) }
        guard let socketAddress = result.pointee.ai_addr else {
            throw DirectoryClientError.connectionFailed("Could not resolve the directory server.")
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ipv4 = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            var value = pointer.pointee.sin_addr
            return inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN))
        }
        guard ipv4 != nil else {
            throw DirectoryClientError.connectionFailed("Could not resolve the directory server.")
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

@MainActor
final class EchoLinkProxySessionStore {
    private let configurationProvider: @MainActor () -> EchoLinkProxyConfiguration
    private var session: EchoLinkProxySession?
    private var requestedConfiguration: EchoLinkProxyConfiguration?
    private var callsign = ""
    private var generation: UInt64 = 0

    init(configurationProvider: @escaping @MainActor () -> EchoLinkProxyConfiguration = {
        EchoLinkProxyConfiguration.load()
    }) {
        self.configurationProvider = configurationProvider
    }

    func currentSession(callsign: String, configuration: EchoLinkProxyConfiguration? = nil) async -> EchoLinkProxySession? {
        let requested = configuration ?? configurationProvider()
        let normalized = callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lookupGeneration = generation
        guard requestedConfiguration == requested, self.callsign == normalized,
              let session, await session.isUsable(), generation == lookupGeneration else { return nil }
        return session
    }

    func sessionForCurrentConfiguration(callsign: String) async throws -> EchoLinkProxySession? {
        try await session(callsign: callsign, configuration: configurationProvider())
    }

    func session(
        callsign: String,
        configuration requested: EchoLinkProxyConfiguration,
        excluding rejected: [EchoLinkProxyConfiguration] = []
    ) async throws -> EchoLinkProxySession? {
        guard requested.isEnabled else {
            await close()
            return nil
        }
        let exclusions = requested.mode == .publicProxy ? rejected : []
        let normalized = callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lookupGeneration = generation
        if requestedConfiguration == requested, self.callsign == normalized, let session,
           !EchoLinkProxyClient.untriedCandidates([session.configuration], excluding: exclusions).isEmpty,
           await session.isUsable() {
            guard generation == lookupGeneration else { throw CancellationError() }
            return session
        }

        guard generation == lookupGeneration else { throw CancellationError() }
        generation &+= 1
        let connectingGeneration = generation
        let previousSession = session
        session = nil
        requestedConfiguration = nil
        self.callsign = ""
        await previousSession?.close()
        guard generation == connectingGeneration else { throw CancellationError() }
        let resolved = try await requested.resolvingProxyCandidates()
        let candidates = EchoLinkProxyClient.untriedCandidates(resolved, excluding: exclusions)
        guard !candidates.isEmpty else {
            throw EchoLinkProxyClient.ClientError.allCandidatesFailed(["No untried public proxy endpoints are available."])
        }
        try Task.checkCancellation()
        guard generation == connectingGeneration else { throw CancellationError() }
        let newSession = try await EchoLinkProxySession.connect(configurations: candidates, callsign: normalized)
        do {
            try Task.checkCancellation()
            guard generation == connectingGeneration else { throw CancellationError() }
        }
        catch { await newSession.close(); throw error }
        session = newSession
        requestedConfiguration = requested
        self.callsign = normalized
        return newSession
    }

    func close() async {
        generation &+= 1
        let closingSession = session
        session = nil
        requestedConfiguration = nil
        callsign = ""
        await closingSession?.close()
    }
}
