// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class EchoLinkRelayProtocolTests: XCTestCase {
    func testDataRequestUsesSevenByteNetworkOrderHeader() throws {
        XCTAssertEqual(try EchoLinkRelayProtocol.encodeRequest(
            type: .data,
            destinationHost: "203.0.113.7",
            destinationPort: 5198,
            payload: Data([0xBE, 0xEF])
        ), Data([
            0x01, 0xCB, 0x00, 0x71, 0x07, 0x14, 0x4E, 0xBE, 0xEF
        ]))
    }

    func testRegisterAndUnregisterHaveZeroDestinationAndLengthPrefixedUppercaseCallsign() throws {
        XCTAssertEqual(try EchoLinkRelayProtocol.register(callsign: "n0call-l"), Data([
            0x03, 0, 0, 0, 0, 0, 0, 0x08,
            0x4E, 0x30, 0x43, 0x41, 0x4C, 0x4C, 0x2D, 0x4C
        ]))
        XCTAssertEqual(try EchoLinkRelayProtocol.unregister(callsign: "W6ABC-R"), Data([
            0x04, 0, 0, 0, 0, 0, 0, 0x07,
            0x57, 0x36, 0x41, 0x42, 0x43, 0x2D, 0x52
        ]))
    }

    func testDropFlowIncludesCallsignAfterPeerAddressAndPort() throws {
        XCTAssertEqual(try EchoLinkRelayProtocol.dropFlow(
            destinationHost: "203.0.113.7", destinationPort: 5199, callsign: "n0call"
        ), Data([
            0x05, 0xCB, 0x00, 0x71, 0x07, 0x14, 0x4F,
            0x06, 0x4E, 0x30, 0x43, 0x41, 0x4C, 0x4C
        ]))
    }

    func testAllDocumentedRequestTypesHaveExpectedCodes() {
        XCTAssertEqual(EchoLinkRelayRequestType.keepalive.rawValue, 0)
        XCTAssertEqual(EchoLinkRelayRequestType.data.rawValue, 1)
        XCTAssertEqual(EchoLinkRelayRequestType.close.rawValue, 2)
        XCTAssertEqual(EchoLinkRelayRequestType.register.rawValue, 3)
        XCTAssertEqual(EchoLinkRelayRequestType.unregister.rawValue, 4)
        XCTAssertEqual(EchoLinkRelayRequestType.dropFlow.rawValue, 5)
        XCTAssertEqual(EchoLinkRelayRequestType.ping.rawValue, 6)
        XCTAssertEqual(EchoLinkRelayProtocol.host, "relay.echolink.org")
        XCTAssertEqual(EchoLinkRelayProtocol.port, 7000)
    }

    func testRequestRejectsInvalidAddressAndDataPort() {
        for address in ["", "203.0.113", "203.0.113.999", "203.0.113.07", "203.0.113.7\n"] {
            XCTAssertThrowsError(try EchoLinkRelayProtocol.encodeRequest(type: .data, destinationHost: address, destinationPort: 5198, payload: Data([1])), address)
        }
        XCTAssertThrowsError(try EchoLinkRelayProtocol.encodeRequest(type: .data, destinationHost: "203.0.113.7", destinationPort: 7000, payload: Data([1])))
    }

    func testRegistrationRejectsMalformedOrOversizedCallsign() {
        for callsign in ["", "A B", "N0CALL/L", "N0CALL\nKILL", String(repeating: "A", count: 16), "N0CALL\u{0000}", "ÅBC"] {
            XCTAssertThrowsError(try EchoLinkRelayProtocol.register(callsign: callsign), callsign)
        }
    }

    func testRegistrationRejectsUnsupportedDestinationAndMalformedPayload() {
        XCTAssertThrowsError(try EchoLinkRelayProtocol.encodeRequest(type: .register, destinationHost: "203.0.113.7", destinationPort: 0, payload: Data([1, 0x41])))
        XCTAssertThrowsError(try EchoLinkRelayProtocol.encodeRequest(type: .register, destinationHost: "0.0.0.0", destinationPort: 0, payload: Data([2, 0x41])))
    }

    func testDataResponseDecodesNineByteNetworkOrderHeader() throws {
        let response = try EchoLinkRelayProtocol.decodeResponse(Data([
            0x01, 0xC6, 0x33, 0x64, 0x0A, 0xC3, 0x50, 0x14, 0x4F, 0xBE, 0xEF
        ]))
        XCTAssertEqual(response.type, .data)
        XCTAssertEqual(response.sourceHost, "198.51.100.10")
        XCTAssertEqual(response.sourcePort, 50000)
        XCTAssertEqual(response.destinationPort, 5199)
        XCTAssertEqual(response.payload, Data([0xBE, 0xEF]))
    }

    func testResponseTypesAndAllocationFailure() throws {
        let base = Data([0, 0, 0, 0, 0, 0, 0, 0, 0])
        for (code, type) in [(UInt8(3), EchoLinkRelayResponseType.ping), (4, .ack)] {
            var bytes = base
            bytes[0] = code
            XCTAssertEqual(try EchoLinkRelayProtocol.decodeResponse(bytes).type, type)
        }
        var errorBytes = base
        errorBytes[0] = 2
        errorBytes.append(1)
        let error = try EchoLinkRelayProtocol.decodeResponse(errorBytes)
        XCTAssertEqual(error.type, .error)
        XCTAssertEqual(error.errorCode, .allocationFailure)
    }

    func testResponseRejectsTruncatedUnknownAndUnsupportedFields() {
        for bytes in [
            Data(),
            Data([1, 0, 0, 0, 0, 0, 0, 0]),
            Data([9, 0, 0, 0, 0, 0, 0, 0, 0]),
            Data([1, 0, 0, 0, 0, 0x14, 0x4E, 0x1B, 0x58]),
            Data([2, 0, 0, 0, 0, 0, 0, 0, 0, 2]),
            Data([2, 0, 0, 0, 0, 0, 0, 0, 0])
        ] {
            XCTAssertThrowsError(try EchoLinkRelayProtocol.decodeResponse(bytes))
        }
    }

    func testRelayPayloadLimitMatchesServerAndRejectsSilentDiscard() throws {
        let maximum = Data(repeating: 0xAA, count: 1500)
        XCTAssertEqual(try EchoLinkRelayProtocol.encodeRequest(
            type: .data, destinationHost: "203.0.113.7", destinationPort: 5198,
            payload: maximum).count, 1507)
        XCTAssertThrowsError(try EchoLinkRelayProtocol.encodeRequest(
            type: .data, destinationHost: "203.0.113.7", destinationPort: 5198,
            payload: Data(repeating: 0, count: 1501))) { error in
            XCTAssertEqual(error as? EchoLinkRelayProtocolError, .oversizedDatagram)
        }
    }

    func testRegistrationRejectsCallsignsThatServerWouldAcknowledgeButIgnore() {
        for callsign in ["ABC", "123", "---", "ABC-L"] {
            XCTAssertThrowsError(try EchoLinkRelayProtocol.register(callsign: callsign))
        }
        XCTAssertThrowsError(try EchoLinkRelayProtocol.encodeRequest(
            type: .register, destinationHost: "0.0.0.0", destinationPort: 0,
            payload: Data([3, 65, 66, 67])))
    }

    func testOversizedDatagramsAreRejected() {
        let oversized = Data(repeating: 0, count: EchoLinkRelayProtocol.maxDatagramBytes + 1)
        XCTAssertThrowsError(try EchoLinkRelayProtocol.decodeResponse(oversized))
        XCTAssertThrowsError(try EchoLinkRelayProtocol.encodeRequest(type: .data, destinationHost: "203.0.113.7", destinationPort: 5198, payload: oversized))
    }
}
