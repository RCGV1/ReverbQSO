// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Deterministic local matching for DEMO/demo. It never enters the public CQ queue.
@MainActor
struct DemoCallCQBackend: CallCQBackend {
    let stations: [Station]
    let delay: Duration
    let policy: CallAccessPolicy

    init(
        stations: [Station],
        delay: Duration = .seconds(2),
        policy: CallAccessPolicy = CallAccessPolicy()
    ) {
        self.stations = stations
        self.delay = delay
        self.policy = policy
    }

    func waitForMatch(preferences: CallCQPreferences) async throws -> Station {
        let outgoingPolicy = policy.applyToOutgoing
        guard !outgoingPolicy || !policy.useAllowList else { throw CallCQBackendError.allowListEnabled }
        let blockedCallsigns = outgoingPolicy
            ? Set(policy.blockedCallsigns.map(CallAccessPolicy.normalize)) : []
        let blockedCountries = outgoingPolicy
            ? Set(policy.blockedCountries.map(CallAccessPolicy.normalize)) : []
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        guard preferences.languageCodes.contains("en"),
              let station = stations.first(where: { station in
                  preferences.nodeTypes.contains(station.type)
                      && (!outgoingPolicy || policy.allowedTypes.contains(station.type))
                      && station.type != .conference
                      && (preferences.countryCodes.isEmpty
                          || station.callSignCountryCode.map(preferences.countryCodes.contains) == true)
                      && !blockedCallsigns.contains(CallAccessPolicy.normalize(station.callsign))
                      && station.callSignCountryCode.map {
                          !blockedCountries.contains(CallAccessPolicy.normalize($0))
                      } != false
              }) else {
            try await Task.sleep(for: .seconds(86_400))
            throw CancellationError()
        }
        return station
    }

    func cancel() async {}
}
