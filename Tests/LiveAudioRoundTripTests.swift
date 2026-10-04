// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import XCTest
@testable import ReverbQSO

/// Explicit account-authorized EchoTest audit, excluded from normal tests.
/// Password is consumed only in this process; reports contain audio and counters.
@MainActor
final class LiveAudioRoundTripTests: XCTestCase {
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
        XCTAssertLessThanOrEqual(playback["backlogTrims"] ?? Int.max, 10,
            "A single burst must not restart playback for every following packet")
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
        let credentialURL = URL(fileURLWithPath: try XCTUnwrap(environment["ECHOLINK_LIVE_CREDENTIAL_PATH"]))
        let password = try NSAttributedString(url: credentialURL,
            options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            .string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { throw AuditError.missingCredential }
        let callsign = try XCTUnwrap(environment["ECHOLINK_LIVE_CALLSIGN"])
        let folder = URL(fileURLWithPath: try XCTUnwrap(environment["ECHOLINK_AUDIO_AUDIT_FOLDER"]))
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
        do {
            let proxy = try await proxyStore.sessionForCurrentConfiguration(callsign: callsign)
            await directory.setProxySession(proxy)
            try await directory.login(callsign: callsign, password: password)
            let stations = try await directory.fetchStations()
            guard let echo = stations.first(where: { $0.callsign.uppercased() == "*ECHOTEST*" }) else {
                throw AuditError.stationMissing
            }
            await connection.connect(to: echo)
            guard connection.session?.state == .connected else { throw AuditError.connectionFailed }
            // Finish the real server's introduction before sending test speech.
            var lastArrival = ProcessInfo.processInfo.systemUptime
            connection.onAuditIncomingDatagram = { _ in lastArrival = ProcessInfo.processInfo.systemUptime }
            let introductionDeadline = lastArrival + 20
            while ProcessInfo.processInfo.systemUptime < introductionDeadline {
                if ProcessInfo.processInfo.systemUptime - lastArrival > 1.5 && !connection.isRemoteTransmitting { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let codecs: [EchoLinkVoiceCodec] = connection.transmitCodec == .speex ? [.gsm, .speex] : [.gsm]
            for codec in codecs {
                try await audit(codec: codec, source: source, folder: folder, audio: audio, connection: connection)
                try await Task.sleep(for: .seconds(2))
            }
            await connection.disconnect()
            await directory.logout()
            await proxyStore.close()
        } catch {
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
        if !tail.isEmpty { payloads.append(tail); audio.onCapturedAudio?(tail) }
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
        let playback = audio.auditPlaybackSnapshot
        let transport = connection.auditTransportSnapshot
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
            "playback": playback, "renderCapture": rendered, "schedule": schedule]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("\(label)-report.json"))
        print("LIVE AUDIO AUDIT \(label): queued=\(transport["queued"] ?? -1) sent=\(transport["sent"] ?? -1) receivedSamples=\(decoded.count) renderTrims=\(playback["backlogTrims"] ?? -1)")
        XCTAssertFalse(decoded.isEmpty, "EchoTest did not return audio")
        XCTAssertEqual(transport["queued"], transport["sent"], "TX queue lost packets")
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
        case transmissionUnavailable, dspRejected, invalidSource
    }
}
