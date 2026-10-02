// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum EchoLinkRelayRequestType: UInt8, Sendable {
    case keepalive = 0
    case data = 1
    case close = 2
    case register = 3
    case unregister = 4
    case dropFlow = 5
    case ping = 6
}

enum EchoLinkRelayResponseType: UInt8, Sendable {
    case data = 1
    case error = 2
    case ping = 3
    case ack = 4
}

enum EchoLinkRelayErrorCode: UInt8, Sendable {
    case allocationFailure = 1
}

enum EchoLinkRelayProtocolError: Error, Equatable, Sendable {
    case invalidAddress
    case invalidPort
    case invalidCallsign
    case invalidFields
    case truncatedDatagram
    case oversizedDatagram
    case unsupportedType
    case unsupportedErrorCode
}

struct EchoLinkRelayResponse: Equatable, Sendable {
    let type: EchoLinkRelayResponseType
    let sourceHost: String
    let sourcePort: UInt16
    /// Local media port selected by the relay (5198 audio, 5199 control).
    let destinationPort: UInt16
    let payload: Data
    let errorCode: EchoLinkRelayErrorCode?
}

/// Stateless wire codec for the EchoLink Relay UDP 7000 envelope.
enum EchoLinkRelayProtocol {
    static let host = "relay.echolink.org"
    static let port: UInt16 = 7000
    /// Relay servers discard request payloads above 1500 bytes (elproxy MAX_PACKET_DATA).
    static let maxPayloadBytes = 1500
    static let maxDatagramBytes = 65_507 // Maximum IPv4 UDP payload.

    static let discoveryPing = Data([6, 0, 0, 0, 0, 0, 0, 0, 0])

    static func discoveryRelayAddress(_ data: Data, responder: String) -> String? {
        guard data.count >= 9, data.first == EchoLinkRelayResponseType.ping.rawValue else { return nil }
        if EchoLinkAutomaticTransportSelector.isUsableRelayIPv4(responder) { return responder }
        guard let fields = String(data: data.dropFirst(9), encoding: .utf8) else { return nil }
        for line in fields.components(separatedBy: "\r\n") {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "ipv4" else { continue }
            let address = pair[1].trimmingCharacters(in: .whitespaces)
            if EchoLinkAutomaticTransportSelector.isUsableRelayIPv4(address) { return address }
        }
        return nil
    }

    static func encodeRequest(
        type: EchoLinkRelayRequestType,
        destinationHost: String,
        destinationPort: UInt16,
        payload: Data = Data()
    ) throws -> Data {
        guard let address = parseIPv4(destinationHost) else {
            throw EchoLinkRelayProtocolError.invalidAddress
        }
        guard payload.count <= maxPayloadBytes else {
            throw EchoLinkRelayProtocolError.oversizedDatagram
        }
        if type == .data && destinationPort != 5198 && destinationPort != 5199 {
            throw EchoLinkRelayProtocolError.invalidPort
        }
        if type == .register || type == .unregister {
            guard address == [0, 0, 0, 0], destinationPort == 0,
                  isValidRegistrationPayload(payload) else {
                throw EchoLinkRelayProtocolError.invalidFields
            }
        }

        var datagram = Data(capacity: 7 + payload.count)
        datagram.append(type.rawValue)
        datagram.append(contentsOf: address)
        datagram.append(UInt8(destinationPort >> 8))
        datagram.append(UInt8(destinationPort & 0xFF))
        datagram.append(payload)
        return datagram
    }

    static func register(callsign: String) throws -> Data {
        try registrationRequest(type: .register, callsign: callsign)
    }

    static func unregister(callsign: String) throws -> Data {
        try registrationRequest(type: .unregister, callsign: callsign)
    }

    static func dropFlow(destinationHost: String, destinationPort: UInt16, callsign: String) throws -> Data {
        let payload = try callsignPayload(callsign)
        return try encodeRequest(type: .dropFlow, destinationHost: destinationHost,
                                 destinationPort: destinationPort, payload: payload)
    }

    static func decodeResponse(_ datagram: Data) throws -> EchoLinkRelayResponse {
        guard datagram.count >= 9 else { throw EchoLinkRelayProtocolError.truncatedDatagram }
        guard datagram.count <= maxDatagramBytes else { throw EchoLinkRelayProtocolError.oversizedDatagram }
        let bytes = Array(datagram)
        guard let type = EchoLinkRelayResponseType(rawValue: bytes[0]) else {
            throw EchoLinkRelayProtocolError.unsupportedType
        }
        let sourceHost = bytes[1...4].map(String.init).joined(separator: ".")
        let sourcePort = (UInt16(bytes[5]) << 8) | UInt16(bytes[6])
        let destinationPort = (UInt16(bytes[7]) << 8) | UInt16(bytes[8])
        let payload = Data(bytes.dropFirst(9))
        if type == .data && destinationPort != 5198 && destinationPort != 5199 {
            throw EchoLinkRelayProtocolError.invalidPort
        }

        var errorCode: EchoLinkRelayErrorCode?
        if type == .error {
            guard payload.count == 1 else { throw EchoLinkRelayProtocolError.invalidFields }
            guard let code = EchoLinkRelayErrorCode(rawValue: payload[0]) else {
                throw EchoLinkRelayProtocolError.unsupportedErrorCode
            }
            errorCode = code
        }
        return EchoLinkRelayResponse(
            type: type,
            sourceHost: sourceHost,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: payload,
            errorCode: errorCode
        )
    }

    private static func registrationRequest(type: EchoLinkRelayRequestType, callsign: String) throws -> Data {
        let payload = try callsignPayload(callsign)
        return try encodeRequest(type: type, destinationHost: "0.0.0.0", destinationPort: 0, payload: payload)
    }

    private static func callsignPayload(_ callsign: String) throws -> Data {
        let bytes = Array(callsign.utf8)
        guard !bytes.isEmpty, bytes.count <= 15,
              bytes.allSatisfy({ isASCIIAlphanumeric($0) || $0 == 45 }) else {
            throw EchoLinkRelayProtocolError.invalidCallsign
        }
        let uppercase = bytes.map { (97...122).contains($0) ? $0 - 32 : $0 }
        // A relay ACK does not prove registration: the server silently rejects
        // callsigns without both a letter and a digit before sending its ACK.
        guard uppercase.contains(where: { (65...90).contains($0) }),
              uppercase.contains(where: { (48...57).contains($0) }) else {
            throw EchoLinkRelayProtocolError.invalidCallsign
        }
        var payload = Data([UInt8(uppercase.count)])
        payload.append(contentsOf: uppercase)
        return payload
    }

    private static func isValidRegistrationPayload(_ payload: Data) -> Bool {
        guard let count = payload.first,
              (1...15).contains(count),
              payload.count == Int(count) + 1 else { return false }
        let callsign = payload.dropFirst()
        guard callsign.contains(where: { (65...90).contains($0) }),
              callsign.contains(where: { (48...57).contains($0) }) else { return false }
        return callsign.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        let fields = host.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        var address: [UInt8] = []
        for field in fields {
            guard !field.isEmpty, field.count <= 3,
                  (field.count == 1 || field.first != "0"),
                  field.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt8(field) else { return nil }
            address.append(value)
        }
        return address
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }
}
