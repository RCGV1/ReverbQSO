// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class EchoLinkParticipantParserTests: XCTestCase {
    func testSvxLinkRosterMarksOnlyTheArrowedOperatorAsTalking() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("""
        SvxLink 26.05.1 - W6SLG-R (2)

        > K1ABC         Alex

        W6SLG-R         UCSC repeater
        K2XYZ         Talking operator
        """)
        XCTAssertEqual(updates, [
            EchoLinkParticipantUpdate(callsign: "K1ABC", isTransmitting: true, kind: .upsert),
            EchoLinkParticipantUpdate(callsign: "W6SLG-R", isTransmitting: false, kind: .upsert),
            EchoLinkParticipantUpdate(callsign: "K2XYZ", isTransmitting: false, kind: .upsert)
        ])
    }

    func testSvxLinkIdleRosterExplicitlyClearsTheFormerTalker() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("""
        SvxLink 26.05.1 - W6SLG-R (1)

        W6SLG-R         UCSC repeater
        K1ABC         Alex
        """)
        XCTAssertEqual(updates.map(\.isTransmitting), [false, false])
    }

    func testSvxLinkRadioSideSpeechMarksTheRepeater() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("""
        SvxLink 26.05.1 - W6SLG-R (1)

        > W6SLG-R         UCSC repeater

        K1ABC         Alex
        """)
        XCTAssertEqual(updates, [
            EchoLinkParticipantUpdate(callsign: "W6SLG-R", isTransmitting: true, kind: .upsert),
            EchoLinkParticipantUpdate(callsign: "K1ABC", isTransmitting: false, kind: .upsert)
        ])
    }

    func testArrowInOrdinaryStationInfoDoesNotInventATalker() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("> K1ABC         Example operator")
        XCTAssertEqual(updates, [EchoLinkParticipantUpdate(callsign: "K1ABC", isTransmitting: nil, kind: .upsert)])
    }

    func testFirstCallsignNormalizesToUppercase() {
        let callsign = EchoLinkParticipantParser.firstCallsign(in: "de k1xyz-l via conference")
        XCTAssertEqual(callsign, "K1XYZ-L")
    }

    func testExtractCallsignsReturnsUniqueValuesInEncounterOrder() {
        let callsigns = EchoLinkParticipantParser.extractCallsigns(
            from: "W6ABC linked to K1XYZ and W6ABC relay"
        )

        XCTAssertEqual(callsigns, ["W6ABC", "K1XYZ"])
    }

    func testParseInfoMessageJoinCreatesUpsertWithoutTransmitState() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("W6ABC connected")

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0], EchoLinkParticipantUpdate(callsign: "W6ABC", isTransmitting: nil, kind: .upsert))
    }

    func testParseInfoMessageLeaveCreatesRemove() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("W6ABC disconnected")

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0], EchoLinkParticipantUpdate(callsign: "W6ABC", isTransmitting: nil, kind: .remove))
    }

    func testParseInfoMessageTransmitOnMarksParticipantAsTransmitting() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("W6ABC is transmitting")

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0], EchoLinkParticipantUpdate(callsign: "W6ABC", isTransmitting: true, kind: .upsert))
    }

    func testParseInfoMessageTransmitOffMarksParticipantAsNotTransmitting() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("W6ABC tx off")

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0], EchoLinkParticipantUpdate(callsign: "W6ABC", isTransmitting: false, kind: .upsert))
    }

    func testNegativeTransmitPhrasesDoNotCountAsTransmitOn() {
        for phrase in ["not transmitting", "stopped transmitting", "unkeyed", "dekeyed"] {
            XCTAssertEqual(
                EchoLinkParticipantParser.parseInfoMessage("W6ABC " + phrase),
                [EchoLinkParticipantUpdate(callsign: "W6ABC", isTransmitting: false, kind: .upsert)],
                phrase
            )
        }
    }

    func testParseInfoMessageConflictingTransmitKeywordsLeavesTransmitStateUnknown() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("W6ABC transmitting but idle")

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0], EchoLinkParticipantUpdate(callsign: "W6ABC", isTransmitting: nil, kind: .upsert))
    }

    func testParseInfoMessageAggregatesAcrossMultipleLines() {
        let text = """
        W6ABC connected
        K1XYZ keyed
        N0CALL disconnected
        """

        let updates = EchoLinkParticipantParser.parseInfoMessage(text)

        XCTAssertEqual(updates, [
            EchoLinkParticipantUpdate(callsign: "W6ABC", isTransmitting: nil, kind: .upsert),
            EchoLinkParticipantUpdate(callsign: "K1XYZ", isTransmitting: true, kind: .upsert),
            EchoLinkParticipantUpdate(callsign: "N0CALL", isTransmitting: nil, kind: .remove)
        ])
    }

    func testParseInfoMessageSkipsLinesWithoutCallsign() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("node status updated")
        XCTAssertTrue(updates.isEmpty)
    }

    func testParseInfoMessageCreatesUpdatePerCallsignInLine() {
        let updates = EchoLinkParticipantParser.parseInfoMessage("W6ABC and K1XYZ linked")

        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0], EchoLinkParticipantUpdate(callsign: "W6ABC", isTransmitting: nil, kind: .upsert))
        XCTAssertEqual(updates[1], EchoLinkParticipantUpdate(callsign: "K1XYZ", isTransmitting: nil, kind: .upsert))
    }
}
