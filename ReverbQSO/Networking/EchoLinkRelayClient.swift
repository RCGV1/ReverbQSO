// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import os

struct EchoLinkRelayTiming: Sendable {
    let ackTimeout: Duration
    let registrationAttempts: Int
    let keepaliveInterval: Duration
    let registrationInterval: Duration

    static let standard = EchoLinkRelayTiming(
        ackTimeout: .seconds(3),
        registrationAttempts: 3,
        keepaliveInterval: .seconds(20),
        registrationInterval: .seconds(20)
    )
}

enum EchoLinkRelayClientError: LocalizedError {
    case alreadyConnected
    case notConnected
    case resolutionFailed
    case registrationTimedOut
    case registrationRejected

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "An EchoLink Relay session is already active."
        case .notConnected:
            return "The EchoLink Relay is not connected. Reconnect before sending."
        case .resolutionFailed:
            return "Could not resolve the EchoLink Relay host. Check the network and relay address."
        case .registrationTimedOut:
            return "The EchoLink Relay did not acknowledge registration. Check connectivity and retry."
        case .registrationRejected:
            return "The EchoLink Relay rejected registration. Check the station's relay access."
        }
    }
}

/// Owns one outbound UDP relay socket. It never binds EchoLink's 5198/5199 ports.
actor EchoLinkRelayClient {
    private struct Peer: Hashable, Sendable {
        let host: String
        let port: UInt16
    }

    private let host: String
    private let port: UInt16
    private let timing: EchoLinkRelayTiming
    private let resolvedIPv4Candidates: [String]?
    private let logger = Logger(subsystem: "org.reverbqso.app", category: "EchoLinkRelay")
    private var socket: BoundUDPSocket?
    private var resolvedHost: String?
    private var callsign: String?
    private var activePeers: Set<Peer> = []
    private var isClosing = false
    private var responseBuffer = LiveTransportMessageBuffer<EchoLinkRelayResponse>()
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var connectGeneration: UInt64 = 0
    private var isConnecting = false

    init(
        host: String = EchoLinkRelayProtocol.host,
        port: UInt16 = EchoLinkRelayProtocol.port,
        timing: EchoLinkRelayTiming = .standard,
        resolvedIPv4Candidates: [String]? = nil
    ) {
        self.host = host
        self.port = port
        self.timing = timing
        self.resolvedIPv4Candidates = resolvedIPv4Candidates
    }

    func connect(callsign: String) async throws -> AsyncThrowingStream<EchoLinkRelayResponse, Error> {
        guard socket == nil, !isConnecting, !isClosing else { throw EchoLinkRelayClientError.alreadyConnected }
        isConnecting = true
        connectGeneration &+= 1
        let generation = connectGeneration
        defer {
            if connectGeneration == generation { isConnecting = false }
        }
        let registration = try EchoLinkRelayProtocol.register(callsign: callsign)
        let addresses: [String]
        if let resolvedIPv4Candidates {
            addresses = resolvedIPv4Candidates
        } else {
            addresses = try await Self.resolveIPv4(host)
        }
        guard !addresses.isEmpty else { throw EchoLinkRelayClientError.resolutionFailed }
        try Task.checkCancellation()
        guard connectGeneration == generation else { throw CancellationError() }
        let newSocket = try BoundUDPSocket(localPort: 0)
        socket = newSocket

        var acceptedAddress: String?
        do {
            for address in addresses {
                for _ in 0..<max(1, timing.registrationAttempts) {
                    try Task.checkCancellation()
                    guard connectGeneration == generation else { throw CancellationError() }
                    try await newSocket.send(registration, to: address, port: port)
                    guard connectGeneration == generation else { throw CancellationError() }
                    do {
                        try await awaitRegistrationAcknowledgement(on: newSocket, relayHost: address)
                        try Task.checkCancellation()
                        guard connectGeneration == generation else { throw CancellationError() }
                        acceptedAddress = address
                        break
                    } catch EchoLinkRelayClientError.registrationTimedOut {
                        try Task.checkCancellation()
                    }
                }
                if acceptedAddress != nil { break }
            }
            guard acceptedAddress != nil else { throw EchoLinkRelayClientError.registrationTimedOut }
        } catch {
            newSocket.close()
            if connectGeneration == generation {
                socket = nil
                resolvedHost = nil
            }
            throw error
        }
        guard let acceptedAddress else { throw EchoLinkRelayClientError.registrationTimedOut }
        resolvedHost = acceptedAddress
        logger.info("Relay selected host=\(acceptedAddress, privacy: .public)")

        self.callsign = callsign
        let responseBuffer = LiveTransportMessageBuffer<EchoLinkRelayResponse>()
        responseBuffer.setOnConsumerCancellation { [weak self, weak responseBuffer] in
            guard let responseBuffer else { return }
            Task { await self?.closeIfCurrentResponseBuffer(responseBuffer) }
        }
        self.responseBuffer = responseBuffer
        let stream = AsyncThrowingStream<EchoLinkRelayResponse, Error>(
            unfolding: { try await responseBuffer.next() }
        )
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(
                socket: newSocket,
                relayHost: acceptedAddress,
                responseBuffer: responseBuffer
            )
        }
        keepaliveTask = Task { [weak self] in
            await self?.keepaliveLoop()
        }
        registrationTask = Task { [weak self] in
            await self?.registrationLoop()
        }
        return stream
    }

    func sendData(_ payload: Data, to peerHost: String, port peerPort: UInt16) async throws {
        guard let socket, let resolvedHost else { throw EchoLinkRelayClientError.notConnected }
        let datagram = try EchoLinkRelayProtocol.encodeRequest(
            type: .data,
            destinationHost: peerHost,
            destinationPort: peerPort,
            payload: payload
        )
        logger.info("Relay DATA outbound destinationPort=\(peerPort) payloadBytes=\(payload.count)")
        try await socket.send(datagram, to: resolvedHost, port: port)
        guard self.socket === socket else { throw EchoLinkRelayClientError.notConnected }
        activePeers.insert(Peer(host: peerHost, port: peerPort))
    }

    func selectedRelayAddress() -> String? { resolvedHost }

    /// Refreshes the relay's route to this callsign after a mid-call allocation error.
    func refreshRegistration() async throws {
        guard let socket, let resolvedHost, let callsign else {
            throw EchoLinkRelayClientError.notConnected
        }
        let registration = try EchoLinkRelayProtocol.register(callsign: callsign)
        try await socket.send(registration, to: resolvedHost, port: port)
        guard self.socket === socket else { throw EchoLinkRelayClientError.notConnected }
    }

    func close() async {
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        connectGeneration &+= 1
        isConnecting = false
        receiveTask?.cancel()
        keepaliveTask?.cancel()
        registrationTask?.cancel()
        receiveTask = nil
        keepaliveTask = nil
        registrationTask = nil

        let closingSocket = socket
        let closingHost = resolvedHost
        let closingCallsign = callsign
        let closingPeers = activePeers
        socket = nil
        resolvedHost = nil
        callsign = nil
        activePeers.removeAll()
        responseBuffer.finish()

        if let closingSocket, let closingHost {
            if let closingCallsign {
                for peer in closingPeers {
                    if let drop = try? EchoLinkRelayProtocol.dropFlow(
                        destinationHost: peer.host,
                        destinationPort: peer.port,
                        callsign: closingCallsign
                    ) {
                        try? await closingSocket.send(drop, to: closingHost, port: port)
                    }
                }
            }
            if let closingCallsign,
               let unregister = try? EchoLinkRelayProtocol.unregister(callsign: closingCallsign) {
                try? await closingSocket.send(unregister, to: closingHost, port: port)
            }
        }
        closingSocket?.close()
    }

    private func closeIfCurrentResponseBuffer(
        _ expectedBuffer: LiveTransportMessageBuffer<EchoLinkRelayResponse>
    ) async {
        guard responseBuffer === expectedBuffer else { return }
        await close()
    }

    private func awaitRegistrationAcknowledgement(on socket: BoundUDPSocket, relayHost: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timing.ackTimeout)
        while clock.now < deadline {
            let remaining = clock.now.duration(to: deadline)
            let datagram = try await Self.receive(socket: socket, timeout: remaining)
            guard datagram.sourceHost == relayHost, datagram.sourcePort == port else { continue }
            guard let response = try? EchoLinkRelayProtocol.decodeResponse(datagram.data) else { continue }
            switch response.type {
            case .ack:
                return
            case .error:
                throw EchoLinkRelayClientError.registrationRejected
            case .data, .ping:
                continue
            }
        }
        throw EchoLinkRelayClientError.registrationTimedOut
    }

    private nonisolated static func receive(socket: BoundUDPSocket, timeout: Duration) async throws -> BoundUDPSocket.Datagram {
        try await withThrowingTaskGroup(of: BoundUDPSocket.Datagram.self) { group in
            group.addTask {
                try await socket.receive(maximumBytes: EchoLinkRelayProtocol.maxDatagramBytes)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw EchoLinkRelayClientError.registrationTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw EchoLinkRelayClientError.registrationTimedOut }
            return first
        }
    }

    private func receiveLoop(
        socket: BoundUDPSocket,
        relayHost: String,
        responseBuffer: LiveTransportMessageBuffer<EchoLinkRelayResponse>
    ) async {
        while !Task.isCancelled {
            do {
                let datagram = try await socket.receive(maximumBytes: EchoLinkRelayProtocol.maxDatagramBytes)
                guard datagram.sourceHost == relayHost, datagram.sourcePort == port else {
                    logger.warning(
                        "Relay inbound ignored unexpectedSender=\(datagram.sourceHost, privacy: .public):\(datagram.sourcePort) bytes=\(datagram.data.count)"
                    )
                    continue
                }
                let response: EchoLinkRelayResponse
                do {
                    response = try EchoLinkRelayProtocol.decodeResponse(datagram.data)
                } catch {
                    logger.warning(
                        "Relay inbound decode failed bytes=\(datagram.data.count) error='\(error.localizedDescription, privacy: .public)'"
                    )
                    continue
                }
                logger.info(
                    "Relay inbound type=\(response.type.rawValue) source=\(response.sourceHost, privacy: .public):\(response.sourcePort) destinationPort=\(response.destinationPort) payloadBytes=\(response.payload.count)"
                )
                let kind: LiveTransportMessageBuffer<EchoLinkRelayResponse>.MessageKind
                if response.type == .data, response.destinationPort == 5198 {
                    guard let payloadKind = LiveTransportAudioPortPayloadKind.classify(response.payload)
                    else { continue }
                    kind = payloadKind == .voice ? .voice : .control
                } else {
                    kind = .control
                }
                guard responseBuffer.yield(response, kind: kind) else {
                    responseBuffer.finish(
                        throwing: LiveTransportMessageBufferError.controlOverflow
                    )
                    break
                }
            } catch is CancellationError {
                break
            } catch {
                if !Task.isCancelled {
                    responseBuffer.finish(throwing: error)
                }
                break
            }
        }
    }

    private func keepaliveLoop() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: timing.keepaliveInterval) } catch { break }
            guard let socket, let resolvedHost else { continue }
            for peer in activePeers {
                guard !Task.isCancelled, self.socket === socket else { break }
                guard let datagram = try? EchoLinkRelayProtocol.encodeRequest(
                    type: .keepalive,
                    destinationHost: peer.host,
                    destinationPort: peer.port
                ) else { continue }
                try? await socket.send(datagram, to: resolvedHost, port: port)
            }
        }
    }

    private func registrationLoop() async {
        let interval = min(timing.registrationInterval, .seconds(599))
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { break }
            guard let socket, let resolvedHost, let callsign,
                  let datagram = try? EchoLinkRelayProtocol.register(callsign: callsign) else { continue }
            try? await socket.send(datagram, to: resolvedHost, port: port)
        }
    }

    private nonisolated static func resolveIPv4(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_DGRAM
                var result: UnsafeMutablePointer<addrinfo>?
                let code = host.withCString { Darwin.getaddrinfo($0, nil, &hints, &result) }
                defer { if let result { Darwin.freeaddrinfo(result) } }
                guard code == 0, let result else {
                    continuation.resume(throwing: EchoLinkRelayClientError.resolutionFailed)
                    return
                }
                var addresses: [String] = []
                var seen: Set<String> = []
                var current: UnsafeMutablePointer<addrinfo>? = result
                while let entry = current {
                    defer { current = entry.pointee.ai_next }
                    guard entry.pointee.ai_family == AF_INET,
                          let socketAddress = entry.pointee.ai_addr else { continue }
                    var address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee.sin_addr
                    }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    let converted = buffer.withUnsafeMutableBufferPointer {
                        Darwin.inet_ntop(AF_INET, &address, $0.baseAddress, socklen_t($0.count))
                    }
                    guard converted != nil else { continue }
                    let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
                    let ip = String(decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if seen.insert(ip).inserted { addresses.append(ip) }
                }
                guard !addresses.isEmpty else {
                    continuation.resume(throwing: EchoLinkRelayClientError.resolutionFailed)
                    return
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}
