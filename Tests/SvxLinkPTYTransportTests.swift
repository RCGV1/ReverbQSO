// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest
@testable import ReverbQSO

final class SvxLinkPTYTransportTests: XCTestCase {
    func testCommandsUseOnlyTheirConfiguredPTYs() async throws {
        let module = try TestPTY()
        let logic = try TestPTY()
        let dtmf = try TestPTY()
        let state = try TestPTY()
        let transport = SvxLinkPTYTransport(paths: .init(
            moduleCommand: module.path, logicCommand: logic.path,
            dtmfControl: dtmf.path, state: state.path
        ))

        try await transport.killTalker()
        XCTAssertEqual(try module.read(), Data("KILL\n".utf8))
        try await transport.disconnect(callsign: "n0call-l")
        XCTAssertEqual(try module.read(), Data("DISC N0CALL-L\n".utf8))
        try await transport.setOnline(logicName: "RepeaterLogic", online: false)
        XCTAssertEqual(try logic.read(), Data("CFG RepeaterLogic ONLINE 0\n".utf8))
        try await transport.sendDTMF("*1#")
        XCTAssertEqual(try dtmf.read(), Data("*1#\n".utf8))
        XCTAssertFalse(try state.hasData())
    }

    func testStateReaderHandlesFragmentsAndDiscardsOversizedLine() async throws {
        let pty = try TestPTY()
        let transport = SvxLinkPTYTransport(paths: .init(
            moduleCommand: pty.path, logicCommand: pty.path,
            dtmfControl: pty.path, state: pty.path
        ))
        let stream = try await transport.startStates()

        try pty.write(Data("1727550000.123 Tx:sta".utf8))
        try pty.write(Data("te {\"id\":\"T\",\"name\":\"Tx1\",\"transmit\":true}\n".utf8))
        let first = try await nextState(from: stream)
        XCTAssertEqual(first?.event, .transmitter(.init(id: "T", name: "Tx1", isTransmitting: true)))

        let oversized = "1727550000.123 EchoLink:peer " + String(repeating: "X", count: 5000) + "\n"
        try pty.write(Data(oversized.utf8))
        try pty.write(Data("1727550000.456 Tx:state {\"id\":\"T\",\"name\":\"Tx1\",\"transmit\":false}\n".utf8))
        let second = try await nextState(from: stream)
        XCTAssertEqual(second?.event, .transmitter(.init(id: "T", name: "Tx1", isTransmitting: false)))

        await transport.stopStates()
        let finished = try await nextState(from: stream)
        XCTAssertNil(finished)
    }

    func testRejectsRegularFileAndDuplicateMonitoring() async throws {
        let pty = try TestPTY()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let badTransport = SvxLinkPTYTransport(paths: .init(
            moduleCommand: file.path, logicCommand: file.path,
            dtmfControl: file.path, state: file.path
        ))
        do {
            try await badTransport.killTalker()
            XCTFail("Regular files must not receive control commands")
        } catch SvxLinkPTYTransportError.notPTY { }

        let transport = SvxLinkPTYTransport(paths: .init(
            moduleCommand: pty.path, logicCommand: pty.path,
            dtmfControl: pty.path, state: pty.path
        ))
        let activeStream = try await transport.startStates()
        do {
            _ = try await transport.startStates()
            XCTFail("A second state reader must be rejected")
        } catch SvxLinkPTYTransportError.alreadyMonitoring { }
        _ = activeStream
        await transport.stopStates()
    }
}

private final class TestPTY: @unchecked Sendable {
    let path: String
    private let master: Int32
    private let slave: Int32

    init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 1024)
        guard Darwin.openpty(&master, &slave, &name, nil, nil) == 0 else {
            throw POSIXError(.EIO)
        }
        var settings = termios()
        guard Darwin.tcgetattr(slave, &settings) == 0 else {
            Darwin.close(master)
            Darwin.close(slave)
            throw POSIXError(.EIO)
        }
        Darwin.cfmakeraw(&settings)
        guard Darwin.tcsetattr(slave, TCSANOW, &settings) == 0 else {
            Darwin.close(master)
            Darwin.close(slave)
            throw POSIXError(.EIO)
        }
        self.master = master
        self.slave = slave
        let terminator = name.firstIndex(of: 0) ?? name.endIndex
        self.path = String(decoding: name[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    deinit {
        Darwin.close(slave)
        Darwin.close(master)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(master, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }

    func read() throws -> Data {
        var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&descriptor, 1, 1000) > 0 else { throw POSIXError(.ETIMEDOUT) }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = Darwin.read(master, &bytes, bytes.count)
        guard count > 0 else { throw POSIXError(.EIO) }
        return Data(bytes.prefix(count))
    }

    func hasData() throws -> Bool {
        var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        let result = Darwin.poll(&descriptor, 1, 20)
        guard result >= 0 else { throw POSIXError(.EIO) }
        return result > 0 && descriptor.revents & Int16(POLLIN) != 0
    }
}

private struct StateReadTimeout: Error {}

private func nextState(
    from stream: AsyncThrowingStream<SvxLinkStateLine, Error>,
    timeout: Duration = .seconds(2)
) async throws -> SvxLinkStateLine? {
    try await withThrowingTaskGroup(of: SvxLinkStateLine?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw StateReadTimeout()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw StateReadTimeout() }
        return first
    }
}
