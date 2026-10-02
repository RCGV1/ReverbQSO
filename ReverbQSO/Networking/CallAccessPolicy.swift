// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

enum CallDirection { case incoming, outgoing }

/// Global operator preferences. Callsign-country is a prefix classification,
/// not the physical location of a visiting operator.
struct CallAccessPolicy: Codable, Equatable {
    var applyToIncoming = true
    var applyToOutgoing = true
    var allowedTypes = Set(Station.StationType.allCases)
    var blockedCallsigns: Set<String> = []
    var useAllowList = false
    var allowedCallsigns: Set<String> = []
    var blockedCountries: Set<String> = []

    func rejection(for station: Station, direction: CallDirection, countryCode: String?) -> String? {
        guard direction == .incoming ? applyToIncoming : applyToOutgoing else { return nil }
        let callsign = Self.normalize(station.callsign)
        if Set(blockedCallsigns.map(Self.normalize)).contains(callsign) {
            return "This callsign is blocked in Call Restrictions."
        }
        if useAllowList && !Set(allowedCallsigns.map(Self.normalize)).contains(callsign) {
            return "This callsign is not in your allowed callsigns."
        }
        if !allowedTypes.contains(station.type) {
            return "Connections to this station type are disabled in Call Restrictions."
        }
        if let countryCode, Set(blockedCountries.map(Self.normalize)).contains(Self.normalize(countryCode)) {
            return "This callsign's country is blocked in Call Restrictions."
        }
        return nil
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

@MainActor
final class CallAccessPolicyStore: ObservableObject {
    @Published var policy: CallAccessPolicy {
        didSet {
            if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: key) }
        }
    }
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, demo: Bool = false) {
        self.defaults = defaults
        key = Self.key(demo: demo)
        policy = Self.load(defaults: defaults, demo: demo)
    }
    static func load(defaults: UserDefaults = .standard, demo: Bool = false) -> CallAccessPolicy {
        guard let data = defaults.data(forKey: key(demo: demo)),
              let policy = try? JSONDecoder().decode(CallAccessPolicy.self, from: data) else {
            return CallAccessPolicy()
        }
        return policy
    }
    private static func key(demo: Bool) -> String {
        demo ? "reverbqso.demo.callRestrictions" : "reverbqso.callRestrictions"
    }
}
