// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

struct SvxLinkPTYPaths: Sendable {
    let moduleCommand: String
    let logicCommand: String
    let dtmfControl: String
    let state: String
}

enum SvxLinkPTYTransportError: LocalizedError {
    case invalidPath
    case alreadyMonitoring
    case notPTY
    case disconnected
    case systemCall(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Configure an absolute path to the SvxLink PTY."
        case .alreadyMonitoring:
            return "SvxLink state monitoring is already active."
        case .notPTY:
            return "The configured SvxLink path is not a PTY device. Check the node configuration."
        case .disconnected:
            return "The SvxLink state PTY disconnected. Check that SvxLink is running."
        case .systemCall(let operation, let code):
            return "SvxLink PTY \(operation) failed: \(String(cString: strerror(code)))."
        }
    }
}

/// Local PTY adapter. SvxLink owns EchoLink networking, radio audio, and PTT.
actor SvxLinkPTYTransport {
    private let paths: SvxLinkPTYPaths
    private let stateQueue = DispatchQueue(label: "org.reverbqso.app.svxlink-state")
    private var stateSource: DispatchSourceRead?
    private var stateDescriptor: Int32?
    private var stateContinuation: AsyncThrowingStream<SvxLinkStateLine, Error>.Continuation?
    private var lineBuffer: [UInt8] = []
    private var discardingOversizedLine = false

    init(paths: SvxLinkPTYPaths) {
        self.paths = paths
    }

    deinit {
        stateSource?.cancel()
    }

    func killTalker() throws {
        try Self.write(SvxLinkCommandEncoder.killTalker(), to: paths.moduleCommand)
    }

    func disconnect(callsign: String) throws {
        try Self.write(SvxLinkCommandEncoder.disconnect(callsign: callsign), to: paths.moduleCommand)
    }

    func setOnline(logicName: String, online: Bool) throws {
        try Self.write(SvxLinkCommandEncoder.setOnline(logicName: logicName, online: online), to: paths.logicCommand)
    }

    func sendDTMF(_ digits: String) throws {
        try Self.write(SvxLinkCommandEncoder.dtmf(digits), to: paths.dtmfControl)
    }

    func startStates() throws -> AsyncThrowingStream<SvxLinkStateLine, Error> {
        guard stateSource == nil else { throw SvxLinkPTYTransportError.alreadyMonitoring }
        let descriptor = try Self.openPTY(paths.state, flags: O_RDONLY | O_NONBLOCK)
        let (stream, continuation) = AsyncThrowingStream<SvxLinkStateLine, Error>.makeStream()
        stateDescriptor = descriptor
        stateContinuation = continuation
        lineBuffer.removeAll(keepingCapacity: true)
        discardingOversizedLine = false

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: stateQueue)
        source.setEventHandler { [weak self] in
            Task { await self?.drainState() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        stateSource = source
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopStates() }
        }
        source.resume()
        return stream
    }

    func stopStates() {
        let source = stateSource
        stateSource = nil
        stateDescriptor = nil
        lineBuffer.removeAll(keepingCapacity: false)
        discardingOversizedLine = false
        let continuation = stateContinuation
        stateContinuation = nil
        source?.cancel()
        continuation?.finish()
    }

    private func drainState() {
        guard let descriptor = stateDescriptor else { return }
        var bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                appendStateBytes(bytes.prefix(count))
            } else if count == 0 {
                failState(SvxLinkPTYTransportError.disconnected)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                failState(SvxLinkPTYTransportError.systemCall(operation: "read", code: errno))
                return
            }
        }
    }

    private func appendStateBytes(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            if discardingOversizedLine {
                if byte == 10 { discardingOversizedLine = false }
                continue
            }
            if lineBuffer.count >= SvxLinkStateParser.maxLineBytes {
                lineBuffer.removeAll(keepingCapacity: true)
                discardingOversizedLine = byte != 10
                continue
            }
            lineBuffer.append(byte)
            guard byte == 10 else { continue }
            if let line = String(bytes: lineBuffer, encoding: .utf8),
               let event = SvxLinkStateParser.parse(line) {
                stateContinuation?.yield(event)
            }
            lineBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func failState(_ error: Error) {
        let source = stateSource
        stateSource = nil
        stateDescriptor = nil
        lineBuffer.removeAll(keepingCapacity: false)
        discardingOversizedLine = false
        let continuation = stateContinuation
        stateContinuation = nil
        source?.cancel()
        continuation?.finish(throwing: error)
    }

    private nonisolated static func write(_ data: Data, to path: String) throws {
        let descriptor = try openPTY(path, flags: O_WRONLY | O_NONBLOCK)
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    throw SvxLinkPTYTransportError.systemCall(operation: "write", code: count < 0 ? errno : EIO)
                }
            }
        }
    }

    private nonisolated static func openPTY(_ path: String, flags: Int32) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw SvxLinkPTYTransportError.invalidPath
        }
        let descriptor = path.withCString { Darwin.open($0, flags | O_NOCTTY | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw SvxLinkPTYTransportError.systemCall(operation: "open", code: errno)
        }
        // isatty validates the opened descriptor itself. No filesystem metadata
        // (including file timestamps) is needed to identify a terminal.
        guard Darwin.isatty(descriptor) == 1 else {
            Darwin.close(descriptor)
            throw SvxLinkPTYTransportError.notPTY
        }
        return descriptor
    }
}
