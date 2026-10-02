// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reserved credentials for on-device App Review access. These identities never
/// authenticate with EchoLink and are never written to the production Keychain.
enum LocalDemoAccount {
    static let username = "DEMO"
    static let secondUsername = "DEMO2"
    static let password = "demo"
    static let transport = EchoLinkEffectiveTransport.explicit(
        EchoLinkProxyConfiguration(mode: .relay, host: "", port: 8100, password: "")
    )

    static func normalizedUsername(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func isDemoUsername(_ value: String) -> Bool {
        [username, secondUsername].contains(normalizedUsername(value))
    }

    // Stable IDs keep selection, favorites and history consistent across refreshes.
    // Documentation-only addresses are an additional safeguard against live use.
    static let stations: [Station] = [
        Station(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!, callsign: "*ECHOTEST*", description: "Audio echo test", ipAddress: "192.0.2.1", type: .conference, nodeNumber: 9999),
        Station(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!, callsign: "N0DEMO-R", description: "Mountain repeater • 146.940 MHz", ipAddress: "192.0.2.2", type: .repeater, nodeNumber: 900002),
        Station(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000003")!, callsign: "*ROUNDTABLE*", description: "Community roundtable", ipAddress: "192.0.2.3", type: .conference, nodeNumber: 900003),
        Station(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000004")!, callsign: "N1DEMO", description: "Alex • Portable station", ipAddress: "192.0.2.4", type: .user, nodeNumber: 900004),
        Station(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000005")!, callsign: "N2DEMO-L", description: "Community radio link", ipAddress: "192.0.2.5", type: .link, nodeNumber: 900005),
        Station(id: UUID(uuidString: "D0000000-0000-0000-0000-000000000006")!, callsign: "N3DEMO-R", description: "Valley repeater • 443.250 MHz", ipAddress: "192.0.2.6", type: .repeater, isBusy: true, nodeNumber: 900006)
    ]

    static let participants: [ActiveNodeParticipant] = [
        ActiveNodeParticipant(callsign: "N1DEMO", displayName: "Alex", isTransmitting: false, lastActivity: Date()),
        ActiveNodeParticipant(callsign: "N2DEMO-L", displayName: "Community radio link", isTransmitting: false, lastActivity: Date()),
        ActiveNodeParticipant(callsign: "N0DEMO-R", displayName: "Mountain repeater", isTransmitting: false, lastActivity: Date())
    ]

    static func messages(for station: Station, account: String) -> [ChatMessage] {
        [
            ChatMessage(sender: station.callsign, body: station.type == .repeater
                ? "Mountain repeater\n146.940 MHz • −600 kHz • 100.0 Hz\nWelcome. Please leave a pause between transmissions."
                : "Welcome to \(station.description).", isInformational: true),
            ChatMessage(sender: "N1DEMO", body: "Hello \(account)! Good to hear you.")
        ]
    }
}
