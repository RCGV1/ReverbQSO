// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import XCTest
#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif
@testable import ReverbQSO

/// Explicit account-authorized EchoTest audit, excluded from normal tests.
/// Password is consumed only in this process; reports contain audio and counters.
@MainActor
final class LiveAudioRoundTripTests: XCTestCase {
    /// Known speech through a localhost relay/echo peer; no directory or account access.
    func testLocalSpeexSpeechRoundTripAndLossRecovery() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ECHOLINK_RUN_LOCAL_SPEEX_AUDIT"] == "1" else {
            throw XCTSkip("Local hardware Speex audit requires explicit opt-in")
        }
        let root = URL(fileURLWithPath: try XCTUnwrap(environment["ECHOLINK_AUDIO_AUDIT_FOLDER"]))
        let source = try Self.sourceSamples(root.appendingPathComponent("speech.wav"))
        // The 48 kHz fixture is converted to 8 kHz, including its bounded
        // 20 ms converter tail before the final packet is padded.
        let expectedPackets = (source.count / 6 + 160 + 639) / 640
        for impaired in [false, true] {
            let folder = root.appendingPathComponent(impaired ? "loss-recovery" : "clean")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let socket = try BoundUDPSocket(localPort: 0)
            let audio = AudioEngine()
            let connection = EchoLinkConnectionService(
                relayClientFactory: { EchoLinkRelayClient(host: "127.0.0.1", port: socket.actualLocalPort) },
                networkConfigurationProvider: { .init(mode: .relay, host: "", port: 8100, password: "") },
                audioEngine: audio)
            connection.authenticatedCallsign = "N0TST"
            connection.callAccessPolicyProvider = { CallAccessPolicy() }
            let server = Task {
                let registration = try await Self.receiveLocal(socket)
                guard registration.sourceHost == "127.0.0.1" else { throw AuditError.invalidSource }
                try await socket.send(Data([4, 0, 0, 0, 0, 0, 0, 0, 0]),
                                      to: registration.sourceHost, port: registration.sourcePort)
                let handshake = try await Self.receiveLocal(socket)
                guard handshake.sourceHost == registration.sourceHost,
                      handshake.sourcePort == registration.sourcePort else { throw AuditError.invalidSource }
                let sdes = EchoLinkControlPacketCodec.buildSDESPacket(callsign: "*ECHOTEST*", advertiseSpeex: true)
                try await socket.send(Data([1, 198, 51, 100, 10, 0x14, 0x4F, 0x14, 0x4F]) + sdes,
                                      to: registration.sourceHost, port: registration.sourcePort)
                var packets: [Data] = []
                var wire: [[String: Double]] = []
                while packets.count < expectedPackets {
                    let datagram = try await Self.receiveLocal(socket)
                    guard datagram.sourceHost == registration.sourceHost,
                          datagram.sourcePort == registration.sourcePort else { continue }
                    guard datagram.data.count >= 19, datagram.data[0] == 1,
                          datagram.data[5] == 0x14, datagram.data[6] == 0x4E else { continue }
                    let packet = Data(datagram.data.dropFirst(7))
                    // The audio port also carries the initial station-info text.
                    guard let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet) else { continue }
                    guard case .speex = parsed.packet else { throw AuditError.invalidSource }
                    var row = Self.metadata(parsed.metadata)
                    row["time"] = ProcessInfo.processInfo.systemUptime
                    row["bytes"] = Double(packet.count)
                    wire.append(row)
                    packets.append(packet)
                }
                // Keep return speech clear of the final transmit drain.
                try await Task.sleep(for: .milliseconds(300))
                let began = ProcessInfo.processInfo.systemUptime
                let dropped: Set<Int> = impaired ? [40, 80, 81] : []
                var returned = 0
                func send(_ packet: Data) async throws {
                    try await socket.send(Data([1, 198, 51, 100, 10, 0x14, 0x4E, 0x14, 0x4E]) + packet,
                                          to: registration.sourceHost, port: registration.sourcePort)
                }
                for index in packets.indices {
                    let jitter = impaired ? Double((index % 3) - 1) * 0.003 : 0
                    let delay = began + Double(index) * 0.08 + jitter - ProcessInfo.processInfo.systemUptime
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    if dropped.contains(index) || (impaired && index == 100) { continue }
                    try await send(packets[index]); returned += 1
                    if impaired && index == 20 { try await send(packets[index]); returned += 1 }
                    if impaired && index == 101 { try await send(packets[100]); returned += 1 }
                }
                let result: [String: Any] = ["packets": wire, "transmitPackets": packets.count,
                    "returnDatagrams": returned, "intentionallyDroppedIndices": dropped.sorted(),
                    "duplicatedIndex": impaired ? 20 : -1, "reorderedIndex": impaired ? 100 : -1]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent("localhost-peer.json"))
            }
            do {
                await connection.connect(to: Station(callsign: "*ECHOTEST*", ipAddress: "198.51.100.10"))
                XCTAssertEqual(connection.session?.state, .connected)
                XCTAssertEqual(connection.transmitCodec, .speex)
                try await audit(codec: .speex, source: source, folder: folder, audio: audio, connection: connection)
                try await server.value
                let report = try XCTUnwrap(JSONSerialization.jsonObject(with:
                    Data(contentsOf: folder.appendingPathComponent("speex-report.json"))) as? [String: Any])
                let accepted = try XCTUnwrap(report["accepted"] as? [[String: Double]])
                XCTAssertEqual(accepted.count, expectedPackets - (impaired ? 3 : 0))
                let playback = try XCTUnwrap(report["playback"] as? [String: Int])
                XCTAssertEqual(playback["backlogTrims"], 0)
                XCTAssertEqual(playback["playoutDiscardedPackets"], 0)
                await connection.disconnect()
                socket.close()
            } catch {
                server.cancel(); socket.close()
                await connection.disconnect()
                throw error
            }
        }
    }

    private static func receiveLocal(_ socket: BoundUDPSocket) async throws -> BoundUDPSocket.Datagram {
        try await withThrowingTaskGroup(of: BoundUDPSocket.Datagram.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask { try await Task.sleep(for: .seconds(5)); throw AuditError.localPeerTimedOut }
            defer { group.cancelAll() }
            let result = try await group.next()
            return try XCTUnwrap(result)
        }
    }

    /// Replays a supplied arrival trace through real hardware without any network login.
    func testOfflineBurstTraceDoesNotEnterPlaybackResetLoop() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1",
              let fixturePath = environment["ECHOLINK_AUDIO_REPLAY_FOLDER"] else {
            throw XCTSkip("Hardware trace replay requires explicit opt-in and a fixture")
        }
        let folder = URL(fileURLWithPath: fixturePath)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: folder.appendingPathComponent("gsm-report.json"))) as? [String: Any])
        let blocks = try XCTUnwrap(report["decodedBlocks"] as? [[String: Double]])
        let firstTime = try XCTUnwrap(blocks.first?["time"])
        let file = try AVAudioFile(forReading: folder.appendingPathComponent("gsm-received.wav"),
                                  commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192))
        var samples: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let data = try XCTUnwrap(buffer.audioBufferList.pointee.mBuffers.mData)
                .assumingMemoryBound(to: Int16.self)
            samples += UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
        }
        XCTAssertEqual(samples.count, Int(file.length), "Replay fixture must be read in full")
        let audio = AudioEngine()
        audio.startPlayback()
        defer { audio.stopAll() }
        let outputFolder = URL(fileURLWithPath: try XCTUnwrap(environment["ECHOLINK_AUDIO_AUDIT_FOLDER"]))
        let capture = try audio.beginAuditRenderCapture(url: outputFolder.appendingPathComponent("offline-rendered.caf"))
        let began = ProcessInfo.processInfo.systemUptime
        for row in blocks {
            let deadline = began + (try XCTUnwrap(row["time"]) - firstTime)
            let delay = deadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            let offset = Int(try XCTUnwrap(row["offset"]))
            let count = Int(try XCTUnwrap(row["count"]))
            guard offset >= 0, offset + count <= samples.count else { throw AuditError.invalidSource }
            let metadata = EchoLinkVoicePacketMetadata(payloadType: UInt8(try XCTUnwrap(row["payloadType"])),
                sequenceNumber: UInt16(try XCTUnwrap(row["seq"])),
                timestamp: UInt32(try XCTUnwrap(row["timestamp"])), ssrc: UInt32(try XCTUnwrap(row["ssrc"])))
            audio.playReceivedPCM(Array(samples[offset..<(offset + count)]), metadata: metadata)
        }
        try await Task.sleep(for: .seconds(1))
        let rendered = await audio.endAuditRenderCapture(capture)
        let playback = audio.auditPlaybackSnapshot
        let result: [String: Any] = ["playback": playback, "renderCapture": rendered,
                                  "schedule": audio.auditPlaybackSchedule]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputFolder.appendingPathComponent("offline-report.json"))
        XCTAssertEqual(playback["timelineResets"], 0,
            "Overflow must preserve the running playback timeline")
        XCTAssertEqual(playback["playoutDiscardedPackets"], 0,
            "The captured proxy burst must survive the decoded playout queue")
        XCTAssertEqual(playback["overflowIncomingDrops"], 0,
            "Refill recovery must respect native output capacity")
        XCTAssertEqual(playback["backlogTrims"], 0)
        XCTAssertLessThan(playback["trimmedSamples"] ?? Int.max, samples.count / 4,
            "Playback recovery must preserve most of the supplied speech")
        XCTAssertEqual(rendered["droppedTapBuffers"], 0)
    }

    func testMicrophonePreparationCannotReopenAfterTeardown() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else {
            throw XCTSkip("Hardware audio audit requires explicit opt-in")
        }
        guard MicrophoneAccess.status == .granted else {
            throw XCTSkip("Hardware microphone permission has not been granted")
        }
        let audio = AudioEngine()
        audio.startPlayback()
        let preparation = Task { await audio.prepareCaptureInput(requestPermission: false) }
        // Allow preparation to enter its first suspension, then disconnect.
        await Task.yield()
        audio.stopAll()
        _ = await preparation.value
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(audio.isRunning, "Stale microphone preparation reopened the hardware graph")
        XCTAssertFalse(audio.isPreparingCapture)
        XCTAssertFalse(audio.isCapturing)
        let folder = URL(fileURLWithPath: try XCTUnwrap(environment["ECHOLINK_AUDIO_AUDIT_FOLDER"]))
        let result = ["runningAfterDisconnect": audio.isRunning,
                      "preparingAfterDisconnect": audio.isPreparingCapture,
                      "capturingAfterDisconnect": audio.isCapturing]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: folder.appendingPathComponent("hardware-teardown.json"))
    }

    func testKnownSpeechThroughProductionAudioAndTransport() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else {
            throw XCTSkip("Live audio audit requires explicit opt-in")
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        // A device test launched while locked can run without an active scene.
        // Do not treat a denied background activation as a speech-quality result.
        let foregroundDeadline = ProcessInfo.processInfo.systemUptime + 30
        while UIApplication.shared.applicationState != .active,
              ProcessInfo.processInfo.systemUptime < foregroundDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard UIApplication.shared.applicationState == .active else {
            throw XCTSkip("Physical audio audit needs the unlocked app in foreground")
        }
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
#endif
        let callsign = try XCTUnwrap(environment["ECHOLINK_LIVE_CALLSIGN"])
        let password: String
        if environment["ECHOLINK_AUDIT_USE_SAVED_ACCOUNT"] == "1" {
            // Physical-device audits consume the existing app Keychain item.
            // Credentials never travel through test arguments or output files.
            guard let saved = KeychainService.loadPassword(for: callsign), !saved.isEmpty else {
                throw AuditError.missingCredential
            }
            password = saved
        } else {
            let credentialURL = URL(fileURLWithPath: try XCTUnwrap(environment["ECHOLINK_LIVE_CREDENTIAL_PATH"]))
            password = try NSAttributedString(url: credentialURL,
                options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                .string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !password.isEmpty else { throw AuditError.missingCredential }
        let folder: URL
        if environment["ECHOLINK_AUDIT_DEVICE_FOLDER"] == "1" {
            folder = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
                .appendingPathComponent("AudioAudit", isDirectory: true)
        } else {
            folder = URL(fileURLWithPath: try XCTUnwrap(environment["ECHOLINK_AUDIO_AUDIT_FOLDER"]))
        }
        VoiceDiagnosticLog.reset()
        let sourceURL = folder.appendingPathComponent("speech.wav")
        let source = try Self.sourceSamples(sourceURL)
        let configuration = EchoLinkProxyConfiguration(mode: .publicProxy, host: "",
            port: EchoLinkProxyConfiguration.defaultPort, password: "PUBLIC")
        let proxyStore = EchoLinkProxySessionStore(configurationProvider: { configuration })
        let directory = DirectoryClient()
        let audio = AudioEngine()
        let connection = EchoLinkConnectionService(networkConfigurationProvider: { configuration }, audioEngine: audio)
        connection.authenticatedCallsign = callsign
        connection.resolveProxySession = { try await proxyStore.sessionForCurrentConfiguration(callsign: $0) }
        var liveStage = "proxy-login"
        do {
            let proxy = try await proxyStore.sessionForCurrentConfiguration(callsign: callsign)
            await directory.setProxySession(proxy)
            try await directory.login(callsign: callsign, password: password)
            liveStage = "directory-list"
            let stations = try await directory.fetchStations()
            guard let echo = stations.first(where: { $0.callsign.uppercased() == "*ECHOTEST*" }) else {
                throw AuditError.stationMissing
            }
            liveStage = "connect"
            await connection.connect(to: echo)
            guard connection.session?.state == .connected else { throw AuditError.connectionFailed }
            // Finish the real server's introduction before sending test speech.
            liveStage = "introduction"
            var lastArrival = ProcessInfo.processInfo.systemUptime
            var introArrivals: [[String: Double]] = []
            connection.onAuditIncomingDatagram = { data in
                lastArrival = ProcessInfo.processInfo.systemUptime
                if let packet = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(data) {
                    var row = Self.metadata(packet.metadata)
                    row["time"] = lastArrival
                    introArrivals.append(row)
                }
            }
            let introductionDeadline = lastArrival + 20
            while ProcessInfo.processInfo.systemUptime < introductionDeadline {
                if ProcessInfo.processInfo.systemUptime - lastArrival > 1.5 && !connection.isRemoteTransmitting { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let intro: [String: Any] = ["arrivals": introArrivals, "playback": audio.auditPlaybackSnapshot,
                                      "engineEvents": audio.auditEngineEvents]
            try JSONSerialization.data(withJSONObject: intro, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("introduction-report.json"))
#if targetEnvironment(macCatalyst)
            // Exercise the real microphone graph transition before network
            // replay. PTT remains inactive, so captured packets are discarded
            // by the connection service and only fixture PCM is transmitted.
            if MicrophoneAccess.status == .granted {
                liveStage = "native-microphone-preflight"
                let started = await audio.startCapture(requestPermission: false)
                let readinessDeadline = ProcessInfo.processInfo.systemUptime + 2
                while started, !audio.isCaptureReady,
                      ProcessInfo.processInfo.systemUptime < readinessDeadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                let ready = started && audio.isCaptureReady
                _ = await audio.stopCaptureAndFlushPendingBuffers()
                guard ready else { throw AuditError.transmissionUnavailable }
            }
#endif
            let codecs: [EchoLinkVoiceCodec] = connection.transmitCodec == .speex ? [.gsm, .speex] : [.gsm]
            let rounds = min(3, max(1, Int(environment["ECHOLINK_AUDIO_AUDIT_ROUNDS"] ?? "1") ?? 1))
            for round in 1...rounds {
                let output = rounds == 1 ? folder : folder.appendingPathComponent("round-\(round)", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for codec in codecs {
                    liveStage = "echo-round-\(round)"
                    try await audit(codec: codec, source: source, folder: output, audio: audio, connection: connection)
                    try await Task.sleep(for: .seconds(2))
                }
            }
            await connection.disconnect()
            await directory.logout()
            await proxyStore.close()
        } catch {
            let failure: [String: Any] = ["stage": liveStage, "errorDomain": (error as NSError).domain,
                "errorCode": (error as NSError).code, "playback": audio.auditPlaybackSnapshot,
                "engineEvents": audio.auditEngineEvents]
            // Only state and numeric error details; never an authentication description.
            try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("failure-report.json"))
            await connection.disconnect()
            await directory.logout()
            await proxyStore.close()
            // Never expose an authentication error's associated data.
            throw AuditError.auditFailed
        }
    }

    private func audit(codec: EchoLinkVoiceCodec, source: [Float], folder: URL,
                       audio: AudioEngine, connection: EchoLinkConnectionService) async throws {
        let label = codec == .speex ? "speex" : "gsm"
        var arrivals: [[String: Double]] = []
        var accepted: [[String: Double]] = []
        var decoded: [Int16] = []
        var blocks: [[String: Double]] = []
        var lastMetadata: EchoLinkVoicePacketMetadata?
        var lastRX = 0.0
        var firstRX: Double?
        connection.onAuditIncomingDatagram = { data in
            guard let packet = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(data) else { return }
            var row = Self.metadata(packet.metadata)
            row["time"] = ProcessInfo.processInfo.systemUptime
            row["bytes"] = Double(data.count)
            arrivals.append(row)
        }
        connection.onAuditAcceptedPacket = { metadata in
            lastMetadata = metadata
            var row = Self.metadata(metadata)
            row["time"] = ProcessInfo.processInfo.systemUptime
            accepted.append(row)
        }
        audio.onRecordingPCM = { samples in
            guard connection.session?.isPTTActive == false else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if firstRX == nil { firstRX = now }
            lastRX = now
            var row = Self.metadata(lastMetadata)
            row["time"] = now
            row["offset"] = Double(decoded.count)
            row["count"] = Double(samples.count)
            blocks.append(row)
            decoded.append(contentsOf: samples)
        }
        let baselinePlayback = audio.auditPlaybackSnapshot
        let baselineTransport = connection.auditTransportSnapshot
        let baselineInbound = await connection.auditInboundBufferSnapshot()
        let capture = try audio.beginAuditRenderCapture(url: folder.appendingPathComponent("\(label)-rendered.caf"))
        guard connection.beginEchoTestAuditTransmission(codec: codec) else {
            _ = await audio.endAuditRenderCapture(capture)
            throw AuditError.transmissionUnavailable
        }
        let processor = CaptureDSPProcessor(label: "org.reverbqso.live-audit-dsp")
        processor.begin(generation: 1)
        let configuration = CaptureDSPProcessor.Configuration(codec: codec,
            gainMode: .automatic, manualGainMultiplier: 1)
        var transmittedPCM: [Int16] = []
        var payloads: [Data] = []
        let began = ProcessInfo.processInfo.systemUptime
        let strideFrames = 4_800 // Actual Mac tap trace: approximately 100 ms.
        for offset in stride(from: 0, to: source.count, by: strideFrames) {
            let end = min(source.count, offset + strideFrames)
            // Timestamp the callback when a physical tap would deliver it.
            let deadline = began + Double(end) / 48_000
            try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            let result: CaptureDSPProcessor.Result? = await withCheckedContinuation { continuation in
                processor.submit(normalizedSamples: Array(source[offset..<end]), sampleRate: 48_000,
                    generation: 1, capturedAt: ProcessInfo.processInfo.systemUptime,
                    configuration: configuration) { continuation.resume(returning: $0) }
            }
            guard let result else { throw AuditError.dspRejected }
            transmittedPCM += result.transmittedPCM
            for packet in result.encodedPackets { payloads.append(packet); audio.onCapturedAudio?(packet) }
        }
        let tail = await processor.flush(generation: 1)
        transmittedPCM += tail.transmittedPCM
        for packet in tail.encodedPackets { payloads.append(packet); audio.onCapturedAudio?(packet) }
        processor.end(generation: 1)
        await connection.endEchoTestAuditTransmission()
        let released = ProcessInfo.processInfo.systemUptime
        let replyDeadline = released + Double(source.count) / 48_000 + 15
        while ProcessInfo.processInfo.systemUptime < replyDeadline {
            if firstRX != nil && ProcessInfo.processInfo.systemUptime - lastRX > 1.5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let rendered = await audio.endAuditRenderCapture(capture)
        let schedule = audio.auditPlaybackSchedule
        var playback = audio.auditPlaybackSnapshot
        playback["playoutDiscardedPacketsTotal"] = playback["playoutDiscardedPackets"]
        playback["playoutDiscardedPackets"] = max(0, (playback["playoutDiscardedPackets"] ?? 0)
            - (baselinePlayback["playoutDiscardedPackets"] ?? 0))
        let transport = connection.auditTransportSnapshot
        let inbound = await connection.auditInboundBufferSnapshot()
        var localDecoded: [Int16] = []
        if codec == .speex {
            let decoder = SpeexCodec()
            for packet in payloads { localDecoded += decoder.decodePacket(packet) ?? [] }
        } else {
            let decoder = GSMCodec()
            var pending = Data()
            for data in payloads {
                pending.append(GSMCodec.stripHeader(data) ?? Data())
                for payload in EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &pending) {
                    localDecoded += decoder.decodePacket(payload)
                }
            }
        }
        try Self.writePCM(transmittedPCM, to: folder.appendingPathComponent("\(label)-tx-processed.wav"))
        try Self.writePCM(localDecoded, to: folder.appendingPathComponent("\(label)-local-codec.wav"))
        try Self.writePCM(decoded, to: folder.appendingPathComponent("\(label)-received.wav"))
        let report: [String: Any] = ["codec": label, "callbackMilliseconds": 100,
            "sourceDuration": Double(source.count) / 48_000, "began": began, "released": released,
            "firstRX": firstRX ?? -1, "lastRX": lastRX, "arrivals": arrivals,
            "accepted": accepted, "decodedBlocks": blocks, "transport": transport,
            "playback": playback, "renderCapture": rendered, "schedule": schedule,
            "baselinePlayback": baselinePlayback, "baselineTransport": baselineTransport,
            "baselineInboundBuffers": baselineInbound, "inboundBuffers": inbound,
            "engineEvents": audio.auditEngineEvents]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("\(label)-report.json"))
        print("LIVE AUDIO AUDIT \(label): queued=\(transport["queued"] ?? -1) sent=\(transport["sent"] ?? -1) receivedSamples=\(decoded.count) renderTrims=\(playback["backlogTrims"] ?? -1)")
        XCTAssertFalse(decoded.isEmpty, "EchoTest did not return audio")
        // Source delivery can be interrupted before reaching the transport. A
        // matching queue/sent count alone would pass a truncated transmission.
        let expectedPackets = (localDecoded.count + 639) / 640
        XCTAssertEqual(transport["queued"], expectedPackets, "Source transmission was interrupted")
        XCTAssertEqual(transport["queued"], transport["sent"], "TX queue lost packets")
        XCTAssertEqual(playback["actualEngineRunning"], 1, "Echo arrived while the hardware graph was stopped")
        XCTAssertGreaterThan(playback["scheduledSamples"] ?? 0, 0, "Return audio never reached playback")
        XCTAssertEqual(rendered["writeErrors"], 0, "Mixer capture could not be saved")
        XCTAssertEqual(rendered["droppedTapBuffers"], 0, "Audit capture fell behind")
        connection.onAuditIncomingDatagram = nil
        connection.onAuditAcceptedPacket = nil
        audio.onRecordingPCM = nil
    }

    private static func metadata(_ value: EchoLinkVoicePacketMetadata?) -> [String: Double] {
        guard let value else { return [:] }
        return ["seq": Double(value.sequenceNumber), "timestamp": Double(value.timestamp),
                "ssrc": Double(value.ssrc), "payloadType": Double(value.payloadType)]
    }

    private static func sourceSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 48_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length)) else { throw AuditError.invalidSource }
        try file.read(into: buffer)
        let voice = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]),
                                             count: min(Int(buffer.frameLength), 480_000)))
        var source = [Float](repeating: 0, count: 9_600)
        source += (0..<14_400).map { n in
            let t = Double(n) / 48_000
            return Float(0.15 * sin(2 * .pi * (400 * t + 1_000 * t * t)))
        }
        source += voice
        source += [Float](repeating: 0, count: 19_200)
        // Full 80 ms codec packets avoid ambiguous partial-frame padding.
        while source.count % 3_840 != 0 { source.append(0) }
        return source
    }

    private static func writePCM(_ samples: [Int16], to url: URL) throws {
        guard !samples.isEmpty else { throw AuditError.emptyAudio }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 8_000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { memcpy(buffer.mutableAudioBufferList.pointee.mBuffers.mData!, base, bytes.count) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                  commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
    }

    private enum AuditError: Error {
        case missingCredential, stationMissing, connectionFailed, auditFailed
        case transmissionUnavailable, dspRejected, invalidSource, localPeerTimedOut, emptyAudio
    }
}
