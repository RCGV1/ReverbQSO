// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

final class SvxLinkControlProtocolTests: XCTestCase {
    func testDocumentedCommandBytes() throws {
        XCTAssertEqual(SvxLinkCommandEncoder.killTalker(), Data("KILL\n".utf8))
        XCTAssertEqual(try SvxLinkCommandEncoder.disconnect(callsign: "n0call-l"), Data("DISC N0CALL-L\n".utf8))
        XCTAssertEqual(try SvxLinkCommandEncoder.disconnect(callsign: "*ECHO*"), Data("DISC *ECHO*\n".utf8))
        XCTAssertEqual(try SvxLinkCommandEncoder.setOnline(logicName: "RepeaterLogic", online: false), Data("CFG RepeaterLogic ONLINE 0\n".utf8))
        XCTAssertEqual(try SvxLinkCommandEncoder.setOnline(logicName: "SimplexLogic_2", online: true), Data("CFG SimplexLogic_2 ONLINE 1\n".utf8))
        XCTAssertEqual(try SvxLinkCommandEncoder.dtmf("*1#"), Data("*1#\n".utf8))
    }

    func testCallsSignCannotInjectAnotherCommand() {
        for callsign in ["N0CALL-L\nKILL", "N0CALL-L\rKILL", "N0CALL-L KILL", "N0CALL/L", "N0CALL--L", "*BAD", "N0CALL-L\u{0000}"] {
            XCTAssertThrowsError(try SvxLinkCommandEncoder.disconnect(callsign: callsign), callsign) {
                XCTAssertEqual($0 as? SvxLinkControlError, .invalidCallsign)
            }
        }
    }

    func testLogicNameCannotInjectConfiguration() {
        for logic in ["", "Repeater Logic", "RepeaterLogic\nEVENT bad", "-Logic", "Logic;id", "Logic\u{0000}"] {
            XCTAssertThrowsError(try SvxLinkCommandEncoder.setOnline(logicName: logic, online: true), logic) {
                XCTAssertEqual($0 as? SvxLinkControlError, .invalidLogicName)
            }
        }
    }

    func testDTMFRejectsTextWhitespaceAndUnterminatedSequences() {
        for digits in ["", "123", "*1#\nKILL", "* 1#", "abc#", "*1#EVENT", "123\r#"] {
            XCTAssertThrowsError(try SvxLinkCommandEncoder.dtmf(digits), digits) {
                XCTAssertEqual($0 as? SvxLinkControlError, .invalidDTMF)
            }
        }
    }

    func testTransmitterTrueThenFalseAreDistinctEvents() throws {
        let active = try XCTUnwrap(SvxLinkStateParser.parse("1727550000.123 Tx:state {\"id\":\"T\",\"name\":\"Tx1\",\"transmit\":true}\n"))
        let inactive = try XCTUnwrap(SvxLinkStateParser.parse("1727550000.456 Tx:state {\"id\":\"T\",\"name\":\"Tx1\",\"transmit\":false}\n"))
        XCTAssertEqual(active.timestamp.timeIntervalSince1970, 1_727_550_000.123, accuracy: 0.001)
        XCTAssertEqual(active.event, .transmitter(.init(id: "T", name: "Tx1", isTransmitting: true)))
        XCTAssertEqual(inactive.event, .transmitter(.init(id: "T", name: "Tx1", isTransmitting: false)))
    }

    func testVoterFixtureAllowsDisabledReceiverWithoutSquelchFields() {
        let line = "1727550000.123 Voter:sql_state [{\"name\":\"Rx1\",\"id\":\"E\",\"enabled\":true,\"sql_open\":true,\"active\":true,\"siglev\":59},{\"name\":\"Rx3\",\"id\":\"D\",\"enabled\":false}]\n"
        let parsed = SvxLinkStateParser.parse(line)
        XCTAssertEqual(parsed?.event, .receivers([
            .init(name: "Rx1", id: "E", isEnabled: true, isSquelchOpen: true, isActive: true, signalLevel: 59),
            .init(name: "Rx3", id: "D", isEnabled: false, isSquelchOpen: nil, isActive: nil, signalLevel: nil)
        ]))
    }

    func testUnknownEventPreservesDataWithoutChangingRadioState() {
        let parsed = SvxLinkStateParser.parse("1727550000.123 EchoLink:peer {\"transmit\":true}\n")
        XCTAssertEqual(parsed?.event, .unknown(context: "EchoLink", name: "peer", data: "{\"transmit\":true}"))
    }

    func testMalformedAndTruncatedStateLinesAreRejected() {
        for line in [
            "1727550000.123 Tx:state {\"transmit\":true}",
            "1727550000.123 Tx:state {bad}\n",
            "1727550000.123 Tx:state {\"id\":\"T\",\"name\":\"Tx1\"}\n",
            "bad Tx:state {}\n",
            "1727550000.123 Tx:state {}\nKILL\n",
            "1727550000.123 Tx:state {}\u{0000}\n"
        ] {
            XCTAssertNil(SvxLinkStateParser.parse(line), line)
        }
        let oversized = "1727550000.123 EchoLink:peer " + String(repeating: "X", count: 4096) + "\n"
        XCTAssertNil(SvxLinkStateParser.parse(oversized))
    }
}
