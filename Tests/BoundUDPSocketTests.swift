// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest
@testable import ReverbQSO

final class BoundUDPSocketTests: XCTestCase {
    func testPortZeroExposesAssignedLocalPort() throws {
        let socket = try BoundUDPSocket(localPort: 0)
        defer { socket.close() }

        XCTAssertNotEqual(socket.actualLocalPort, 0)
    }

    func testExactPortBindAndExclusiveOwnership() throws {
        let reservation = try BoundUDPSocket(localPort: 0)
        let fixedPort = reservation.actualLocalPort
        reservation.close()

        let socket = try BoundUDPSocket(localPort: fixedPort)
        defer { socket.close() }

        XCTAssertEqual(socket.actualLocalPort, fixedPort)
        XCTAssertThrowsError(try BoundUDPSocket(localPort: fixedPort))
    }

    func testReceiveReturnsLoopbackDatagram() async throws {
        let receiver = try BoundUDPSocket(localPort: 0)
        let sender = try BoundUDPSocket(localPort: 0)
        defer {
            sender.close()
            receiver.close()
        }

        let payload = Data("EchoLink loopback".utf8)
        try await sender.send(payload, to: "127.0.0.1", port: receiver.actualLocalPort)

        let datagram = try await receiver.receive()
        XCTAssertEqual(datagram.data, payload)
        XCTAssertEqual(datagram.sourceHost, "127.0.0.1")
        XCTAssertEqual(datagram.sourcePort, sender.actualLocalPort)
    }

    func testOneBoundSocketKeepsSourcePortAcrossRemotePorts() async throws {
        let firstReceiver = try RawIPv4UDPSocket()
        let secondReceiver = try RawIPv4UDPSocket()
        let sender = try BoundUDPSocket(localPort: 0)
        defer { sender.close() }

        let firstPayload = Data([0x51, 0x53, 0x4F, 0x31])
        let secondPayload = Data([0x51, 0x53, 0x4F, 0x32])

        try await sender.send(firstPayload, to: "127.0.0.1", port: firstReceiver.localPort)
        try await sender.send(secondPayload, to: "127.0.0.1", port: secondReceiver.localPort)

        let firstDatagram = try firstReceiver.receive()
        let secondDatagram = try secondReceiver.receive()
        XCTAssertEqual(firstDatagram.data, firstPayload)
        XCTAssertEqual(secondDatagram.data, secondPayload)
        XCTAssertEqual(firstDatagram.sourcePort, sender.actualLocalPort)
        XCTAssertEqual(secondDatagram.sourcePort, sender.actualLocalPort)
    }

    func testCloseIsIdempotentAndUnblocksReceive() async throws {
        let socket = try BoundUDPSocket(localPort: 0)
        let receiveTask = Task {
            try await socket.receive()
        }

        await Task.yield()
        socket.close()
        socket.close()

        do {
            _ = try await receiveTask.value
            XCTFail("Expected close to unblock receive with an error")
        } catch let error as BoundUDPSocket.SocketError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testENOTCONNFromRecvfromIsTransient() {
        let error = BoundUDPSocket.SocketError.systemCall(
            operation: "recvfrom",
            code: ENOTCONN
        )

        XCTAssertTrue(error.isTransientReceiveFailure)
        XCTAssertFalse(BoundUDPSocket.SocketError.closed.isTransientReceiveFailure)
        XCTAssertFalse(
            BoundUDPSocket.SocketError.systemCall(
                operation: "sendto",
                code: ENOTCONN
            ).isTransientReceiveFailure
        )
    }
}

private final class RawIPv4UDPSocket {
    struct Datagram {
        let data: Data
        let sourcePort: UInt16
    }

    let localPort: UInt16
    private let descriptor: Int32

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor {
                Darwin.close(descriptor)
            }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(descriptor, socketAddress, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        self.descriptor = descriptor
        self.localPort = UInt16(bigEndian: boundAddress.sin_port)
        shouldCloseDescriptor = false
    }

    deinit {
        Darwin.close(descriptor)
    }

    func receive(maximumBytes: Int = 65_536) throws -> Datagram {
        var data = Data(count: maximumBytes)
        var sourceAddress = sockaddr_in()
        var sourceAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)

        let receivedCount = data.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &sourceAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.recvfrom(
                        descriptor,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        socketAddress,
                        &sourceAddressLength
                    )
                }
            }
        }
        guard receivedCount >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        data.removeSubrange(Int(receivedCount)..<data.count)
        return Datagram(
            data: data,
            sourcePort: UInt16(bigEndian: sourceAddress.sin_port)
        )
    }
}
