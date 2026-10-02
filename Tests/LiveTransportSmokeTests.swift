// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

/// Opt-in: place a password-only RTF named LiveCredential.rtf and a callsign
/// in LiveCallsign.txt in the test host's Documents directory, or set the
/// matching ECHOLINK_LIVE_CREDENTIAL_PATH and ECHOLINK_LIVE_CALLSIGN variables.
/// The credential is read in the test process and never logged.
@MainActor
final class LiveTransportSmokeTests: XCTestCase {
    func testEchoTestAcrossAvailableTransports() async throws {
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live EchoTest checks require explicit opt-in")
        }
        let path = ProcessInfo.processInfo.environment["ECHOLINK_LIVE_CREDENTIAL_PATH"]
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LiveCredential.rtf").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Live EchoLink credentials were not provided")
        }
        let password = try NSAttributedString(
            url: URL(fileURLWithPath: path),
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ).string.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(password.isEmpty)
        guard !password.isEmpty else { return }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let callsignPath = documents.appendingPathComponent("LiveCallsign.txt")
        let callsign = (ProcessInfo.processInfo.environment["ECHOLINK_LIVE_CALLSIGN"]
            ?? (try? String(contentsOf: callsignPath, encoding: .utf8)))?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let callsign, !callsign.isEmpty else {
            throw XCTSkip("Live EchoLink callsign was not provided")
        }
        let relayHost = (try? String(contentsOf: documents.appendingPathComponent("LiveRelayHost.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedMode = (ProcessInfo.processInfo.environment["ECHOLINK_LIVE_MODE"]
            ?? (try? String(contentsOf: documents.appendingPathComponent("LiveMode.txt"), encoding: .utf8)))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let customCandidates = try? await EchoLinkPublicProxyListClient.fetchReadyCandidates(
            preferredHost: nil, limit: 1
        )
        let customProxy = customCandidates?.first
        let modes = [EchoLinkNetworkMode.publicProxy, .customProxy, .relay, .direct]
            .filter { selectedMode == nil || selectedMode == $0.rawValue }
        var outcomes: [EchoLinkNetworkMode: String] = [:]
        for mode in modes {
            if mode == .customProxy && customProxy == nil {
                outcomes[mode] = "no-ready-public-proxy"
                continue
            }
            let configuration = EchoLinkProxyConfiguration(
                mode: mode,
                host: mode == .customProxy ? customProxy!.host : "",
                port: mode == .customProxy ? customProxy!.port : EchoLinkProxyConfiguration.defaultPort,
                password: mode == .publicProxy || mode == .customProxy ? "PUBLIC" : ""
            )
            let proxyStore = EchoLinkProxySessionStore(configurationProvider: { configuration })
            let directory = DirectoryClient()
            let relayClient = EchoLinkRelayClient(host: relayHost?.isEmpty == false
                ? relayHost! : EchoLinkRelayProtocol.host)
            let connection = EchoLinkConnectionService(
                relayClientFactory: { relayClient },
                networkConfigurationProvider: { configuration }
            )
            connection.authenticatedCallsign = callsign
            connection.resolveProxySession = { requestedCallsign in
                try await proxyStore.sessionForCurrentConfiguration(callsign: requestedCallsign)
            }
            connection.prepareRelayDirectory = { _, address in
                try await directory.advertiseRelay(address: address)
            }
            connection.finishRelayDirectory = { _, address in
                await directory.stopAdvertisingRelay(address: address)
            }

            do {
                let proxy = try await proxyStore.sessionForCurrentConfiguration(callsign: callsign)
                await directory.setProxySession(proxy)
                try await directory.login(callsign: callsign, password: password)
                let stations = try await directory.fetchStations()
                guard let echoTest = stations.first(where: {
                    $0.callsign.uppercased().contains("ECHOTEST")
                }) else {
                    outcomes[mode] = "station-missing"
                    await directory.logout()
                    await proxyStore.close()
                    continue
                }

                await connection.connect(to: echoTest)
                outcomes[mode] = connection.session?.state == .connected
                    ? "connected" : "handshake-failed-\(connection.error.map { safeDescription($0, password: password) } ?? "unknown")"
            } catch {
                outcomes[mode] = "directory-or-transport-failed-\(safeDescription(error, password: password))"
            }

            await connection.disconnect()
            await directory.logout()
            await proxyStore.close()
            print("LIVE TRANSPORT \(mode.rawValue): \(outcomes[mode] ?? "unknown")")
        }

        for mode in modes {
            XCTAssertEqual(outcomes[mode], "connected", "EchoTest did not connect through \(mode.title)")
        }
    }

    private func safeDescription(_ error: Error, password: String) -> String {
        [password, password.uppercased(), password.lowercased()].reduce(error.localizedDescription) {
            $0.replacingOccurrences(of: $1, with: "<redacted>")
        }
    }
}
