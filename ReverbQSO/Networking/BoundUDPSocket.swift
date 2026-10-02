// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// An IPv4 UDP socket whose outbound datagrams retain one explicitly bound source port.
final class BoundUDPSocket: @unchecked Sendable {
    enum SocketError: Swift.Error, Equatable, LocalizedError, Sendable {
        case closed
        case invalidHost(String)
        case invalidPort(UInt16)
        case invalidMaximumBytes(Int)
        case datagramTooLarge(Int)
        case systemCall(operation: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .closed:
                return "The UDP socket is closed."
            case .invalidHost(let host):
                return "Invalid numeric IPv4 address: \(host)"
            case .invalidPort(let port):
                return "Invalid remote UDP port: \(port)"
            case .invalidMaximumBytes(let count):
                return "Receive size must be between 1 and 65,536 bytes; received \(count)."
            case .datagramTooLarge(let count):
                return "IPv4 UDP datagrams cannot exceed 65,507 bytes; received \(count)."
            case .systemCall(let operation, let code):
                return "\(operation) failed (errno \(code)): \(String(cString: strerror(code)))"
            }
        }

        var isTransientReceiveFailure: Bool {
            guard case .systemCall(let operation, let code) = self else { return false }
            return operation == "recvfrom" && code == ENOTCONN
        }
    }

    struct Datagram: Equatable, Sendable {
        let data: Data
        let sourceHost: String
        let sourcePort: UInt16
    }

    let actualLocalPort: UInt16

    private struct PendingReceive {
        let id: UUID
        let maximumBytes: Int
        let continuation: CheckedContinuation<Datagram, Swift.Error>
    }

    private static let maximumIPv4UDPPayload = 65_507
    private static let maximumReceiveSize = 65_536

    private let descriptor: Int32
    private let ioQueue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let descriptorCloseGroup: DispatchGroup
    private var readSource: DispatchSourceRead?
    private var pendingReceives: [PendingReceive] = []
    private var cancelledReceiveIDs: Set<UUID> = []
    private var isClosed = false

    init(localPort: UInt16) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw SocketError.systemCall(operation: "socket", code: errno)
        }

        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor {
                Darwin.close(descriptor)
            }
        }

        var localAddress = sockaddr_in()
        localAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddress.sin_family = sa_family_t(AF_INET)
        localAddress.sin_port = localPort.bigEndian
        localAddress.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.bind(descriptor, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw SocketError.systemCall(operation: "bind", code: errno)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.getsockname(descriptor, address, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            throw SocketError.systemCall(operation: "getsockname", code: errno)
        }

        let currentFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard currentFlags >= 0 else {
            throw SocketError.systemCall(operation: "fcntl(F_GETFL)", code: errno)
        }
        guard Darwin.fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            throw SocketError.systemCall(operation: "fcntl(F_SETFL)", code: errno)
        }

        let descriptorCloseGroup = DispatchGroup()
        descriptorCloseGroup.enter()

        self.descriptor = descriptor
        self.actualLocalPort = UInt16(bigEndian: boundAddress.sin_port)
        self.ioQueue = DispatchQueue(label: "org.reverbqso.app.bound-udp.\(descriptor)")
        self.descriptorCloseGroup = descriptorCloseGroup
        self.ioQueue.setSpecific(key: queueKey, value: 1)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.drainPendingReceives()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
            descriptorCloseGroup.leave()
        }
        self.readSource = source

        shouldCloseDescriptor = false
        source.resume()
    }

    deinit {
        close()
    }

    func send(_ data: Data, to host: String, port: UInt16) async throws {
        guard port != 0 else {
            throw SocketError.invalidPort(port)
        }
        guard data.count <= Self.maximumIPv4UDPPayload else {
            throw SocketError.datagramTooLarge(data.count)
        }

        let endpoint = try Self.makeIPv4Address(host: host, port: port)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            ioQueue.async {
                guard !self.isClosed else {
                    continuation.resume(throwing: SocketError.closed)
                    return
                }

                var destination = endpoint
                let sentCount = data.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &destination) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                            Darwin.sendto(
                                self.descriptor,
                                bytes.baseAddress,
                                bytes.count,
                                0,
                                address,
                                socklen_t(MemoryLayout<sockaddr_in>.size)
                            )
                        }
                    }
                }

                guard sentCount >= 0 else {
                    continuation.resume(
                        throwing: SocketError.systemCall(operation: "sendto", code: errno)
                    )
                    return
                }
                guard sentCount == data.count else {
                    continuation.resume(
                        throwing: SocketError.systemCall(operation: "sendto", code: EMSGSIZE)
                    )
                    return
                }

                continuation.resume()
            }
        }
    }

    func receive(maximumBytes: Int = 65_536) async throws -> Datagram {
        guard (1...Self.maximumReceiveSize).contains(maximumBytes) else {
            throw SocketError.invalidMaximumBytes(maximumBytes)
        }

        let receiveID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                ioQueue.async {
                    if self.cancelledReceiveIDs.remove(receiveID) != nil {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard !self.isClosed else {
                        continuation.resume(throwing: SocketError.closed)
                        return
                    }

                    self.pendingReceives.append(
                        PendingReceive(
                            id: receiveID,
                            maximumBytes: maximumBytes,
                            continuation: continuation
                        )
                    )
                    self.drainPendingReceives()
                }
            }
        } onCancel: {
            self.ioQueue.async {
                self.cancelReceive(id: receiveID)
            }
        }
    }

    func close() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeOnIOQueue()
        } else {
            ioQueue.sync {
                closeOnIOQueue()
            }
            descriptorCloseGroup.wait()
        }
    }

    private func drainPendingReceives() {
        guard !isClosed else { return }

        while let request = pendingReceives.first {
            var data = Data(count: request.maximumBytes)
            var sourceAddress = sockaddr_in()
            var sourceAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let receivedCount = data.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &sourceAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        Darwin.recvfrom(
                            descriptor,
                            bytes.baseAddress,
                            bytes.count,
                            0,
                            address,
                            &sourceAddressLength
                        )
                    }
                }
            }

            if receivedCount >= 0 {
                pendingReceives.removeFirst()
                data.removeSubrange(Int(receivedCount)..<data.count)
                do {
                    request.continuation.resume(
                        returning: try Self.makeDatagram(data: data, sourceAddress: sourceAddress)
                    )
                } catch {
                    request.continuation.resume(throwing: error)
                }
                continue
            }

            let receiveError = errno
            if receiveError == EINTR {
                continue
            }
            if receiveError == EAGAIN || receiveError == EWOULDBLOCK {
                return
            }

            pendingReceives.removeFirst()
            request.continuation.resume(
                throwing: SocketError.systemCall(operation: "recvfrom", code: receiveError)
            )
        }
    }

    private func cancelReceive(id: UUID) {
        if let index = pendingReceives.firstIndex(where: { $0.id == id }) {
            let request = pendingReceives.remove(at: index)
            request.continuation.resume(throwing: CancellationError())
        } else if !isClosed {
            cancelledReceiveIDs.insert(id)
        }
    }

    private func closeOnIOQueue() {
        guard !isClosed else { return }
        isClosed = true

        let receives = pendingReceives
        pendingReceives.removeAll()
        cancelledReceiveIDs.removeAll()
        readSource?.cancel()

        for request in receives {
            request.continuation.resume(throwing: SocketError.closed)
        }
    }

    private static func makeIPv4Address(host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian

        let conversionResult = host.withCString { hostPointer in
            Darwin.inet_pton(AF_INET, hostPointer, &address.sin_addr)
        }
        guard conversionResult == 1 else {
            throw SocketError.invalidHost(host)
        }

        return address
    }

    private static func makeDatagram(data: Data, sourceAddress: sockaddr_in) throws -> Datagram {
        guard sourceAddress.sin_family == sa_family_t(AF_INET) else {
            throw SocketError.systemCall(operation: "recvfrom address family", code: EAFNOSUPPORT)
        }

        var address = sourceAddress.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let converted = buffer.withUnsafeMutableBufferPointer { pointer in
            Darwin.inet_ntop(
                AF_INET,
                &address,
                pointer.baseAddress,
                socklen_t(pointer.count)
            )
        }
        guard converted != nil else {
            throw SocketError.systemCall(operation: "inet_ntop", code: errno)
        }

        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let sourceHost = String(
            decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )

        return Datagram(
            data: data,
            sourceHost: sourceHost,
            sourcePort: UInt16(bigEndian: sourceAddress.sin_port)
        )
    }
}
