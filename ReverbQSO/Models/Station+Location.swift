// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

extension Station {
    private static let locationLogger = Logger(subsystem: "org.reverbqso.app", category: "StationLocation")
    private static let enableLocationParseLogging = ProcessInfo.processInfo.environment["OEL_LOCATION_DEBUG"] == "1"

    /// Human-friendly cleanup of the operator-supplied directory location.
    /// Country provenance is exposed separately and is never prefixed here.
    var locationDisplay: String? {
        let raw = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let normalized = Self.normalizeLocationRaw(raw)
        let parsed = Self.parseLocation(from: normalized)
        let city = parsed.city.isEmpty ? raw : parsed.city
        if Self.enableLocationParseLogging {
            let countryTag = parsed.countryCode ?? "UNKNOWN"
            Self.locationLogger.debug(
                "Location parse raw='\(raw, privacy: .public)' normalized='\(normalized, privacy: .public)' city='\(city, privacy: .public)' countryCode='\(parsed.countryCode ?? "nil", privacy: .public)' countryTag='\(countryTag, privacy: .public)'"
            )
        }
        return city
    }

    /// Returns an ISO country code when it can be inferred from description.
    var countryCode: String? {
        advertisedLocationCountryCode
    }

    /// Country inferred from the operator-supplied directory description.
    /// This is separate from EchoLink's callsign-prefix location grouping.
    var advertisedLocationCountryCode: String? {
        let raw = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = Self.normalizeLocationRaw(raw)
        return Self.parseLocation(from: normalized).countryCode
    }

    /// ISO 3166 country used by EchoLink's Locations folders.
    /// EchoLink documents those folders as based solely on ITU callsign prefix.
    var callSignCountryCode: String? {
        ITUCallsignCountryResolver.countryCode(for: callsign)
    }

    var callSignCountryName: String? {
        guard let callSignCountryCode else { return nil }
        return Locale.current.localizedString(forRegionCode: callSignCountryCode)
            ?? Locale(identifier: "en_US").localizedString(forRegionCode: callSignCountryCode)
    }

    private static func parseLocation(from value: String) -> (city: String, countryCode: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        let tokens = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if tokens.isEmpty { return (trimmed, inferCountry(from: trimmed)) }
        if tokens.count == 1 {
            let city = cityFromSingleToken(tokens[0])
            let country = inferCountry(from: tokens[0])
            return (city, country)
        }

        let last = tokens.last ?? ""
        let secondLast = tokens.count >= 2 ? tokens[tokens.count - 2] : ""
        let city = cityFromTokens(tokens, fallback: value)

        if isUSStateCode(last) {
            return (city, "US")
        }

        if let country = countryCode(from: last) {
            return (city, country)
        }

        if isUSStateCode(secondLast), let country = countryCode(from: last) {
            return (city, country)
        }

        if let inferred = tokens.reversed().compactMap({ inferCountry(from: $0) }).first {
            return (city, inferred)
        }

        // If no clear country is found, return the first token as city and unknown country.
        return (city, nil)
    }

    private static func countryCode(from token: String) -> String? {
        let cleaned = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let aliases: [String: String] = [
            "us": "US", "usa": "US", "united states": "US", "united states of america": "US",
            "canada": "CA",
            "mexico": "MX",
            "uk": "GB", "united kingdom": "GB", "great britain": "GB",
            "germany": "DE",
            "france": "FR",
            "italy": "IT",
            "spain": "ES",
            "japan": "JP",
            "australia": "AU",
            "new zealand": "NZ",
            "brazil": "BR",
            "argentina": "AR",
            "india": "IN",
            "south korea": "KR",
            "korea": "KR",
            "china": "CN"
        ]

        if let code = aliases[cleaned] {
            return code
        }

        if cleaned.count == 2, cleaned.allSatisfy(\.isLetter) {
            return cleaned.uppercased()
        }

        // Try locale lookup for full country names.
        for region in Locale.Region.isoRegions {
            let iso = region.identifier
            if Locale.current.localizedString(forRegionCode: iso)?.lowercased() == cleaned {
                return iso
            }
            if Locale(identifier: "en_US").localizedString(forRegionCode: iso)?.lowercased() == cleaned {
                return iso
            }
        }
        return nil
    }

    private static func inferCountry(from token: String) -> String? {
        let tokenWithSpaces = token.replacingOccurrences(of: ".", with: " ")
        let cleaned = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: " ")
            .lowercased()

        if cleaned.contains("usa") || cleaned == "us" || cleaned.contains("united states") {
            return "US"
        }
        if cleaned == "uk" || cleaned.contains("united kingdom") || cleaned.contains("great britain") {
            return "GB"
        }

        if usStateNames.contains(cleaned) {
            return "US"
        }

        let parts = cleaned
            .split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }

        let rawParts = tokenWithSpaces
            .split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }

        if let trailingRaw = rawParts.last {
            let trailingUpper = trailingRaw.uppercased()
            if caProvinceCodes.contains(trailingUpper) {
                return "CA"
            }
            if isLikelyTrailingUSStateCode(trailingUpper: trailingUpper, parts: parts, rawToken: trailingRaw) {
                return "US"
            }
            if !isUSStateCode(trailingUpper),
               !caProvinceCodes.contains(trailingUpper),
               let explicitCountry = countryCode(from: trailingRaw) {
                return explicitCountry
            }
        }

        if rawParts.contains(where: { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard trimmed.count == 2 else { return false }
            let original = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard original == original.uppercased() else { return false }
            return isUSStateCode(trimmed)
        }) {
            return "US"
        }
        if parts.contains(where: { caProvinceCodes.contains($0.uppercased()) }) {
            return "CA"
        }

        if let domainCountry = inferCountryFromDomain(rawParts) {
            return domainCountry
        }

        if let hamCountry = inferHamCallsignCountry(from: rawParts) {
            return hamCountry
        }

        return countryCode(from: cleaned)
    }

    private static func inferHamCallsignCountry(from parts: [String]) -> String? {
        for part in parts {
            let candidate = part
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .filter { $0.isLetter || $0.isNumber }
            guard candidate.count >= 4 else { continue }
            guard candidate.contains(where: { $0.isNumber }) else { continue }
            guard candidate.contains(where: { $0.isLetter }) else { continue }
            guard let first = candidate.first, first.isLetter else { continue }

            if isLikelyUSHamCallsign(candidate) {
                return "US"
            }
        }
        return nil
    }

    private static func isLikelyUSHamCallsign(_ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)

        // US amateur callsigns are commonly:
        //  - K/N/W + optional letter + digit + 1-4 letters (e.g. N6NFI, KD6WQK)
        //  - AA-AL + digit + 1-4 letters (e.g. AB1CDE)
        if let regex = try? NSRegularExpression(pattern: #"^(?:[KNW][A-Z]?|A[A-L])[0-9][A-Z]{1,4}$"#),
           regex.firstMatch(in: value, options: [], range: range) != nil {
            return true
        }

        return false
    }

    private static func cityFromSingleToken(_ token: String) -> String {
        let cleaned = sanitizeCity(token)
        var parts = cleaned
            .split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }

        while let first = parts.first, shouldDropLeadingNoiseToken(first) {
            parts.removeFirst()
        }

        guard !parts.isEmpty else { return cleaned }
        guard parts.count >= 2 else { return cleaned }

        let tailRaw = parts.last ?? ""
        let tail = tailRaw.uppercased()
        if isLikelyTrailingUSStateCode(trailingUpper: tail, parts: parts, rawToken: tailRaw) || caProvinceCodes.contains(tail) {
            let candidate = parts.dropLast().joined(separator: " ")
            return candidate.isEmpty ? cleaned : candidate
        }
        if countryCode(from: tailRaw) != nil {
            let candidate = parts.dropLast().joined(separator: " ")
            return candidate.isEmpty ? cleaned : candidate
        }
        return parts.joined(separator: " ")
    }

    private static func sanitizeCity(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") && value.contains("]") {
            let comps = value.split(separator: "]", maxSplits: 1, omittingEmptySubsequences: false)
            if comps.count == 2 {
                value = String(comps[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value
    }

    private static func normalizeLocationRaw(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\s*\[[^\]]*\]\s*$"#
        while let regex = try? NSRegularExpression(pattern: pattern),
              regex.firstMatch(
                  in: value,
                  options: [],
                  range: NSRange(location: 0, length: (value as NSString).length)
              ) != nil {
            value = regex.stringByReplacingMatches(
                in: value,
                options: [],
                range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let leadingBracketPattern = #"^\[[^\]]+\]\s*"#
        while let regex = try? NSRegularExpression(pattern: leadingBracketPattern),
              regex.firstMatch(
                  in: value,
                  options: [],
                  range: NSRange(location: 0, length: (value as NSString).length)
              ) != nil {
            value = regex.stringByReplacingMatches(
                in: value,
                options: [],
                range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func cityFromTokens(_ tokens: [String], fallback: String) -> String {
        guard !tokens.isEmpty else { return sanitizeCity(fallback) }
        var city = sanitizeCity(tokens[0])
        if shouldPromoteNextTokenAsCity(city), tokens.count > 1 {
            let next = sanitizeCity(tokens[1])
            if !next.isEmpty {
                city = next
            }
        }
        return cityFromSingleToken(city)
    }

    private static func shouldPromoteNextTokenAsCity(_ city: String) -> Bool {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if shouldDropLeadingNoiseToken(trimmed) {
            return true
        }
        return false
    }

    private static func shouldDropLeadingNoiseToken(_ token: String) -> Bool {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return true }
        if cleaned == "*" { return true }
        let lowered = cleaned.lowercased()
        if lowered == "svx" || lowered == "link" || lowered == "rpt" || lowered == "rptr" {
            return true
        }
        if looksLikeFrequencyToken(cleaned) {
            return true
        }
        return false
    }

    private static func looksLikeFrequencyToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        if let regex = try? NSRegularExpression(pattern: #"^\d{2,4}(?:\.\d{1,4})?$"#),
           regex.firstMatch(in: trimmed, options: [], range: range) != nil {
            return true
        }
        return false
    }

    private static func inferCountryFromDomain(_ rawParts: [String]) -> String? {
        for raw in rawParts {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard token.contains(".") else { continue }
            guard let tld = token.split(separator: ".").last else { continue }
            let suffix = String(tld)
            guard suffix.count == 2, suffix.allSatisfy(\.isLetter) else { continue }
            let upper = suffix.uppercased()
            if !isUSStateCode(upper), !caProvinceCodes.contains(upper) {
                return upper
            }
            if upper == "US" {
                return "US"
            }
        }
        return nil
    }

    private static func isLikelyTrailingUSStateCode(trailingUpper: String, parts: [String], rawToken: String) -> Bool {
        guard isUSStateCode(trailingUpper) else { return false }
        if rawToken == rawToken.uppercased() {
            return true
        }
        // Lower-case state abbreviations are common in location strings, but
        // avoid obvious English prepositions that collide with state codes.
        if ["IN", "OR", "ME"].contains(trailingUpper) {
            return false
        }
        return parts.count >= 2
    }

    private static func isUSStateCode(_ token: String) -> Bool {
        let code = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return usStateCodes.contains(code)
    }

    private static let usStateCodes: Set<String> = [
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN","IA","KS",
        "KY","LA","ME","MD","MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ","NM","NY",
        "NC","ND","OH","OK","OR","PA","RI","SC","SD","TN","TX","UT","VT","VA","WA","WV",
        "WI","WY","DC"
    ]

    private static let caProvinceCodes: Set<String> = ["AB","BC","MB","NB","NL","NS","NT","NU","ON","PE","QC","SK","YT"]
    private static let usStateNames: Set<String> = [
        "alabama","alaska","arizona","arkansas","california","colorado","connecticut","delaware",
        "florida","georgia","hawaii","idaho","illinois","indiana","iowa","kansas","kentucky",
        "louisiana","maine","maryland","massachusetts","michigan","minnesota","mississippi",
        "missouri","montana","nebraska","nevada","new hampshire","new jersey","new mexico",
        "new york","north carolina","north dakota","ohio","oklahoma","oregon","pennsylvania",
        "rhode island","south carolina","south dakota","tennessee","texas","utah","vermont",
        "virginia","washington","west virginia","wisconsin","wyoming","district of columbia"
    ]
}

/// Resolves the ITU callsign prefix used by EchoLink's country grouping.
/// It deliberately does not inspect the station's free-text description.
enum ITUCallsignCountryResolver {
    static func countryCode(for rawCallsign: String) -> String? {
        let cleaned = rawCallsign.uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("*") else { return nil }

        let withoutEchoLinkSuffix: String
        if cleaned.hasSuffix("-R") || cleaned.hasSuffix("-L") {
            withoutEchoLinkSuffix = String(cleaned.dropLast(2))
        } else {
            withoutEchoLinkSuffix = cleaned
        }

        let components = withoutEchoLinkSuffix.split(separator: "/").map(String.init)
        let candidates: [String]
        if components.count > 1, let first = components.first, first.count <= 4,
           prefixCountry(for: first) != nil {
            // A leading portable designator (for example G/W6ABC) identifies
            // the operating country. Trailing /P, /M, and similar suffixes do not.
            candidates = [first] + components
        } else {
            candidates = components
        }

        for candidate in candidates {
            let alphanumeric = candidate.filter { $0.isLetter || $0.isNumber }
            if let code = prefixCountry(for: alphanumeric) { return code }
        }
        return nil
    }

    private static func prefixCountry(for callsign: String) -> String? {
        // Common amateur assignments that need more detail than their parent
        // two-character ITU block.
        let amateurOverrides: [(String, String)] = [
            ("3D2", "FJ"), ("E51", "CK"), ("E6", "NU"),
            ("PJ2", "CW"), ("PJ4", "BQ"), ("PJ5", "BQ"),
            ("PJ6", "BQ"), ("PJ7", "SX")
        ]
        if let override = amateurOverrides.first(where: { callsign.hasPrefix($0.0) }) {
            return override.1
        }

        if callsign.count >= 2 {
            let key = String(callsign.prefix(2))
            if let code = ituTwoCharacterAllocations[key] { return code }
        }

        // Amateur callsigns can put a digit immediately after a nationally
        // allocated one-letter series (for example K1ABC or F4ABC).
        guard let first = callsign.first else { return nil }
        return singleCharacterAmateurAllocations[first]
    }

    // Source: ITU GLAD, Table of International Call Sign Series,
    // Appendix 42 to the Radio Regulations. Snapshot reviewed 2026-10-02.
    // https://www.itu.int/gladapp/Allocation/CallSigns
    private static let ituTwoCharacterAllocations: [String: String] = [
        "2A": "GB", "2B": "GB", "2C": "GB", "2D": "GB", "2E": "GB", "2F": "GB", "2G": "GB", "2H": "GB",
        "2I": "GB", "2J": "GB", "2K": "GB", "2L": "GB", "2M": "GB", "2N": "GB", "2O": "GB", "2P": "GB",
        "2Q": "GB", "2R": "GB", "2S": "GB", "2T": "GB", "2U": "GB", "2V": "GB", "2W": "GB", "2X": "GB",
        "2Y": "GB", "2Z": "GB", "3A": "MC", "3B": "MU", "3C": "GQ", "3D": "SZ", "3E": "PA", "3F": "PA",
        "3G": "CL", "3H": "CN", "3I": "CN", "3J": "CN", "3K": "CN", "3L": "CN", "3M": "CN", "3N": "CN",
        "3O": "CN", "3P": "CN", "3Q": "CN", "3R": "CN", "3S": "CN", "3T": "CN", "3U": "CN", "3V": "TN",
        "3W": "VN", "3X": "GN", "3Y": "NO", "3Z": "PL", "4A": "MX", "4B": "MX", "4C": "MX", "4D": "PH",
        "4E": "PH", "4F": "PH", "4G": "PH", "4H": "PH", "4I": "PH", "4J": "AZ", "4K": "AZ", "4L": "GE",
        "4M": "VE", "4O": "ME", "4P": "LK", "4Q": "LK", "4R": "LK", "4S": "LK", "4T": "PE", "4V": "HT",
        "4W": "TL", "4X": "IL", "4Z": "IL", "5A": "LY", "5B": "CY", "5C": "MA", "5D": "MA", "5E": "MA",
        "5F": "MA", "5G": "MA", "5H": "TZ", "5I": "TZ", "5J": "CO", "5K": "CO", "5L": "LR", "5M": "LR",
        "5N": "NG", "5O": "NG", "5P": "DK", "5Q": "DK", "5R": "MG", "5S": "MG", "5T": "MR", "5U": "NE",
        "5V": "TG", "5W": "AS", "5X": "UG", "5Y": "KE", "5Z": "KE", "6A": "EG", "6B": "EG", "6C": "SY",
        "6D": "MX", "6E": "MX", "6F": "MX", "6G": "MX", "6H": "MX", "6I": "MX", "6J": "MX", "6K": "KR",
        "6L": "KR", "6M": "KR", "6N": "KR", "6O": "SO", "6P": "PK", "6Q": "PK", "6R": "PK", "6S": "PK",
        "6T": "SD", "6U": "SD", "6V": "SN", "6W": "SN", "6X": "MG", "6Y": "JM", "6Z": "LR", "7A": "ID",
        "7B": "ID", "7C": "ID", "7D": "ID", "7E": "ID", "7F": "ID", "7G": "ID", "7H": "ID", "7I": "ID",
        "7J": "JP", "7K": "JP", "7L": "JP", "7M": "JP", "7N": "JP", "7O": "YE", "7P": "LS", "7Q": "MW",
        "7R": "DZ", "7S": "SE", "7T": "DZ", "7U": "DZ", "7V": "DZ", "7W": "DZ", "7X": "DZ", "7Y": "DZ",
        "7Z": "SA", "8A": "ID", "8B": "ID", "8C": "ID", "8D": "ID", "8E": "ID", "8F": "ID", "8G": "ID",
        "8H": "ID", "8I": "ID", "8J": "JP", "8K": "JP", "8L": "JP", "8M": "JP", "8N": "JP", "8O": "BW",
        "8P": "BB", "8Q": "MV", "8R": "GY", "8S": "SE", "8T": "IN", "8U": "IN", "8V": "IN", "8W": "IN",
        "8X": "IN", "8Y": "IN", "8Z": "SA", "9A": "HR", "9B": "IR", "9C": "IR", "9D": "IR", "9E": "ET",
        "9F": "ET", "9G": "GH", "9H": "MT", "9I": "ZM", "9J": "ZM", "9K": "KW", "9L": "SL", "9M": "MY",
        "9N": "NP", "9O": "CD", "9P": "CD", "9Q": "CD", "9R": "CD", "9S": "CD", "9T": "CD", "9U": "BI",
        "9V": "SG", "9W": "MY", "9X": "RW", "9Y": "TT", "9Z": "TT", "A2": "BW", "A3": "TO", "A4": "OM",
        "A5": "BT", "A6": "AE", "A7": "QA", "A8": "LR", "A9": "BH", "AA": "US", "AB": "US", "AC": "US",
        "AD": "US", "AE": "US", "AF": "US", "AG": "US", "AH": "US", "AI": "US", "AJ": "US", "AK": "US",
        "AL": "US", "AM": "ES", "AN": "ES", "AO": "ES", "AP": "PK", "AQ": "PK", "AR": "PK", "AS": "PK",
        "AT": "IN", "AU": "IN", "AV": "IN", "AW": "IN", "AX": "AU", "AY": "AR", "AZ": "AR", "BA": "CN",
        "BB": "CN", "BC": "CN", "BD": "CN", "BE": "CN", "BF": "CN", "BG": "CN", "BH": "CN", "BI": "CN",
        "BJ": "CN", "BK": "CN", "BL": "CN", "BM": "CN", "BN": "CN", "BO": "CN", "BP": "CN", "BQ": "CN",
        "BR": "CN", "BS": "CN", "BT": "CN", "BU": "CN", "BV": "CN", "BW": "CN", "BX": "CN", "BY": "CN",
        "BZ": "CN", "C2": "NR", "C3": "AD", "C4": "CY", "C5": "GM", "C6": "BS", "C8": "MZ", "C9": "MZ",
        "CA": "CL", "CB": "CL", "CC": "CL", "CD": "CL", "CE": "CL", "CF": "CA", "CG": "CA", "CH": "CA",
        "CI": "CA", "CJ": "CA", "CK": "CA", "CL": "CU", "CM": "CU", "CN": "MA", "CO": "CU", "CP": "BO",
        "CQ": "PT", "CR": "PT", "CS": "PT", "CT": "PT", "CU": "PT", "CV": "UY", "CW": "UY", "CX": "UY",
        "CY": "CA", "CZ": "CA", "D2": "AO", "D3": "AO", "D4": "CV", "D5": "LR", "D6": "KM", "D7": "KR",
        "D8": "KR", "D9": "KR", "DA": "DE", "DB": "DE", "DC": "DE", "DD": "DE", "DE": "DE", "DF": "DE",
        "DG": "DE", "DH": "DE", "DI": "DE", "DJ": "DE", "DK": "DE", "DL": "DE", "DM": "DE", "DN": "DE",
        "DO": "DE", "DP": "DE", "DQ": "DE", "DR": "DE", "DS": "KR", "DT": "KR", "DU": "PH", "DV": "PH",
        "DW": "PH", "DX": "PH", "DY": "PH", "DZ": "PH", "E2": "TH", "E3": "ER", "E4": "PS", "E5": "CK",
        "E6": "NU", "E7": "BA", "EA": "ES", "EB": "ES", "EC": "ES", "ED": "ES", "EE": "ES", "EF": "ES",
        "EG": "ES", "EH": "ES", "EI": "IE", "EJ": "IE", "EK": "AM", "EL": "LR", "EM": "UA", "EN": "UA",
        "EO": "UA", "EP": "IR", "EQ": "IR", "ER": "MD", "ES": "EE", "ET": "ET", "EU": "BY", "EV": "BY",
        "EW": "BY", "EX": "KG", "EY": "TJ", "EZ": "TM", "FA": "FR", "FB": "FR", "FC": "FR", "FD": "FR",
        "FE": "FR", "FF": "FR", "FG": "FR", "FH": "FR", "FI": "FR", "FJ": "FR", "FK": "FR", "FL": "FR",
        "FM": "FR", "FN": "FR", "FO": "FR", "FP": "FR", "FQ": "FR", "FR": "FR", "FS": "FR", "FT": "FR",
        "FU": "FR", "FV": "FR", "FW": "FR", "FX": "FR", "FY": "FR", "FZ": "FR", "GA": "GB", "GB": "GB",
        "GC": "GB", "GD": "GB", "GE": "GB", "GF": "GB", "GG": "GB", "GH": "GB", "GI": "GB", "GJ": "GB",
        "GK": "GB", "GL": "GB", "GM": "GB", "GN": "GB", "GO": "GB", "GP": "GB", "GQ": "GB", "GR": "GB",
        "GS": "GB", "GT": "GB", "GU": "GB", "GV": "GB", "GW": "GB", "GX": "GB", "GY": "GB", "GZ": "GB",
        "H2": "CY", "H3": "PA", "H4": "SB", "H6": "NI", "H7": "NI", "H8": "PA", "H9": "PA", "HA": "HU",
        "HB": "CH", "HC": "EC", "HD": "EC", "HE": "CH", "HF": "PL", "HG": "HU", "HH": "HT", "HI": "DO",
        "HJ": "CO", "HK": "CO", "HL": "KR", "HM": "KP", "HN": "IQ", "HO": "PA", "HP": "PA", "HQ": "HN",
        "HR": "HN", "HS": "TH", "HT": "NI", "HU": "SV", "HV": "VA", "HW": "FR", "HX": "FR", "HY": "FR",
        "HZ": "SA", "IA": "IT", "IB": "IT", "IC": "IT", "ID": "IT", "IE": "IT", "IF": "IT", "IG": "IT",
        "IH": "IT", "II": "IT", "IJ": "IT", "IK": "IT", "IL": "IT", "IM": "IT", "IN": "IT", "IO": "IT",
        "IP": "IT", "IQ": "IT", "IR": "IT", "IS": "IT", "IT": "IT", "IU": "IT", "IV": "IT", "IW": "IT",
        "IX": "IT", "IY": "IT", "IZ": "IT", "J2": "DJ", "J3": "GD", "J4": "GR", "J5": "GW", "J6": "LC",
        "J7": "DM", "J8": "VC", "JA": "JP", "JB": "JP", "JC": "JP", "JD": "JP", "JE": "JP", "JF": "JP",
        "JG": "JP", "JH": "JP", "JI": "JP", "JJ": "JP", "JK": "JP", "JL": "JP", "JM": "JP", "JN": "JP",
        "JO": "JP", "JP": "JP", "JQ": "JP", "JR": "JP", "JS": "JP", "JT": "MN", "JU": "MN", "JV": "MN",
        "JW": "NO", "JX": "NO", "JY": "JO", "JZ": "ID", "KA": "US", "KB": "US", "KC": "US", "KD": "US",
        "KE": "US", "KF": "US", "KG": "US", "KH": "US", "KI": "US", "KJ": "US", "KK": "US", "KL": "US",
        "KM": "US", "KN": "US", "KO": "US", "KP": "US", "KQ": "US", "KR": "US", "KS": "US", "KT": "US",
        "KU": "US", "KV": "US", "KW": "US", "KX": "US", "KY": "US", "KZ": "US", "L2": "AR", "L3": "AR",
        "L4": "AR", "L5": "AR", "L6": "AR", "L7": "AR", "L8": "AR", "L9": "AR", "LA": "NO", "LB": "NO",
        "LC": "NO", "LD": "NO", "LE": "NO", "LF": "NO", "LG": "NO", "LH": "NO", "LI": "NO", "LJ": "NO",
        "LK": "NO", "LL": "NO", "LM": "NO", "LN": "NO", "LO": "AR", "LP": "AR", "LQ": "AR", "LR": "AR",
        "LS": "AR", "LT": "AR", "LU": "AR", "LV": "AR", "LW": "AR", "LX": "LU", "LY": "LT", "LZ": "BG",
        "MA": "GB", "MB": "GB", "MC": "GB", "MD": "GB", "ME": "GB", "MF": "GB", "MG": "GB", "MH": "GB",
        "MI": "GB", "MJ": "GB", "MK": "GB", "ML": "GB", "MM": "GB", "MN": "GB", "MO": "GB", "MP": "GB",
        "MQ": "GB", "MR": "GB", "MS": "GB", "MT": "GB", "MU": "GB", "MV": "GB", "MW": "GB", "MX": "GB",
        "MY": "GB", "MZ": "GB", "NA": "US", "NB": "US", "NC": "US", "ND": "US", "NE": "US", "NF": "US",
        "NG": "US", "NH": "US", "NI": "US", "NJ": "US", "NK": "US", "NL": "US", "NM": "US", "NN": "US",
        "NO": "US", "NP": "US", "NQ": "US", "NR": "US", "NS": "US", "NT": "US", "NU": "US", "NV": "US",
        "NW": "US", "NX": "US", "NY": "US", "NZ": "US", "OA": "PE", "OB": "PE", "OC": "PE", "OD": "LB",
        "OE": "AT", "OF": "FI", "OG": "FI", "OH": "FI", "OI": "FI", "OJ": "FI", "OK": "CZ", "OL": "CZ",
        "OM": "SK", "ON": "BE", "OO": "BE", "OP": "BE", "OQ": "BE", "OR": "BE", "OS": "BE", "OT": "BE",
        "OU": "DK", "OV": "DK", "OW": "DK", "OX": "DK", "OY": "DK", "OZ": "DK", "P2": "PG", "P3": "CY",
        "P4": "AW", "P5": "KP", "P6": "KP", "P7": "KP", "P8": "KP", "P9": "KP", "PA": "NL", "PB": "NL",
        "PC": "NL", "PD": "NL", "PE": "NL", "PF": "NL", "PG": "NL", "PH": "NL", "PI": "NL", "PJ": "BQ",
        "PK": "ID", "PL": "ID", "PM": "ID", "PN": "ID", "PO": "ID", "PP": "BR", "PQ": "BR", "PR": "BR",
        "PS": "BR", "PT": "BR", "PU": "BR", "PV": "BR", "PW": "BR", "PX": "BR", "PY": "BR", "PZ": "SR",
        "RA": "RU", "RB": "RU", "RC": "RU", "RD": "RU", "RE": "RU", "RF": "RU", "RG": "RU", "RH": "RU",
        "RI": "RU", "RJ": "RU", "RK": "RU", "RL": "RU", "RM": "RU", "RN": "RU", "RO": "RU", "RP": "RU",
        "RQ": "RU", "RR": "RU", "RS": "RU", "RT": "RU", "RU": "RU", "RV": "RU", "RW": "RU", "RX": "RU",
        "RY": "RU", "RZ": "RU", "S2": "BD", "S3": "BD", "S5": "SI", "S6": "SG", "S7": "SC", "S8": "ZA",
        "S9": "ST", "SA": "SE", "SB": "SE", "SC": "SE", "SD": "SE", "SE": "SE", "SF": "SE", "SG": "SE",
        "SH": "SE", "SI": "SE", "SJ": "SE", "SK": "SE", "SL": "SE", "SM": "SE", "SN": "PL", "SO": "PL",
        "SP": "PL", "SQ": "PL", "SR": "PL", "SS": "EG", "ST": "SD", "SU": "EG", "SV": "GR", "SW": "GR",
        "SX": "GR", "SY": "GR", "SZ": "GR", "T2": "TV", "T3": "KI", "T4": "CU", "T5": "SO", "T6": "AF",
        "T7": "SM", "T8": "PW", "TA": "TR", "TB": "TR", "TC": "TR", "TD": "GT", "TE": "CR", "TF": "IS",
        "TG": "GT", "TH": "FR", "TI": "CR", "TJ": "CM", "TK": "FR", "TL": "CF", "TM": "FR", "TN": "CG",
        "TO": "FR", "TP": "FR", "TQ": "FR", "TR": "GA", "TS": "TN", "TT": "TD", "TU": "CI", "TV": "FR",
        "TW": "FR", "TX": "FR", "TY": "BJ", "TZ": "ML", "UA": "RU", "UB": "RU", "UC": "RU", "UD": "RU",
        "UE": "RU", "UF": "RU", "UG": "RU", "UH": "RU", "UI": "RU", "UJ": "UZ", "UK": "UZ", "UL": "UZ",
        "UM": "UZ", "UN": "KZ", "UO": "KZ", "UP": "KZ", "UQ": "KZ", "UR": "UA", "US": "UA", "UT": "UA",
        "UU": "UA", "UV": "UA", "UW": "UA", "UX": "UA", "UY": "UA", "UZ": "UA", "V2": "AG", "V3": "BZ",
        "V4": "KN", "V5": "NA", "V6": "FM", "V7": "MH", "V8": "BN", "VA": "CA", "VB": "CA", "VC": "CA",
        "VD": "CA", "VE": "CA", "VF": "CA", "VG": "CA", "VH": "AU", "VI": "AU", "VJ": "AU", "VK": "AU",
        "VL": "AU", "VM": "AU", "VN": "AU", "VO": "CA", "VP": "GB", "VQ": "GB", "VR": "HK", "VS": "GB",
        "VT": "IN", "VU": "IN", "VV": "IN", "VW": "IN", "VX": "CA", "VY": "CA", "VZ": "AU", "WA": "US",
        "WB": "US", "WC": "US", "WD": "US", "WE": "US", "WF": "US", "WG": "US", "WH": "US", "WI": "US",
        "WJ": "US", "WK": "US", "WL": "US", "WM": "US", "WN": "US", "WO": "US", "WP": "US", "WQ": "US",
        "WR": "US", "WS": "US", "WT": "US", "WU": "US", "WV": "US", "WW": "US", "WX": "US", "WY": "US",
        "WZ": "US", "XA": "MX", "XB": "MX", "XC": "MX", "XD": "MX", "XE": "MX", "XF": "MX", "XG": "MX",
        "XH": "MX", "XI": "MX", "XJ": "CA", "XK": "CA", "XL": "CA", "XM": "CA", "XN": "CA", "XO": "CA",
        "XP": "DK", "XQ": "CL", "XR": "CL", "XS": "CN", "XT": "BF", "XU": "KH", "XV": "VN", "XW": "LA",
        "XX": "MO", "XY": "MM", "XZ": "MM", "Y2": "DE", "Y3": "DE", "Y4": "DE", "Y5": "DE", "Y6": "DE",
        "Y7": "DE", "Y8": "DE", "Y9": "DE", "YA": "AF", "YB": "ID", "YC": "ID", "YD": "ID", "YE": "ID",
        "YF": "ID", "YG": "ID", "YH": "ID", "YI": "IQ", "YJ": "VU", "YK": "SY", "YL": "LV", "YM": "TR",
        "YN": "NI", "YO": "RO", "YP": "RO", "YQ": "RO", "YR": "RO", "YS": "SV", "YT": "RS", "YU": "RS",
        "YV": "VE", "YW": "VE", "YX": "VE", "YY": "VE", "Z2": "ZW", "Z3": "MK", "Z8": "SS", "ZA": "AL",
        "ZB": "GB", "ZC": "GB", "ZD": "GB", "ZE": "GB", "ZF": "GB", "ZG": "GB", "ZH": "GB", "ZI": "GB",
        "ZJ": "GB", "ZK": "NZ", "ZL": "NZ", "ZM": "NZ", "ZN": "GB", "ZO": "GB", "ZP": "PY", "ZQ": "GB",
        "ZR": "ZA", "ZS": "ZA", "ZT": "ZA", "ZU": "ZA", "ZV": "BR", "ZW": "BR", "ZX": "BR", "ZY": "BR",
        "ZZ": "BR"
    ]

    private static let singleCharacterAmateurAllocations: [Character: String] = [
        "B": "CN", "F": "FR", "G": "GB", "I": "IT", "K": "US",
        "M": "GB", "N": "US", "R": "RU", "W": "US"
    ]
}
