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
    func testEchoTestRemainsConnectedDuringDirectoryRefresh() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ECHOLINK_RUN_QSO_REFRESH_AUDIT"] == "1" else {
            throw XCTSkip("Live QSO refresh audit requires explicit opt-in")
        }
        let callsign = try XCTUnwrap(environment["ECHOLINK_LIVE_CALLSIGN"])
        let path = try XCTUnwrap(environment["ECHOLINK_LIVE_CREDENTIAL_PATH"])
        let password = try NSAttributedString(url: URL(fileURLWithPath: path),
            options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            .string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { XCTFail("Live credential is empty"); return }
        let configuration = EchoLinkProxyConfiguration(mode: .publicProxy, host: "", port: 8100, password: "PUBLIC")
        let directory = EchoLinkDirectoryService(configurationProvider: { configuration },
            saveCredentials: { _, _, _ in true })
        await directory.login(callsign: callsign, password: password, persistAsActive: false)
        guard directory.isLoggedIn,
              let echo = directory.stations.first(where: { $0.callsign.uppercased() == "*ECHOTEST*" }) else {
            await directory.logout()
            await directory.closeProxySession()
            XCTFail("Live EchoTest directory lookup failed")
            return
        }
        let connection = EchoLinkConnectionService(networkConfigurationProvider: { configuration })
        connection.authenticatedCallsign = callsign
        connection.setBackgroundMuted(true)
        connection.resolveProxySession = { try await directory.prepareProxySession(callsign: $0) }
        var voicePackets = 0
        connection.onAuditIncomingDatagram = { _ in voicePackets += 1 }
        await connection.connect(to: echo)
        for refresh in 1...3 {
            let refreshed = await directory.refresh()
            try await Task.sleep(for: .seconds(2))
            print("LIVE QSO REFRESH attempt=\(refresh) refreshed=\(refreshed) connected=\(connection.session?.state == .connected) voicePackets=\(voicePackets)")
            XCTAssertTrue(refreshed)
            XCTAssertEqual(connection.session?.state, .connected)
            XCTAssertNil(connection.error)
        }
        XCTAssertGreaterThan(voicePackets, 0)
        connection.onAuditIncomingDatagram = nil
        await connection.disconnect()
        await directory.logout()
        await directory.closeProxySession()
    }

    /// Recreate the directory after a process-like tunnel loss, without logging
    /// the old account off. Credentials remain inside the opted-in test host.
    func testSavedAccountRegistrationAfterRepeatedReloads() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ECHOLINK_RUN_RELOAD_AUDIT"] == "1" else {
            throw XCTSkip("Live reload audit requires explicit opt-in")
        }
        let callsign = try XCTUnwrap(environment["ECHOLINK_LIVE_CALLSIGN"])
        let path = try XCTUnwrap(environment["ECHOLINK_LIVE_CREDENTIAL_PATH"])
        let password = try NSAttributedString(url: URL(fileURLWithPath: path),
            options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            .string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { XCTFail("Live credential is empty"); return }
        let configuration = EchoLinkProxyConfiguration(mode: .publicProxy, host: "", port: 8100, password: "PUBLIC")
        for reload in 1...3 {
            let store = EchoLinkProxySessionStore(configurationProvider: { configuration })
            let directory = EchoLinkDirectoryService(proxySessionStore: store,
                configurationProvider: { configuration }, saveCredentials: { _, _, _ in true })
            let started = ContinuousClock.now
            await directory.login(callsign: callsign, password: password, persistAsActive: false)
            print("LIVE RELOAD attempt=\(reload) registered=\(directory.isLoggedIn) stations=\(directory.stations.count) elapsed=\(started.duration(to: .now)) error=\(directory.error?.localizedDescription ?? "none")")
            XCTAssertTrue(directory.isLoggedIn)
            XCTAssertFalse(directory.isLoading)
            XCTAssertFalse(directory.stations.isEmpty)
            if reload == 3 || !directory.isLoggedIn { await directory.logout() }
            await store.close()
            if !directory.isLoggedIn && reload != 3 { return }
        }
    }

    /// Opt-in, receive-only comparison against a requested live station. This
    /// uses the app's shared directory/proxy recovery path, including retries.
    func testRequestedStationWithPublicProxyRetry() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ECHOLINK_RUN_STATION_AUDIT"] == "1" else {
            throw XCTSkip("Live station audit requires explicit opt-in")
        }
        let requested = try XCTUnwrap(environment["ECHOLINK_LIVE_STATION"]).uppercased()
        let callsign = try XCTUnwrap(environment["ECHOLINK_LIVE_CALLSIGN"])
        let credentialPath = try XCTUnwrap(environment["ECHOLINK_LIVE_CREDENTIAL_PATH"])
        let password = try NSAttributedString(url: URL(fileURLWithPath: credentialPath),
            options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            .string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { XCTFail("Live credential is empty"); return }
        let configuration = EchoLinkProxyConfiguration(mode: .publicProxy, host: "", port: 8100, password: "PUBLIC")
        let store = EchoLinkProxySessionStore(configurationProvider: { configuration })
        let directory = EchoLinkDirectoryService(proxySessionStore: store, configurationProvider: { configuration },
            saveCredentials: { _, _, _ in true })
        await directory.login(callsign: callsign, password: password, persistAsActive: false)
        guard directory.isLoggedIn else {
            await directory.logout()
            XCTFail("Live directory login failed")
            return
        }
        let connection = EchoLinkConnectionService(networkConfigurationProvider: { configuration })
        connection.authenticatedCallsign = callsign
        connection.resolveProxySession = { try await directory.prepareProxySession(callsign: $0) }
        connection.reportUnansweredProxyHandshake = { await directory.reportUnansweredProxyHandshake($0) }
        let target = directory.stations.first { $0.callsign.uppercased() == requested }
        let echo = directory.stations.first { $0.callsign.uppercased() == "*ECHOTEST*" }
        guard let target, let echo else {
            await directory.logout()
            XCTFail("Requested station or EchoTest is absent from the live directory")
            return
        }
        var connected = false
        for attempt in 1...3 {
            // A retry replaces an unanswered public proxy before the control
            // call, so EchoTest verifies that same replacement tunnel.
            for station in [echo, target] {
                let proxy = try? await directory.prepareProxySession(callsign: callsign)
                let endpoint = await proxy?.configuration
                let started = ContinuousClock.now
                var inboundPackets = 0
                connection.onAuditIncomingDatagram = { _ in inboundPackets += 1 }
                await connection.connect(to: station)
                let didConnect = connection.session?.state == .connected
                if didConnect { try? await Task.sleep(for: .seconds(2)) }
                print("LIVE STATION attempt=\(attempt) station=\(station.callsign) connected=\(didConnect) proxy=\(endpoint?.host ?? "none") elapsed=\(started.duration(to: .now)) audioDatagrams=\(inboundPackets)")
                if station.callsign == target.callsign { connected = didConnect }
                await connection.disconnect()
            }
            if connected { break }
        }
        connection.onAuditIncomingDatagram = nil
        await directory.logout()
        await store.close()
        XCTAssertTrue(connected, "Requested station did not acknowledge through three public proxy attempts")
    }

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
