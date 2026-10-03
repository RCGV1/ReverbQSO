// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import os

final class EchoLinkProxyClient: @unchecked Sendable {
    static let defaultSetupTimeout: Int = 10
    static let defaultAuthenticationTimeout: TimeInterval = 10

    enum ClientError: Swift.Error, LocalizedError {
        case invalidPort(UInt16)
        case connectionFailed(String)
        case connectionClosed
        case badPassword
        case accessDenied
        case unexpectedSystemEvent(UInt8)
        case allCandidatesFailed([String])
        case authenticationTimedOut

        /// SYSTEM errors describe this proxy's password/ACL, not the directory account.
        var isCandidateRejection: Bool {
            switch self {
            case .badPassword, .accessDenied: return true
            default: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port): return "Invalid EchoLink Proxy port: \(port)."
            case .connectionFailed(let reason): return "EchoLink Proxy connection failed: \(reason)"
            case .connectionClosed: return "The EchoLink Proxy connection closed."
            case .badPassword: return "The EchoLink Proxy rejected the password."
            case .accessDenied: return "The EchoLink Proxy denied access for this callsign."
            case .unexpectedSystemEvent(let code): return "EchoLink Proxy reported system event \(code)."
            case .allCandidatesFailed(let failures):
                return "Could not connect to an EchoLink Proxy. " + failures.joined(separator: " ")
            case .authenticationTimedOut:
                return "The EchoLink Proxy did not send an authentication challenge in time."
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.reverbqso.app.proxy")
    private let logger = Logger(subsystem: "org.reverbqso.app", category: "EchoLinkProxy")
    private var receiveBuffer = Data()
    private lazy var messageBuffer = LiveTransportMessageBuffer<EchoLinkProxyMessage>(
        onConsumerCancellation: { [weak self] in self?.close() }
    )
    private var isClosed = false
    private let authenticationTimeout: TimeInterval

    init(
        host: String,
        port: UInt16,
        setupTimeout: Int = defaultSetupTimeout,
        authenticationTimeout: TimeInterval = defaultAuthenticationTimeout
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ClientError.invalidPort(port) }
        self.authenticationTimeout = authenticationTimeout
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = setupTimeout
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: NWParameters(tls: nil, tcp: tcpOptions)
        )
    }

    static func connectFirstAvailable(
        configurations: [EchoLinkProxyConfiguration],
        callsign: String
    ) async throws -> (client: EchoLinkProxyClient, configuration: EchoLinkProxyConfiguration) {
        var failures: [String] = []
        for configuration in configurations {
            try Task.checkCancellation()
            let client = try EchoLinkProxyClient(host: configuration.host, port: configuration.port)
            do {
                try await client.connect(callsign: callsign, password: configuration.password)
                return (client, configuration)
            } catch is CancellationError {
                client.close()
                throw CancellationError()
            } catch {
                client.close()
                failures.append("\(configuration.host):\(configuration.port): \(error.localizedDescription)")
            }
        }
        throw ClientError.allCandidatesFailed(failures)
    }

    static func untriedCandidates(
        _ configurations: [EchoLinkProxyConfiguration],
        excluding rejected: [EchoLinkProxyConfiguration]
    ) -> [EchoLinkProxyConfiguration] {
        configurations.filter { candidate in
            !rejected.contains {
                $0.host.caseInsensitiveCompare(candidate.host) == .orderedSame && $0.port == candidate.port
            }
        }
    }

    func connect(callsign: String, password: String) async throws {
        try await withTaskCancellationHandler {
            try await waitUntilReady()
            let nonce = try await receiveExactly(8, timeout: authenticationTimeout)
            let response = try EchoLinkProxyProtocol.authenticationResponse(
                callsign: callsign,
                password: password,
                nonce: nonce
            )
            try await sendRaw(response)
        } onCancel: {
            self.close()
        }
    }

    func messages() -> AsyncThrowingStream<EchoLinkProxyMessage, Swift.Error> {
        queue.async {
            guard !self.isClosed else {
                self.messageBuffer.finish(throwing: ClientError.connectionClosed)
                return
            }
            self.receiveNextChunk()
        }
        return AsyncThrowingStream(unfolding: { try await self.messageBuffer.next() })
    }

    func sendAudio(_ data: Data, to remoteHost: String) async throws {
        try await send(type: .udpData, data: data, to: remoteHost)
    }

    func sendControl(_ data: Data, to remoteHost: String) async throws {
        try await send(type: .udpControl, data: data, to: remoteHost)
    }

    func openTCP(to remoteHost: String) async throws {
        try await send(type: .tcpOpen, data: Data(), to: remoteHost)
    }

    func sendTCP(_ data: Data) async throws {
        try await send(type: .tcpData, data: data, to: "0.0.0.0")
    }

    func closeTCP() async throws {
        try await send(type: .tcpClose, data: Data(), to: "0.0.0.0")
    }

    func close() {
        queue.async {
            guard !self.isClosed else { return }
            self.isClosed = true
            self.connection.cancel()
            self.messageBuffer.finish()
        }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.connection.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        self.connection.stateUpdateHandler = nil
                        continuation.resume(throwing: ClientError.connectionFailed(error.localizedDescription))
                    case .cancelled:
                        self.connection.stateUpdateHandler = nil
                        continuation.resume(throwing: ClientError.connectionClosed)
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    private func receiveExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        var received = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while received.count < count {
            let remaining = count - received.count
            let remainingTime = deadline.timeIntervalSinceNow
            guard remainingTime > 0 else { throw ClientError.authenticationTimedOut }
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error {
                        gate.resume(throwing: ClientError.connectionFailed(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        gate.resume(returning: data)
                    } else if isComplete {
                        gate.resume(throwing: ClientError.connectionClosed)
                    } else {
                        gate.resume(throwing: ClientError.connectionFailed("empty authentication challenge"))
                    }
                }
                queue.asyncAfter(deadline: .now() + remainingTime) {
                    if gate.resume(throwing: ClientError.authenticationTimedOut) {
                        self.connection.cancel()
                    }
                }
            }
            received.append(chunk)
        }
        return received
    }

    private func send(
        type: EchoLinkProxyMessage.MessageType,
        data: Data,
        to remoteHost: String
    ) async throws {
        let frame = try EchoLinkProxyProtocol.encode(type: type, remoteHost: remoteHost, payload: data)
        logger.info("Proxy outbound type=\(type.rawValue) payloadBytes=\(data.count)")
        try await sendRaw(frame)
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ClientError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            self.queue.async {
                if let data { self.receiveBuffer.append(data) }
                do {
                    while let message = try EchoLinkProxyProtocol.parseNextMessage(from: &self.receiveBuffer) {
                        self.logger.info(
                            "Proxy inbound type=\(message.type.rawValue) source=\(message.remoteHost, privacy: .public) payloadBytes=\(message.payload.count)"
                        )
                        if let event = message.systemEvent {
                            switch event {
                            case .badPassword: throw ClientError.badPassword
                            case .accessDenied: throw ClientError.accessDenied
                            case .unknown(let code): throw ClientError.unexpectedSystemEvent(code)
                            }
                        }
                        let kind: LiveTransportMessageBuffer<EchoLinkProxyMessage>.MessageKind
                        if message.type == .udpData {
                            guard let payloadKind = LiveTransportAudioPortPayloadKind.classify(message.payload)
                            else { continue }
                            kind = payloadKind == .voice ? .voice : .control
                        } else {
                            kind = .control
                        }
                        guard self.messageBuffer.yield(message, kind: kind) else {
                            self.finishReceiving(
                                throwing: LiveTransportMessageBufferError.controlOverflow
                            )
                            return
                        }
                    }
                } catch {
                    self.logger.warning(
                        "Proxy inbound decode failed bufferedBytes=\(self.receiveBuffer.count) error='\(error.localizedDescription, privacy: .public)'"
                    )
                    self.finishReceiving(throwing: error)
                    return
                }

                if let error {
                    self.finishReceiving(throwing: ClientError.connectionFailed(error.localizedDescription))
                } else if isComplete {
                    self.finishReceiving(throwing: ClientError.connectionClosed)
                } else if !self.isClosed {
                    self.receiveNextChunk()
                }
            }
        }
    }

    private func finishReceiving(throwing error: Swift.Error) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        messageBuffer.finish(throwing: error)
    }
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Swift.Error>?

    init(_ continuation: CheckedContinuation<Value, Swift.Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: Value) -> Bool {
        guard let continuation = take() else { return false }
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Swift.Error) -> Bool {
        guard let continuation = take() else { return false }
        continuation.resume(throwing: error)
        return true
    }

    private func take() -> CheckedContinuation<Value, Swift.Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
