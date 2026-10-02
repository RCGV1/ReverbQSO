// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import Network

/// A login's transport choice. The saved preference is never replaced by this value.
struct EchoLinkEffectiveTransport: Equatable, Sendable {
    let preference: EchoLinkProxyConfiguration
    let configuration: EchoLinkProxyConfiguration
    let relayAddress: String?

    static func explicit(_ preference: EchoLinkProxyConfiguration) -> Self {
        Self(preference: preference, configuration: preference, relayAddress: nil)
    }
}

struct EchoLinkAutomaticTransportSelector: Sendable {
    var localAddresses: @Sendable () -> [String] = Self.activeLocalAddresses
    var discoverRelays: @Sendable () async throws -> [String] = {
        try await EchoLinkRelayDiscovery().run()
    }
    var chooseRelay: @Sendable ([String]) -> String? = { $0.randomElement() }

    func select(_ preference: EchoLinkProxyConfiguration) async throws -> EchoLinkEffectiveTransport {
        try Task.checkCancellation()
        guard preference.mode == .automatic else { return .explicit(preference) }
        let mode: EchoLinkNetworkMode
        var relay: String?
        // Direct QSO sockets and station endpoints are IPv4. A public IPv6
        // interface alone does not make inbound IPv4 EchoLink reachable.
        if localAddresses().contains(where: Self.isGlobalDirectIPv4Address) {
            mode = .direct
        } else {
            let candidates: [String]
            do { candidates = try await discoverRelays().filter(Self.isUsableRelayIPv4) }
            catch is CancellationError { throw CancellationError() }
            catch { candidates = [] }
            try Task.checkCancellation()
            relay = chooseRelay(candidates)
            if let selected = relay, !candidates.contains(selected) { relay = nil }
            mode = relay == nil ? .publicProxy : .relay
        }
        try Task.checkCancellation()
        let effective = EchoLinkProxyConfiguration(
            mode: mode, host: preference.host, port: preference.port,
            password: mode == .publicProxy ? "PUBLIC" : ""
        )
        return EchoLinkEffectiveTransport(preference: preference, configuration: effective, relayAddress: relay)
    }

    static func isUsableRelayIPv4(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        return value != 0 && value != UInt32.max && (value >> 28) != 0xE
    }

    static func isGlobalDirectIPv4Address(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let a = value >> 24
            let b = (value >> 16) & 255
            return a != 0 && a != 10 && a != 127 && a < 224
                && !(a == 100 && (64...127).contains(b))
                && !(a == 169 && b == 254)
                && !(a == 172 && (16...31).contains(b))
                && !(a == 192 && b == 168)
                && !(a == 192 && b == 0 && ((value >> 8) & 255) == 0)
                && !(a == 198 && (18...19).contains(b))
                && !(a == 192 && b == 0 && ((value >> 8) & 255) == 2)
                && !(a == 198 && b == 51 && ((value >> 8) & 255) == 100)
                && !(a == 203 && b == 0 && ((value >> 8) & 255) == 113)
        }
        return false
    }

    static func activeLocalAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var result: [String] = []
        var cursor = interfaces
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let flags = interface.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))
            }
        }
        return result
    }
}

/// DNS and all UDP probes share one deadline. State is confined to queue;
/// cancellation also resumes the caller if DNS is still blocked in the OS.
final class EchoLinkRelayDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EchoLinkRelayDiscovery")
    private var continuation: CheckedContinuation<[String], Error>?
    private var connections: [NWConnection] = []
    private var responders = Set<String>()
    private var finished = false
    private let resolve: @Sendable () -> [String]
    private let timeout: TimeInterval
    private let port: UInt16

    init(timeout: TimeInterval = 4, port: UInt16 = EchoLinkRelayProtocol.port,
         resolve: @escaping @Sendable () -> [String] = EchoLinkRelayDiscovery.resolveRelayAddresses) {
        self.timeout = timeout
        self.port = port
        self.resolve = resolve
    }

    func run() async throws -> [String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.finished else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    self.queue.asyncAfter(deadline: .now() + self.timeout) { self.finish() }
                    DispatchQueue.global(qos: .utility).async {
                        let hosts = self.resolve()
                        self.queue.async {
                            guard !self.finished else { return }
                            guard !hosts.isEmpty else { self.finish(); return }
                            for host in hosts { self.probe(host) }
                        }
                    }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(error: CancellationError()) }
        }
    }

    private func probe(_ host: String) {
        let connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .udp)
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            if case .ready = state {
                connection.send(content: EchoLinkRelayProtocol.discoveryPing, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.finished, error == nil else { return }
                    self.receive(connection, host: host)
                })
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, host: String) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.finished else { return }
            if let data, let address = EchoLinkRelayProtocol.discoveryRelayAddress(data, responder: host) {
                self.responders.insert(address)
            }
            if error == nil { self.receive(connection, host: host) }
        }
    }

    private func finish(error: Error? = nil) {
        guard !finished else { return }
        finished = true
        for connection in connections { connection.cancel() }
        connections.removeAll()
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: responders.sorted()) }
        continuation = nil
    }

    static func resolveRelayAddresses() -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(EchoLinkRelayProtocol.host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var cursor = result
        var hosts = Set<String>()
        while let entry = cursor {
            defer { cursor = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, entry.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                hosts.insert(String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))
            }
        }
        return hosts.sorted()
    }
}
