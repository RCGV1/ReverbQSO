// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class StationLocationTests: XCTestCase {
    func testStatusOnlyDescriptionDoesNotBecomeAnAdvertisedLocation() {
        for status in ["[ON: 00:08]", "[ON 12:34]", "[BUSY 23:59]"] {
            let station = Station(callsign: "K1ABC-R", description: status, ipAddress: "192.0.2.1")
            XCTAssertNil(station.locationDisplay, status)
        }
    }

    func testDisplayDescriptionHidesDirectoryStatusButPreservesOperatorTextAndRelayEligibility() {
        for suffix in ["[ON: 00:08]", "[ON 12:34]", "[busy:23:59]"] {
            let raw = "Hilltop [r] [0/20]   \(suffix)  "
            let station = Station(callsign: "K1ABC-R", description: raw, ipAddress: "192.0.2.1")
            XCTAssertEqual(station.displayDescription, "Hilltop [r]")
            XCTAssertEqual(station.description, raw)
            XCTAssertTrue(station.isRelayOnly)
        }
        for text in ["Night net at 00:08", "[Svx] Hilltop", "Radio [ON AIR]", "", "Hilltop [ON 99:99]"] {
            XCTAssertEqual(Station(callsign: "K1ABC-R", description: text, ipAddress: "192.0.2.1").displayDescription, text)
        }
    }

    func testDisplayDescriptionSeparatesPublishedConnectionCapacity() {
        XCTAssertEqual(Station(callsign: "K1ABC-R", description: "El Cajon, CA [0/20]", ipAddress: "192.0.2.1").displayDescription, "El Cajon, CA")
        XCTAssertEqual(Station(callsign: "K1ABC-R", description: "[20/20] [ON: 00:08]", ipAddress: "192.0.2.1").displayDescription, "")
        for text in ["Net [0/0]", "Net [x/20]", "Net [0/20] schedule", "Net [144/440 MHz]"] {
            XCTAssertEqual(Station(callsign: "K1ABC-R", description: text, ipAddress: "192.0.2.1").displayDescription, text)
        }
    }

    func testPublishedCapacityControlsConnectionAvailabilityWithoutInventingCounts() {
        var station = Station(callsign: "K1ABC-R", description: "Hilltop [0/20] [ON 12:34]", ipAddress: "192.0.2.1")
        XCTAssertEqual(station.reportedConnections?.connected, 0)
        XCTAssertEqual(station.reportedConnections?.limit, 20)
        XCTAssertNil(station.connectionUnavailableReason)
        station.description = "Hilltop [20 / 20]"
        XCTAssertNil(station.connectionUnavailableReason)
        station.isBusy = true
        XCTAssertEqual(station.connectionUnavailableReason, "Connection limit reached (20 connected; advertised limit 20).")
        station.isBusy = false
        station.description = "Hilltop [21/20]"
        XCTAssertTrue(station.reportedConnections?.isAtReportedLimit == true)
        XCTAssertNil(station.connectionUnavailableReason)
        for text in ["Hilltop", "Hilltop [0/0]", "Hilltop [x/20]", "Hilltop [0/20] schedule", "Hilltop [999999999999999999999/20]"] {
            station.description = text
            XCTAssertNil(station.reportedConnections, text)
            XCTAssertNil(station.connectionUnavailableReason, text)
        }
        station.isBusy = true
        XCTAssertEqual(station.connectionUnavailableReason, "This station is not accepting new connections.")
        station.description = "Hilltop [r] [0/20]"
        XCTAssertEqual(station.connectionUnavailableReason, "This station cannot receive calls.")
    }

    func testCountryFlagsRequireRecognizedTwoLetterCodes() {
        XCTAssertEqual(CountryFlag.emoji(for: "US"), "🇺🇸")
        XCTAssertEqual(CountryFlag.emoji(for: "gb"), "🇬🇧")
        XCTAssertEqual(CountryFlag.emoji(for: "AU"), "🇦🇺")
        for invalid: String? in [nil, "", "ZZ", "USA", "12", "åu"] {
            XCTAssertNil(CountryFlag.emoji(for: invalid))
        }
        let portable = Station(callsign: "G/W6ABC-L", description: "Sydney, Australia", ipAddress: "192.0.2.1")
        XCTAssertEqual(portable.callSignCountryFlag, "🇬🇧")
        XCTAssertEqual(portable.callSignRegion, .europe)
        XCTAssertNil(Station(callsign: "*ECHOTEST*", description: "USA", ipAddress: "192.0.2.1").callSignCountryFlag)
    }

    func testRegionsIncludeCentralAmericaCaribbeanAndAntarctica() {
        let expected: [(String, StationRegion)] = [
            ("US", .northAmerica), ("MX", .northAmerica), ("CR", .northAmerica), ("JM", .northAmerica),
            ("BR", .southAmerica), ("ZA", .africa), ("FR", .europe), ("JP", .asia),
            ("AU", .oceania), ("FJ", .oceania), ("AQ", .antarctica)
        ]
        for (country, region) in expected { XCTAssertEqual(StationRegion.forCountry(country), region, country) }
        XCTAssertNil(StationRegion.forCountry(nil))
        XCTAssertNil(StationRegion.forCountry("ZZ"))
    }


    func testCallsignCountryIsIndependentOfAdvertisedDescription() {
        let station = Station(
            callsign: "VK2ABC-L",
            description: "Paris, France",
            ipAddress: "1.2.3.4"
        )

        XCTAssertEqual(station.callSignCountryCode, "AU")
        XCTAssertEqual(station.advertisedLocationCountryCode, "FR")
    }

    func testCallsignCountryHandlesEchoLinkAndPortableSuffixes() {
        XCTAssertEqual(Station(callsign: "DL1ABC-R", ipAddress: "1.2.3.4").callSignCountryCode, "DE")
        XCTAssertEqual(Station(callsign: "G/W6ABC-L", ipAddress: "1.2.3.4").callSignCountryCode, "GB")
        XCTAssertEqual(Station(callsign: "JA1ABC/P", ipAddress: "1.2.3.4").callSignCountryCode, "JP")
        XCTAssertNil(Station(callsign: "*ECHOTEST*", ipAddress: "1.2.3.4").callSignCountryCode)
    }

    func testCallsignCountryCoversRepresentativeITURegions() {
        let expected: [(String, String)] = [
            ("K1ABC", "US"), ("VE3ABC", "CA"), ("XE1ABC", "MX"),
            ("PY2ABC", "BR"), ("LU1ABC", "AR"), ("ZS6ABC", "ZA"),
            ("F4ABC", "FR"), ("I0ABC", "IT"), ("EA3ABC", "ES"),
            ("SP5ABC", "PL"), ("OH2ABC", "FI"), ("SM0ABC", "SE"),
            ("VU2ABC", "IN"), ("HS0ABC", "TH"), ("YB0ABC", "ID"),
            ("ZL1ABC", "NZ"), ("HL2ABC", "KR")
        ]

        for (callsign, country) in expected {
            XCTAssertEqual(
                Station(callsign: callsign, ipAddress: "1.2.3.4").callSignCountryCode,
                country,
                callsign
            )
        }
    }

    func testCallsignCountryHandlesSharedITUBlocksAndUncommonAllocations() {
        let expected: [(String, String)] = [
            ("3D2ABC", "FJ"), ("3DA0ABC", "SZ"),
            ("PJ2ABC", "CW"), ("PJ4ABC", "BQ"), ("PJ7ABC", "SX"),
            ("E7ABC", "BA"), ("4W1ABC", "TL"),
            ("T2ABC", "TV"), ("Z81ABC", "SS")
        ]

        for (callsign, country) in expected {
            XCTAssertEqual(
                Station(callsign: callsign, ipAddress: "1.2.3.4").callSignCountryCode,
                country,
                callsign
            )
        }
    }

    func testUSStateInfersCountryCodeAndCity() {
        let station = Station(
            callsign: "W6ABC-R",
            description: "San Francisco, CA",
            ipAddress: "1.2.3.4"
        )

        XCTAssertEqual(station.locationDisplay, "San Francisco")
        XCTAssertEqual(station.countryCode, "US")
        assertNoEmoji(in: station.locationDisplay)
    }

    func testCountryNameInfersCountryCodeAndCity() {
        let station = Station(
            callsign: "VK2ABC",
            description: "Sydney, Australia",
            ipAddress: "1.2.3.4"
        )

        XCTAssertEqual(station.locationDisplay, "Sydney")
        XCTAssertEqual(station.countryCode, "AU")
        assertNoEmoji(in: station.locationDisplay)

        let svxStation = Station(
            callsign: "IR0ABC-L",
            description: "[Svx] 430.125 Rome IT      [ON 07:34]",
            ipAddress: "1.2.3.4"
        )
        XCTAssertEqual(svxStation.locationDisplay, "Rome")
        XCTAssertEqual(svxStation.countryCode, "IT")
        assertNoEmoji(in: svxStation.locationDisplay)
    }

    func testUnknownCountryShowsCityWithoutEmojiPrefix() {
        let station = Station(
            callsign: "X1ABC",
            description: "Downtown Metro Hub",
            ipAddress: "1.2.3.4"
        )

        XCTAssertEqual(station.locationDisplay, "Downtown Metro Hub")
        XCTAssertNil(station.countryCode)
        assertNoEmoji(in: station.locationDisplay)

        let svxCommaStation = Station(
            callsign: "IR0DEF-L",
            description: "[Svx] 435.9875, GardaLake  [ON 07:35]",
            ipAddress: "1.2.3.4"
        )
        XCTAssertEqual(svxCommaStation.locationDisplay, "GardaLake")
        XCTAssertNil(svxCommaStation.countryCode)
        assertNoEmoji(in: svxCommaStation.locationDisplay)
    }

    func testStatusSuffixIsStrippedBeforeParsing() {
        let station = Station(
            callsign: "KD6WQK-L",
            description: "Fullerton, CA USA [0/20]   [ON 22:09]",
            ipAddress: "1.2.3.4"
        )

        XCTAssertEqual(station.locationDisplay, "Fullerton")
        XCTAssertEqual(station.countryCode, "US")
        assertNoEmoji(in: station.locationDisplay)
    }

    func testCanadianProvinceCodeWithoutCommaInfersCanada() {
        let station = Station(
            callsign: "VE3ABC",
            description: "Bayfield On [0/20]         [ON 01:10]",
            ipAddress: "1.2.3.4"
        )

        XCTAssertEqual(station.locationDisplay, "Bayfield")
        XCTAssertEqual(station.countryCode, "CA")
        assertNoEmoji(in: station.locationDisplay)
    }

    func testUKTokenInfersGreatBritainCountryCode() {
        let station = Station(
            callsign: "G0ABC",
            description: "Harpenden, Herts, UK [0/20][ON 06:10]",
            ipAddress: "1.2.3.4"
        )

        XCTAssertEqual(station.locationDisplay, "Harpenden")
        XCTAssertEqual(station.countryCode, "GB")
        assertNoEmoji(in: station.locationDisplay)
    }

    func testConferenceTextDoesNotFalseMatchIndianaStateCode() {
        let station = Station(
            callsign: "*CONF*",
            description: "In Conference IRLP 0070    [ON 22:09]",
            ipAddress: "1.2.3.4"
        )

        XCTAssertEqual(station.locationDisplay, "In Conference IRLP 0070")
        XCTAssertNil(station.countryCode)
        assertNoEmoji(in: station.locationDisplay)
    }

    func testCallsignLikeLocationTokenInfersUS() {
        let station = Station(
            callsign: "W6ABC-R",
            description: "N6NFI 145.23 link          [ON 22:32]",
            ipAddress: "1.2.3.4"
        )

        XCTAssertEqual(station.locationDisplay, "N6NFI 145.23 link")
        XCTAssertEqual(station.countryCode, "US")
        assertNoEmoji(in: station.locationDisplay)

        let lowerCaseStateStation = Station(
            callsign: "KD6ABC-L",
            description: "south gate ca              [ON 22:35]",
            ipAddress: "1.2.3.4"
        )
        XCTAssertEqual(lowerCaseStateStation.locationDisplay, "south gate")
        XCTAssertEqual(lowerCaseStateStation.countryCode, "US")
        assertNoEmoji(in: lowerCaseStateStation.locationDisplay)
    }

    func testLocationDisplayForUnknownCountryDoesNotIncludeCountryPlaceholder() {
        let station = Station(
            callsign: "X9ABC",
            description: "Metro Bridge Node",
            ipAddress: "1.2.3.4"
        )

        XCTAssertEqual(station.locationDisplay, "Metro Bridge Node")
        XCTAssertFalse(station.locationDisplay?.contains("UNKNOWN") ?? true)
        assertNoEmoji(in: station.locationDisplay)

        let domainStation = Station(
            callsign: "DX1ABC-L",
            description: "DXLink * dxlink.ro         [ON 08:33]",
            ipAddress: "1.2.3.4"
        )
        XCTAssertEqual(domainStation.locationDisplay, "DXLink * dxlink.ro")
        XCTAssertEqual(domainStation.countryCode, "RO")
        assertNoEmoji(in: domainStation.locationDisplay)
    }

    private func assertNoEmoji(in value: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let value else { return }
        let hasEmoji = value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .otherSymbol:
                return scalar.value >= 0x2600 || scalar.properties.isEmojiPresentation
            default:
                return scalar.properties.isEmojiPresentation
            }
        }
        XCTAssertFalse(hasEmoji, "Expected no emoji symbols in '\(value)'", file: file, line: line)
    }
}
