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
        case directoryDeferred

        var errorDescription: String? {
            switch self {
            case .directoryBusy: return "Another proxy directory request is already active."
            case .directoryOpenFailed: return "The proxy could not open the EchoLink directory connection."
            case .directoryClosed: return "The proxy directory connection closed before returning a response."
            case .timedOut: return "The proxy directory request timed out."
            case .directoryDeferred: return "The station list will refresh after your call."
            }
        }
    }

    let configuration: EchoLinkProxyConfiguration
    let callsign: String

    private let client: EchoLinkProxyClient
    private var receiveTask: Task<Void, Never>?
    private var udpBuffer: LiveTransportMessageBuffer<EchoLinkProxyMessage>?
    private var statusWaiter: (UUID, CheckedContinuation<Void, Error>)?
    private var responseWaiter: (UUID, ResponseBoundary, Data, CheckedContinuation<Data, Error>)?
    private var isDirectoryTransactionActive = false
    private var serializedTurnActive = false
    private var directoryTurnWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var terminalError: Error?
    private var directoryQuarantined = false
    private var udpConsumerID: UUID?
    private var quarantinedDirectoryRecovery: (@Sendable () -> Void)?

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

    func udpMessages(consumerID: UUID = UUID()) -> AsyncThrowingStream<EchoLinkProxyMessage, Error> {
        udpBuffer?.finish(throwing: CancellationError())
        udpConsumerID = consumerID
        let buffer = LiveTransportMessageBuffer<EchoLinkProxyMessage>()
        buffer.setOnConsumerCancellation { [weak self, weak buffer] in
            buffer?.finish(throwing: CancellationError())
            Task { await self?.releaseUDPConsumer(consumerID) }
        }
        udpBuffer = buffer
        if let terminalError { buffer.finish(throwing: terminalError) }
        return AsyncThrowingStream(unfolding: { try await buffer.next() })
    }

    func isUsable() -> Bool {
        terminalError == nil
    }

    func isDirectoryUsable() -> Bool { terminalError == nil && !directoryQuarantined }

    func hasActiveVoiceConsumer() -> Bool {
        terminalError == nil && udpConsumerID != nil && udpBuffer?.isFinished == false
    }

    func recoverDirectoryWhenVoiceEnds(_ action: @escaping @Sendable () -> Void) {
        guard directoryQuarantined, terminalError == nil else { return }
        if hasActiveVoiceConsumer() {
            quarantinedDirectoryRecovery = action
        } else {
            action()
        }
    }

    /// A receive loop can finish between `next()` calls, before the buffer's
    /// cancellation handler runs. Its owner must also release on loop exit.
    func releaseUDPConsumer(_ id: UUID) {
        guard udpConsumerID == id else { return }
        udpConsumerID = nil
        udpBuffer = nil
        let recovery = quarantinedDirectoryRecovery
        quarantinedDirectoryRecovery = nil
        if directoryQuarantined, terminalError == nil { recovery?() }
    }

    var inboundAudioMetrics: [String: LiveTransportMessageBufferMetrics] {
        var metrics = ["socket": client.inboundAudioMetrics]
        if let udpBuffer { metrics["session"] = udpBuffer.metricsSnapshot }
        return metrics
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
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        guard !directoryQuarantined else { throw SessionError.directoryDeferred }
        guard !isDirectoryTransactionActive else { throw SessionError.directoryBusy }
        isDirectoryTransactionActive = true
        defer { isDirectoryTransactionActive = false }
        // Once TCP_OPEN has been sent, drain the bounded response even if the
        // page disappears. Cancelling that UI task must not cut off QSO UDP.
        return try await performDirectoryRequest(payload, host: host, boundary: boundary, timeout: timeout)
    }

    /// Serialize directory commands while retaining the proxy's UDP stream.
    /// Cancelling a queued request does not close the shared authenticated tunnel.
    func serializedDirectoryRequest(
        _ payload: Data, host: String, boundary: ResponseBoundary,
        timeout: Duration = .seconds(30)
    ) async throws -> Data {
        try await acquireDirectoryTurn()
        defer { releaseDirectoryTurn() }
        try Task.checkCancellation()
        return try await directoryRequest(payload, host: host, boundary: boundary, timeout: timeout)
    }

    private func acquireDirectoryTurn() async throws {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        if !serializedTurnActive {
            serializedTurnActive = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { directoryTurnWaiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelDirectoryTurn(id: id) }
        }
    }

    private func releaseDirectoryTurn() {
        guard !directoryTurnWaiters.isEmpty else { serializedTurnActive = false; return }
        directoryTurnWaiters.removeFirst().1.resume()
    }

    private func cancelDirectoryTurn(id: UUID) {
        guard let index = directoryTurnWaiters.firstIndex(where: { $0.0 == id }) else { return }
        directoryTurnWaiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func performDirectoryRequest(
        _ payload: Data, host: String, boundary: ResponseBoundary, timeout: Duration
    ) async throws -> Data {
        let numericHost = try Self.resolveIPv4(host)
        do {
            try await awaitDirectoryOpen(host: numericHost, timeout: timeout)
        } catch {
            if terminalError == nil,
               case SessionError.directoryOpenFailed = error {
                // TCP_STATUS rejected this remote directory socket. The
                // authenticated proxy connection and its UDP path are intact.
                throw error
            }
            // Proxy frames have no transaction identifier. Once TCP_OPEN has
            // timed out, a late TCP_STATUS cannot be distinguished from the
            // status for a later request, so stop reusing its directory channel.
            retireDirectory(after: error)
            throw error
        }
        do {
            let response = try await awaitDirectoryResponse(payload, boundary: boundary, timeout: timeout)
            do {
                // The transaction is committed once TCP_OPEN succeeds. A UI
                // task may be canceled while its bounded response is draining,
                // but the shared tunnel still needs TCP_CLOSE. Run that final
                // framed send outside the canceled caller; sendRaw retains its
                // own deadline and retires the tunnel if the close really stalls.
                let client = self.client
                try await Task { try await client.closeTCP() }.value
            } catch {
                // Without a confirmed TCP_CLOSE send, the proxy may keep its
                // directory stream open and route later data into the next
                // logical request. Retire the uncorrelatable session.
                retireDirectory(after: error)
                throw error
            }
            return response
        } catch {
            if terminalError == nil,
               case SessionError.directoryClosed = error {
                // A framed TCP_CLOSE is the end of the remote directory
                // transaction, not the end of the proxy's voice tunnel. The
                // caller can retry on this same authenticated connection.
                throw error
            }
            // A delayed TCP_DATA/TCP_CLOSE is just as uncorrelated as a delayed
            // TCP_STATUS. Stop directory reuse after an incomplete transaction.
            retireDirectory(after: error)
            throw error
        }
    }

    private func retireDirectory(after error: Error) {
        // TCP directory frames have no request identifiers. After a timeout,
        // never send another directory command on this socket. UDP frames are
        // independently typed and can safely keep an existing QSO alive.
        if hasActiveVoiceConsumer(),
           case SessionError.timedOut = error {
            directoryQuarantined = true
        } else {
            close()
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
            let kind: LiveTransportMessageBuffer<EchoLinkProxyMessage>.MessageKind
            if message.type == .udpData {
                guard let payloadKind = LiveTransportAudioPortPayloadKind.classify(message.payload)
                else { return }
                kind = payloadKind == .voice ? .voice : .control
            } else {
                kind = .control
            }
            if let udpBuffer, !udpBuffer.yield(message, kind: kind),
               udpBuffer.hasControlOverflowed {
                close()
            }
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
        guard terminalError == nil else { return }
        terminalError = error
        udpConsumerID = nil
        quarantinedDirectoryRecovery = nil
        let waiting = directoryTurnWaiters
        directoryTurnWaiters.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
        if let (_, continuation) = statusWaiter { continuation.resume(throwing: error) }
        statusWaiter = nil
        if let (_, _, _, continuation) = responseWaiter { continuation.resume(throwing: error) }
        responseWaiter = nil
        udpBuffer?.finish(throwing: error)
        udpBuffer = nil
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
    private let resolveCandidates: @MainActor (EchoLinkProxyConfiguration) async throws -> [EchoLinkProxyConfiguration]
    private var session: EchoLinkProxySession?
    private var requestedConfiguration: EchoLinkProxyConfiguration?
    private var callsign = ""
    private var generation: UInt64 = 0

    init(configurationProvider: @escaping @MainActor () -> EchoLinkProxyConfiguration = {
        EchoLinkProxyConfiguration.load()
    }, resolveCandidates: @escaping @MainActor (EchoLinkProxyConfiguration) async throws -> [EchoLinkProxyConfiguration] = {
        try await $0.resolvingProxyCandidates()
    }) {
        self.configurationProvider = configurationProvider
        self.resolveCandidates = resolveCandidates
    }

    func currentSession(callsign: String, configuration: EchoLinkProxyConfiguration? = nil) async -> EchoLinkProxySession? {
        let requested = configuration ?? configurationProvider()
        let normalized = callsign.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lookupGeneration = generation
        guard requestedConfiguration == requested, self.callsign == normalized,
              let session, await canReuse(session), generation == lookupGeneration else { return nil }
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
           await canReuse(session) {
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
        let resolved = try await resolveCandidates(requested)
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

    private func canReuse(_ session: EchoLinkProxySession) async -> Bool {
        if await session.isDirectoryUsable() { return true }
        return await session.hasActiveVoiceConsumer()
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
