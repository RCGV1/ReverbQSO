// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ReverbQSO

/// Virtual-time renderer around production receive components; no audio device or account.
final class SvxLinkImpairmentAuditTests: XCTestCase {
    private enum Impairment: String, CaseIterable {
        case clean, jitter, reordered, duplicated, singleLoss, burstLoss, wifiBurst, longStall
    }
    private struct Arrival {
        let time: Double
        let packet: Data
    }
    private struct Result {
        var accepted = 0
        var missing = 0
        var late = 0
        var discarded = 0
        var syntheticSamples = 0
        var silenceSeconds = 0.0
        var maximumLead = 0.0
        var maximumWait = 0.0
        var decoded: [Int16] = []
        var rendered: [Int16] = []
    }

    func testSvxLinkGSMAndSpeexAcrossDeterministicWifiTraces() throws {
        for codec in [EchoLinkVoiceCodec.gsm, .speex] {
            for timestamped in [false, true] {
                let fixture = try packets(codec: codec, timestamped: timestamped)
                let reference = try referenceDecode(fixture, codec: codec)
                for impairment in Impairment.allCases {
                    let result = try render(trace(fixture, impairment: impairment), codec: codec)
                    let label = "\(codec)-\(timestamped ? "timestamped" : "svx-zero-time")-\(impairment.rawValue)"
                    print("SVXLINK_AUDIT \(label) accepted=\(result.accepted) missing=\(result.missing) late=\(result.late) discarded=\(result.discarded) syntheticMs=\(Double(result.syntheticSamples) / 8) gapsMs=\(result.silenceSeconds * 1000) maxLeadMs=\(result.maximumLead * 1000) maxWaitMs=\(result.maximumWait * 1000)")
                    XCTAssertFalse(result.rendered.isEmpty, label)
                    XCTAssertLessThanOrEqual(result.maximumLead, 0.323, label)
                    XCTAssertLessThanOrEqual(result.maximumWait, 0.242, label)
                    XCTAssertLessThanOrEqual(result.discarded, 4, label)
                    XCTAssertLessThan(Double(result.rendered.filter { abs(Int($0)) >= 32767 }.count)
                        / Double(result.rendered.count), 0.001, label)
                    switch impairment {
                    case .clean, .jitter, .reordered, .duplicated:
                        XCTAssertEqual(result.accepted, fixture.count, label)
                        XCTAssertEqual(result.missing, 0, label)
                        XCTAssertEqual(result.discarded, 0, label)
                        XCTAssertEqual(result.decoded, reference, "Lossless transport changed decoder input: \(label)")
                        // The reordered packet is 100 ms late, beyond the 40 ms
                        // startup cushion. Allow that outage plus one refill.
                        XCTAssertLessThan(result.silenceSeconds, impairment == .reordered ? 0.160 : 0.002, label)
                    case .singleLoss:
                        XCTAssertEqual(result.accepted, fixture.count - 1, label)
                        XCTAssertEqual(result.missing, 1, label)
                    case .burstLoss:
                        XCTAssertEqual(result.accepted, fixture.count - 2, label)
                        XCTAssertEqual(result.missing, 2, label)
                    case .wifiBurst, .longStall:
                        XCTAssertEqual(result.accepted, fixture.count, label)
                        XCTAssertEqual(result.missing, 0, label)
                        // Every trace ends in a clean tail; the renderer must recover.
                        XCTAssertEqual(Array(result.decoded.suffix(640)), Array(reference.suffix(640)), label)
                    }
                    if !timestamped, [.clean, .burstLoss, .longStall].contains(impairment) {
                        let attachment = XCTAttachment(data: wav(result.rendered), uniformTypeIdentifier: "com.microsoft.waveform-audio")
                        attachment.name = "\(label).wav"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
        }
    }

    func testLossRecoveryDoesNotPutSyntheticSpeechAheadOfQueuedRealSpeech() {
        let speech = (0..<640).map { Int16(10_000 * sin(Double($0) * .pi / 32)) }
        func metadata(_ sequence: UInt16) -> EchoLinkVoicePacketMetadata {
            .init(payloadType: 3, sequenceNumber: sequence, timestamp: 0, ssrc: 0)
        }
        func firstSpeechStart(budgeted: Bool) -> Double {
            let smoother = ReceiveSpeechSmoother()
            _ = smoother.process(speech, metadata: metadata(100), now: 0)
            let budget = budgeted ? ReceivePlaybackQueue().concealmentSampleBudget(
                receivedSamples: 640, remainingSamples: 1920) : 1280
            let recovered = smoother.process(speech, metadata: metadata(103), now: 0.010,
                maximumConcealmentSamples: budget)
            var playout = ReceiveAdaptivePlayoutBuffer()
            playout.enqueue(recovered, networkSampleCount: 640, now: 0.010, rendererLeadSamples: 1920)
            for tick in 10...500 {
                let now = Double(tick) / 1000
                let lead = max(0, Int(((0.250 - now) * 8000).rounded()))
                let capacity = Int(Double(max(0, 2576 - lead)) / 1.005)
                if let ready = playout.drain(now: now, maximumSamples: capacity).first {
                    return max(now, 0.250) + Double(ready.count - speech.count) / 8000
                }
            }
            XCTFail("Recovery packet never reached renderer")
            return .infinity
        }
        let previous = firstSpeechStart(budgeted: false)
        let current = firstSpeechStart(budgeted: true)
        print("SVXLINK_RECOVERY freshSpeechStartMs before=\(previous * 1000) after=\(current * 1000)")
        XCTAssertEqual(previous - current, 0.160, accuracy: 0.002)
    }

    func testNativeHeadroomRecoversLateSpeechWithoutPlaybackUnderrun() throws {
        for codec in [EchoLinkVoiceCodec.gsm, .speex] {
            for timestamped in [false, true] {
                let fixture = try packets(codec: codec, timestamped: timestamped)
                let reference = try referenceDecode(fixture, codec: codec)
                let arrivals = trace(fixture, impairment: .reordered, reorderDelay: 0.140)
                // Model speech already scheduled by preceding traffic. This is
                // renderer lead, not a new startup delay imposed on this stream.
                let prebufferedSpeech = Array(reference.prefix(1920))
                let fixed = try render(arrivals, codec: codec, nativeReorderHeadroom: false,
                    prebufferedSamples: prebufferedSpeech)
                let adaptive = try render(arrivals, codec: codec, nativeReorderHeadroom: true,
                    prebufferedSamples: prebufferedSpeech)
                let label = "\(codec)-\(timestamped ? "timestamped" : "svx-zero-time")"

                print("SVXLINK_HEADROOM \(label) acceptedBefore=\(fixed.accepted) acceptedAfter=\(adaptive.accepted) missingBefore=\(fixed.missing) missingAfter=\(adaptive.missing) gapsBeforeMs=\(fixed.silenceSeconds * 1000) gapsAfterMs=\(adaptive.silenceSeconds * 1000)")
                XCTAssertEqual(fixed.accepted, fixture.count - 1, label)
                XCTAssertEqual(fixed.missing, 1, label)
                XCTAssertEqual(fixed.late, 1, label)
                XCTAssertEqual(adaptive.accepted, fixture.count, label)
                XCTAssertEqual(adaptive.missing, 0, label)
                XCTAssertEqual(adaptive.late, 0, label)
                XCTAssertEqual(adaptive.decoded, reference, "Every real packet must reach the decoder in order: \(label)")
                XCTAssertEqual(adaptive.syntheticSamples, 0, label)
                XCTAssertEqual(adaptive.discarded, 0, label)
                XCTAssertLessThan(adaptive.silenceSeconds, 0.002, label)
                XCTAssertLessThanOrEqual(adaptive.maximumLead, 0.323, label)
                XCTAssertLessThanOrEqual(adaptive.maximumWait, 0.242, label)

                if !timestamped {
                    for (policy, result) in [("fixed", fixed), ("headroom", adaptive)] {
                        let attachment = XCTAttachment(data: wav(result.rendered), uniformTypeIdentifier: "com.microsoft.waveform-audio")
                        attachment.name = "\(label)-late-reorder-\(policy).wav"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
        }
    }

    func testBundledSpokenWelcomeUnderNetworkImpairment() throws {
        let gsmPayloads = LocalDemoAnnouncement.echoTestPackets()
        XCTAssertGreaterThan(gsmPayloads.count, 50, "Spoken fixture must be present, not silently skipped")
        let welcomeDecoder = GSMCodec()
        let spokenPCM = gsmPayloads.flatMap { welcomeDecoder.decodePacket($0) }
        XCTAssertGreaterThan(spokenPCM.map { abs(Int($0)) }.max() ?? 0, 1_000)

        for codec in [EchoLinkVoiceCodec.gsm, .speex] {
            // The existing welcome is synthesized speech already encoded as GSM.
            // Speex uses a transcode; comparisons use that codec's own clean decode.
            let payloads = codec == .gsm ? gsmPayloads : try XCTUnwrap(SpeexCodec().encode(spokenPCM))
            let fixture = packetize(payloads, codec: codec, timestamped: false)
            let reference = try referenceDecode(fixture, codec: codec)
            for impairment: Impairment in [.clean, .jitter, .burstLoss, .longStall] {
                let result = try render(trace(fixture, impairment: impairment), codec: codec)
                let label = "spoken-\(codec)-\(impairment.rawValue)"
                print("SVXLINK_SPOKEN \(label) accepted=\(result.accepted) missing=\(result.missing) discarded=\(result.discarded) gapsMs=\(result.silenceSeconds * 1000)")
                XCTAssertEqual(result.accepted, fixture.count - (impairment == .burstLoss ? 2 : 0), label)
                XCTAssertEqual(result.missing, impairment == .burstLoss ? 2 : 0, label)
                XCTAssertLessThanOrEqual(result.discarded, impairment == .longStall ? 4 : 0, label)
                XCTAssertLessThanOrEqual(result.maximumLead, 0.323, label)
                XCTAssertLessThanOrEqual(result.maximumWait, 0.242, label)
                XCTAssertLessThan(result.silenceSeconds, impairment == .longStall ? 0.750 : impairment == .burstLoss ? 0.250 : 0.002, label)
                if impairment == .clean || impairment == .jitter {
                    XCTAssertEqual(result.decoded, reference, label)
                }
                XCTAssertEqual(Array(result.decoded.suffix(640)), Array(reference.suffix(640)), label)
                let attachment = XCTAttachment(data: wav(result.rendered), uniformTypeIdentifier: "com.microsoft.waveform-audio")
                attachment.name = "\(label).wav"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func packets(codec: EchoLinkVoiceCodec, timestamped: Bool) throws -> [Data] {
        // Speech-like voiced/unvoiced transitions with a fixed seed, without external assets.
        var state: UInt32 = 0x51_58_4C
        let source: [Int16] = (0..<(80 * 640)).map { index in
            state = 1664525 &* state &+ 1013904223
            let time = Double(index) / 8000
            let envelope = 0.35 + 0.65 * pow(sin(.pi * time / 0.32), 2)
            let voiced = 8000 * sin(2 * .pi * 125 * time) + 3000 * sin(2 * .pi * 375 * time)
            let noise = Double(Int(state >> 16) - 32768) / 32768 * 1800
            return Int16((envelope * (voiced + noise)).rounded())
        }
        let payloads: [Data]
        switch codec {
        case .gsm:
            let encoded = try XCTUnwrap(GSMCodec.stripHeader(GSMCodec().encode(source)))
            payloads = stride(from: 0, to: encoded.count, by: 132).map { Data(encoded[$0..<($0 + 132)]) }
        case .speex:
            payloads = try XCTUnwrap(SpeexCodec().encode(source))
        }
        XCTAssertEqual(payloads.count, 80)
        return packetize(payloads, codec: codec, timestamped: timestamped)
    }

    private func packetize(_ payloads: [Data], codec: EchoLinkVoiceCodec, timestamped: Bool) -> [Data] {
        payloads.enumerated().map { index, payload in
            EchoLinkAudioPacketCodec.buildLegacyVoicePacket(gsmPayload: payload,
                sequence: 65520 &+ UInt16(index), timestamp: timestamped ? UInt32(index * 640) : 0, codec: codec)
        }
    }

    private func trace(_ packets: [Data], impairment: Impairment, reorderDelay: Double = 0.100) -> [Arrival] {
        var state: UInt32 = 0xBADC0DE
        var arrivals: [Arrival] = []
        for index in packets.indices {
            if impairment == .singleLoss, index == 24 { continue }
            if impairment == .burstLoss, [24, 25].contains(index) { continue }
            var time = Double(index) * 0.08 + 0.035
            state = 1664525 &* state &+ 1013904223
            if impairment == .jitter { time += Double(state % 41) / 1000 - 0.020 }
            if impairment == .reordered, index == 24 { time += reorderDelay }
            if impairment == .wifiBurst, (24...27).contains(index) { time = 28 * 0.08 + 0.035 }
            if impairment == .longStall, (24...32).contains(index) { time = 33 * 0.08 + 0.035 }
            arrivals.append(Arrival(time: time, packet: packets[index]))
            if impairment == .duplicated, index.isMultiple(of: 11) {
                arrivals.append(Arrival(time: time + 0.005, packet: packets[index]))
            }
        }
        return arrivals.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
    }

    private func referenceDecode(_ packets: [Data], codec: EchoLinkVoiceCodec) throws -> [Int16] {
        let gsm = GSMCodec()
        let speex = SpeexCodec()
        return try packets.flatMap { packet in
            let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet))
            switch parsed.packet {
            case .gsm(let data): return gsm.decodePacket(data)
            case .speex(let data): return try XCTUnwrap(speex.decodePacket(data))
            default: throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    private func render(_ arrivals: [Arrival], codec: EchoLinkVoiceCodec,
                        nativeReorderHeadroom: Bool = true, prebufferedSamples: [Int16] = []) throws -> Result {
        var result = Result()
        result.rendered = prebufferedSamples
        var reorder = EchoLinkAudioReorderBuffer()
        var playout = ReceiveAdaptivePlayoutBuffer()
        let smoother = ReceiveSpeechSmoother()
        let gsm = GSMCodec()
        let speex = SpeexReceiveStreamDecoder()
        let clock = ReceiveClockCompensator()
        let queue = ReceivePlaybackQueue()
        var gain = ReceivePlaybackGain()
        var nextArrival = 0
        var renderEnd = Double(prebufferedSamples.count) / 8000
        result.maximumLead = renderEnd
        var lastDecodedAt = -Double.infinity
        func lead(_ now: Double) -> Int { max(0, Int(((renderEnd - now) * 8000).rounded())) }
        func drain(_ now: Double) {
            let capacity = Int(Double(max(0, queue.maximumSamples - lead(now))) / 1.005)
            for packet in playout.drain(now: now, maximumSamples: capacity) {
                let corrected = clock.process(packet, queuedSamples: lead(now),
                    targetQueuedSamples: Int(playout.targetDelay * 8000))
                if renderEnd > 0 { result.silenceSeconds += max(0, now - renderEnd) }
                let start = max(now, renderEnd)
                let startSample = Int((start * 8000).rounded())
                if result.rendered.count < startSample {
                    result.rendered += repeatElement(0, count: startSample - result.rendered.count)
                }
                result.rendered += gain.process(corrected).map { Int16(clamping: Int(($0 * 32768).rounded())) }
                renderEnd = start + Double(corrected.count) / 8000
                result.maximumLead = max(result.maximumLead, renderEnd - now)
            }
        }
        func admit(_ packet: Data, now: Double) throws {
            let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet))
            let received: [Int16]
            let output: [Int16]
            let budget = queue.concealmentSampleBudget(receivedSamples: 640,
                remainingSamples: lead(now), pendingSamples: playout.pendingSampleCount)
            switch parsed.packet {
            case .gsm(let data):
                received = gsm.decodePacket(data)
                output = smoother.process(received, metadata: parsed.metadata, now: now,
                    maximumConcealmentSamples: budget)
            case .speex(let data):
                let decoded = try XCTUnwrap(speex.decode(data, metadata: parsed.metadata, now: now))
                received = decoded.received
                output = Array(queue.retainedConcealment(decoded.concealed, receivedSamples: received.count,
                    remainingSamples: lead(now), pendingSamples: playout.pendingSampleCount)) + received
            default: throw CocoaError(.fileReadCorruptFile)
            }
            if now - lastDecodedAt >= 0.5 { clock.reset() }
            lastDecodedAt = now
            result.accepted += 1
            result.decoded += received
            result.syntheticSamples += output.count - received.count
            drain(now)
            playout.enqueue(output, networkSampleCount: received.count, now: now, rendererLeadSamples: lead(now))
            drain(now)
        }
        for tick in 0...8500 {
            let now = Double(tick) / 1000
            while nextArrival < arrivals.count, arrivals[nextArrival].time <= now + 0.0000001 {
                let arrival = arrivals[nextArrival]
                let parsed = try XCTUnwrap(EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(arrival.packet))
                for packet in reorder.insert(arrival.packet, metadata: parsed.metadata, now: now,
                    playbackLeadSamples: nativeReorderHeadroom ? lead(now) : 0) {
                    try admit(packet, now: now)
                }
                nextArrival += 1
            }
            for packet in reorder.drain(now: now) { try admit(packet, now: now) }
            drain(now)
        }
        result.missing = reorder.missingPacketCount
        result.late = reorder.duplicateOrLatePacketCount
        result.discarded = playout.discardedPackets
        result.maximumWait = playout.maximumObservedWait
        XCTAssertEqual(nextArrival, arrivals.count)
        XCTAssertEqual(playout.pendingSampleCount, 0)
        return result
    }

    private func wav(_ samples: [Int16]) -> Data {
        var output = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
        }
        output.append(Data("RIFF".utf8)); word(UInt32(36 + samples.count * 2))
        output.append(Data("WAVEfmt ".utf8)); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(8000)); word(UInt32(16000)); word(UInt16(2)); word(UInt16(16))
        output.append(Data("data".utf8)); word(UInt32(samples.count * 2))
        for sample in samples { word(sample) }
        return output
    }
}
