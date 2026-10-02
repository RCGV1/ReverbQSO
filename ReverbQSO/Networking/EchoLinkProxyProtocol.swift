// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Darwin
import Foundation

struct EchoLinkProxyMessage: Equatable, Sendable {
    enum MessageType: UInt8, Equatable, Sendable {
        case tcpOpen = 1
        case tcpData = 2
        case tcpClose = 3
        case tcpStatus = 4
        case udpData = 5
        case udpControl = 6
        case system = 7
    }

    enum SystemEvent: Equatable, Sendable {
        case badPassword
        case accessDenied
        case unknown(UInt8)
    }

    let type: MessageType
    let remoteHost: String
    let payload: Data

    var systemEvent: SystemEvent? {
        guard type == .system, payload.count == 1, let code = payload.first else { return nil }
        switch code {
        case 1: return .badPassword
        case 2: return .accessDenied
        default: return .unknown(code)
        }
    }
}

enum EchoLinkProxyProtocol {
    enum ProtocolError: Swift.Error, Equatable, LocalizedError {
        case invalidNonceLength(Int)
        case invalidRemoteHost(String)
        case invalidMessageType(UInt8)
        case payloadTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .invalidNonceLength(let count):
                return "EchoLink Proxy sent a \(count)-byte challenge; expected 8 bytes."
            case .invalidRemoteHost(let host):
                return "EchoLink Proxy requires a numeric IPv4 peer address; received \(host)."
            case .invalidMessageType(let type):
                return "EchoLink Proxy sent unsupported message type \(type)."
            case .payloadTooLarge(let count):
                return "EchoLink Proxy payload is too large (\(count) bytes)."
            }
        }
    }

    static let headerSize = 9
    static let maximumPayloadSize = 5_000

    static func authenticationResponse(
        callsign: String,
        password: String,
        nonce: Data
    ) throws -> Data {
        guard nonce.count == 8 else {
            throw ProtocolError.invalidNonceLength(nonce.count)
        }

        let normalizedCallsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedPassword = password.uppercased()
        var digestInput = Data(normalizedPassword.utf8)
        digestInput.append(nonce)

        var response = Data(normalizedCallsign.utf8)
        response.append(0x0A)
        response.append(contentsOf: Insecure.MD5.hash(data: digestInput))
        return response
    }

    static func encode(
        type: EchoLinkProxyMessage.MessageType,
        remoteHost: String,
        payload: Data
    ) throws -> Data {
        guard payload.count <= maximumPayloadSize else {
            throw ProtocolError.payloadTooLarge(payload.count)
        }

        var address = in_addr()
        guard inet_pton(AF_INET, remoteHost, &address) == 1 else {
            throw ProtocolError.invalidRemoteHost(remoteHost)
        }

        var frame = Data([type.rawValue])
        withUnsafeBytes(of: address.s_addr) { frame.append(contentsOf: $0) }
        let length = UInt32(payload.count)
        frame.append(UInt8(length & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(payload)
        return frame
    }

    static func parseAvailableMessages(from buffer: inout Data) throws -> [EchoLinkProxyMessage] {
        var messages: [EchoLinkProxyMessage] = []

        while let message = try parseNextMessage(from: &buffer) {
            messages.append(message)
        }
        return messages
    }

    /// Consume one complete frame so callers can deliver it before inspecting
    /// a following header that might terminate the stream.
    static func parseNextMessage(from buffer: inout Data) throws -> EchoLinkProxyMessage? {
        guard buffer.count >= headerSize else { return nil }
        let header = [UInt8](buffer.prefix(headerSize))
        guard let type = EchoLinkProxyMessage.MessageType(rawValue: header[0]) else {
            throw ProtocolError.invalidMessageType(header[0])
        }
        let payloadLength = Int(header[5])
            | (Int(header[6]) << 8)
            | (Int(header[7]) << 16)
            | (Int(header[8]) << 24)
        guard payloadLength <= maximumPayloadSize else {
            throw ProtocolError.payloadTooLarge(payloadLength)
        }
        let frameLength = headerSize + payloadLength
        guard buffer.count >= frameLength else { return nil }

        var address = in_addr()
        withUnsafeMutableBytes(of: &address.s_addr) { destination in
            destination.copyBytes(from: header[1...4])
        }
        var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &hostBuffer, socklen_t(INET_ADDRSTRLEN))
        let remoteHost = String(cString: hostBuffer)
        // Data can retain a non-zero startIndex after removeFirst. Work in
        // offsets so concatenated frames never subscript with invalid indices.
        let payload = Data(buffer.dropFirst(headerSize).prefix(payloadLength))
        buffer = Data(buffer.dropFirst(frameLength))
        return EchoLinkProxyMessage(type: type, remoteHost: remoteHost, payload: payload)
    }
}
