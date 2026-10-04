// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation
import XCTest
@testable import ReverbQSO

@MainActor
final class StationConnectionLatencyTests: XCTestCase {
    func testAcknowledgementCompletesWithoutPollingDelay() async throws {
        try await exerciseHandshake(dropFirst: false)
    }

    func testLostFirstHandshakeRetriesWithinTwoSeconds() async throws {
        try await exerciseHandshake(dropFirst: true)
    }

    private func exerciseHandshake(dropFirst: Bool) async throws {
        let relay = try BoundUDPSocket(localPort: 0)
        defer { relay.close() }
        let service = EchoLinkConnectionService(
            relayClientFactory: { EchoLinkRelayClient(host: "127.0.0.1", port: relay.actualLocalPort) },
            networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") })
        service.authenticatedCallsign = "N0TST"
        service.callAccessPolicyProvider = { CallAccessPolicy() }
        service.setBackgroundMuted(true) // Measure network setup without starting hardware audio.
        let clock = ContinuousClock()
        var acknowledgedAt: ContinuousClock.Instant?
        let stateObserver = service.$session.sink { session in
            if session?.state == .connected { acknowledgedAt = clock.now }
        }
        defer { stateObserver.cancel() }
        let connected = expectation(description: "Station acknowledged and connect returned")
        let server = Task {
            let registration = try await relay.receive()
            try await relay.send(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]),
                                 to: registration.sourceHost, port: registration.sourcePort)
            var controlRequests = 0
            var firstSentAt: ContinuousClock.Instant?
            while !Task.isCancelled {
                let request = try await relay.receive()
                guard request.data.count >= 19,
                      request.data[0] == 1, request.data[5] == 0x14, request.data[6] == 0x4F,
                      case .sdes = EchoLinkControlPacketCodec.parseEvents(from: Data(request.data.dropFirst(7))).first
                else { continue }
                controlRequests += 1
                print("Latency fixture dropFirst=\(dropFirst) controlRequests=\(controlRequests)")
                if firstSentAt == nil { firstSentAt = clock.now }
                // Each attempt sends two SDES copies (one from each local path).
                if dropFirst && controlRequests <= 2 { continue }
                if dropFirst {
                    XCTAssertLessThan(firstSentAt!.duration(to: clock.now), .seconds(2))
                } else {
                    // Reply during the old 100 ms polling sleep.
                    try await Task.sleep(for: .milliseconds(20))
                }
                let sdes = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "K1MOCK")
                try await relay.send(Data([1, 198, 51, 100, 10, 0xC3, 0x50, 0x14, 0x4F]) + sdes,
                                     to: registration.sourceHost, port: registration.sourcePort)
                return
            }
        }
        let operation = Task {
            await service.connect(to: Station(callsign: "K1MOCK", ipAddress: "198.51.100.10"))
            if service.session?.state == .connected {
                if let acknowledgedAt {
                    let delay = acknowledgedAt.duration(to: clock.now)
                    print("Handshake post-ack completion delay: \(delay)")
                    XCTAssertLessThan(delay, .milliseconds(60))
                }
                connected.fulfill()
            }
        }
        defer { operation.cancel(); server.cancel() }
        await fulfillment(of: [connected], timeout: 3)
        operation.cancel()
        server.cancel()
        await operation.value
        XCTAssertEqual(service.session?.state, .connected)
        if service.session?.state == .connected { await service.disconnect() }
    }
}
