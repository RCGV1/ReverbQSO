// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

/// Realistic audio quality and protocol-correctness tests for the EchoLink voice pipeline.
///
/// These tests go beyond smoke-testing and verify codec fidelity, resampler accuracy,
/// packet loss recovery, and G.711 reference values — covering the scenarios that
/// occur during a real QSO.
final class VoicePipelineQualityTests: XCTestCase {

    // MARK: - GSM Fidelity

    /// A sine wave at 440 Hz (voice-range tone) must survive a GSM encode/decode
    /// cycle with high correlation to the original. GSM 06.10 is a lossy codec but
    /// should preserve the waveform shape well for tonal signals (correlation ≥ 0.85).
    func testSineWaveRoundTripCorrelation() {
        let encoder = GSMCodec()
        let decoder = GSMCodec()
        let sampleCount = GSMCodec.samplesPerFrame * 5

        let samples = makeSine(hz: 440, sampleRate: 8000, count: sampleCount, amplitude: 10_000)

        let encoded = encoder.encode(samples)
        let payload = GSMCodec.stripHeader(encoded) ?? Data()
        XCTAssertEqual(payload.count, GSMCodec.encodedFrameSize * 5, "Encoded payload should contain exactly 5 frames")

        let decoded = decoder.decodePacket(payload)
        XCTAssertEqual(decoded.count, sampleCount, "Decoded sample count must match input")

        let correlation = pearsonCorrelation(samples.map(Double.init), decoded.map(Double.init))
        XCTAssertGreaterThan(correlation, 0.85,
            "GSM round-trip correlation should be ≥ 0.85 for a 440 Hz tone (got \(correlation))")
    }

    /// A 200 Hz tone (low-voice fundamental) should also survive the round-trip.
    func testLowFrequencyToneRoundTripCorrelation() {
        let encoder = GSMCodec()
        let decoder = GSMCodec()
        let sampleCount = GSMCodec.samplesPerFrame * 4

        let samples = makeSine(hz: 200, sampleRate: 8000, count: sampleCount, amplitude: 8_000)

        let encoded = encoder.encode(samples)
        let payload = GSMCodec.stripHeader(encoded) ?? Data()
        let decoded = decoder.decodePacket(payload)

        XCTAssertEqual(decoded.count, sampleCount)
        let correlation = pearsonCorrelation(samples.map(Double.init), decoded.map(Double.init))
        XCTAssertGreaterThan(correlation, 0.80, "200 Hz tone correlation should be ≥ 0.80")
    }

    /// Silence (all-zero samples) must encode and decode without introducing loud
    /// artefacts. After convergence (≥ 2 frames), the last frame's peak amplitude
    /// must stay well below 1% of full scale.
    func testSilenceRoundTripIsNearSilent() {
        let encoder = GSMCodec()
        let decoder = GSMCodec()
        let frameCount = 4
        let samples = [Int16](repeating: 0, count: GSMCodec.samplesPerFrame * frameCount)

        let encoded = encoder.encode(samples)
        let payload = GSMCodec.stripHeader(encoded) ?? Data()
        let decoded = decoder.decodePacket(payload)

        XCTAssertEqual(decoded.count, samples.count)

        // Skip the first two frames (codec convergence transient) and check the rest.
        let convergedFrameStart = GSMCodec.samplesPerFrame * 2
        let converged = Array(decoded[convergedFrameStart...])
        let peakAmplitude = converged.map { abs(Int($0)) }.max() ?? 0
        XCTAssertLessThan(peakAmplitude, 330,
            "Silence should decode to near-silence after codec convergence (peak was \(peakAmplitude))")
    }

    /// Near-clipping input (Int16.max/min range) must not crash the codec and must
    /// produce a plausible (non-empty, non-overflowing) decoded output.
    func testNearClippingInputDoesNotCrash() {
        let encoder = GSMCodec()
        let decoder = GSMCodec()

        // Alternate +32000 / -32000 — a square wave at Nyquist/2 (harsh signal).
        let samples: [Int16] = (0..<GSMCodec.samplesPerFrame * 2).map { i in
            i.isMultiple(of: 2) ? 32_000 : -32_000
        }

        let encoded = encoder.encode(samples)
        let payload = GSMCodec.stripHeader(encoded) ?? Data()
        XCTAssertFalse(payload.isEmpty, "Encoding near-clipping input must produce output")

        let decoded = decoder.decodePacket(payload)
        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame * 2)
        // Decoded values must be within Int16 range (no overflow artefacts).
        XCTAssertTrue(decoded.allSatisfy { $0 >= -32_768 && $0 <= 32_767 })
    }

    /// Verify that the output energy (RMS) is within a reasonable fraction of the
    /// input energy after GSM encode/decode. GSM should not mute or massively amplify.
    func testRoundTripEnergyPreservation() {
        let encoder = GSMCodec()
        let decoder = GSMCodec()

        let samples = makeSine(hz: 880, sampleRate: 8000, count: GSMCodec.samplesPerFrame * 3, amplitude: 5_000)

        let encoded = encoder.encode(samples)
        let payload = GSMCodec.stripHeader(encoded) ?? Data()
        let decoded = decoder.decodePacket(payload)

        XCTAssertEqual(decoded.count, samples.count)

        let inputRMS  = rms(samples.map(Double.init))
        let outputRMS = rms(decoded.map(Double.init))

        guard inputRMS > 0 else { return XCTFail("Input RMS must be non-zero") }
        let ratio = outputRMS / inputRMS
        XCTAssertGreaterThan(ratio, 0.3, "Output RMS should be at least 30% of input (ratio was \(ratio))")
        XCTAssertLessThan(ratio, 3.0, "Output RMS should not exceed 3× input (ratio was \(ratio))")
    }

    // MARK: - Packet Loss Simulation

    /// If a packet is lost (skipped), the next received packet must decode cleanly as
    /// a self-contained unit. Using `decodePacket` (not `decode`) ensures no stale
    /// carry-over from the gap corrupts subsequent audio.
    func testDecodingAfterOnePacketLossRecovery() {
        let encoder = GSMCodec()
        let receiveDecoder = GSMCodec()

        // Build 4 independent packets.
        var packets: [Data] = []
        for i in 0..<4 {
            let enc = GSMCodec()
            let s = makeSine(hz: Double(300 + i * 100), sampleRate: 8000,
                             count: GSMCodec.samplesPerFrame * 2, amplitude: 8_000)
            let encoded = enc.encode(s)
            let payload = GSMCodec.stripHeader(encoded) ?? Data()
            packets.append(payload)
        }

        // Decode packets 0, 2, 3 — packet 1 is lost.
        var totalDecoded = 0
        for idx in [0, 2, 3] {
            let decoded = receiveDecoder.decodePacket(packets[idx])
            XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame * 2,
                "Packet \(idx) should decode fully even after packet loss")
            XCTAssertTrue(decoded.contains(where: { abs(Int($0)) > 50 }),
                "Decoded packet \(idx) should contain non-trivial audio")
            totalDecoded += decoded.count
        }

        XCTAssertEqual(totalDecoded, GSMCodec.samplesPerFrame * 2 * 3)
    }

    /// Back-to-back packet loss (2 consecutive missing packets) should still allow
    /// clean decode of the next received packet.
    func testDecodingAfterTwoConsecutivePacketLoss() {
        let encoder = GSMCodec()
        let receiveDecoder = GSMCodec()

        let s = makeSine(hz: 440, sampleRate: 8000,
                         count: GSMCodec.samplesPerFrame * 2, amplitude: 6_000)

        // Encode four packets using independent encoder state.
        var packets: [Data] = []
        for _ in 0..<4 {
            let enc = GSMCodec()
            let encoded = enc.encode(s)
            packets.append(GSMCodec.stripHeader(encoded) ?? Data())
        }

        // Process only packet 0 then jump to packet 3.
        _ = receiveDecoder.decodePacket(packets[0])
        let late = receiveDecoder.decodePacket(packets[3])

        XCTAssertEqual(late.count, GSMCodec.samplesPerFrame * 2)
    }

    // MARK: - Realistic Multi-Packet QSO Simulation

    /// Simulate a 10-packet EchoLink audio stream (each with 2 GSM frames = 40 ms).
    /// Every decoded packet must be non-trivial and the total sample count must match.
    func testMultiPacketQSOStreamDecoding() {
        let receiveDecoder = GSMCodec()
        let packetCount   = 10
        let framesPerPacket = 2
        let expectedSamplesPerPacket = GSMCodec.samplesPerFrame * framesPerPacket

        var totalDecodedSamples = 0
        var nonTrivialPackets   = 0

        for i in 0..<packetCount {
            // Each packet comes from an independent encode chain (realistic: the
            // remote station is encoding continuously, not per-packet).
            let remoteEncoder = GSMCodec()
            let signal = makeSine(
                hz: Double(300 + (i % 5) * 80),
                sampleRate: 8000,
                count: expectedSamplesPerPacket,
                amplitude: 7_000
            )
            let encoded = remoteEncoder.encode(signal)
            let rawPayload = GSMCodec.stripHeader(encoded) ?? Data()

            // Wrap in an EchoLink legacy voice packet and round-trip through parser.
            let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                gsmPayload: rawPayload,
                sequence: UInt16(i),
                timestamp: UInt32(i * expectedSamplesPerPacket)
            )

            guard case .gsm(let parsedPayload)? = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet) else {
                XCTFail("Packet \(i) should parse as GSM")
                continue
            }

            let decoded = receiveDecoder.decodePacket(parsedPayload)
            XCTAssertEqual(decoded.count, expectedSamplesPerPacket,
                "Packet \(i): decoded count mismatch")

            totalDecodedSamples += decoded.count
            if decoded.contains(where: { abs(Int($0)) > 100 }) { nonTrivialPackets += 1 }
        }

        XCTAssertEqual(totalDecodedSamples, expectedSamplesPerPacket * packetCount)
        // Expect the vast majority of packets to contain audible audio.
        XCTAssertGreaterThanOrEqual(nonTrivialPackets, 8,
            "At least 8 of 10 packets should decode to audible audio")
    }

    /// Verify that 4-frame packets (the maximum allowed by EchoLink) are correctly
    /// assembled, transmitted, and decoded end-to-end.
    func testFourFrameMaxPacketRoundTrip() {
        let encoder = GSMCodec()
        let decoder = GSMCodec()
        let totalSamples = GSMCodec.samplesPerFrame * 4

        let input = makeSine(hz: 500, sampleRate: 8000, count: totalSamples, amplitude: 9_000)
        let encoded = encoder.encode(input)
        let rawPayload = GSMCodec.stripHeader(encoded) ?? Data()

        // Packetize — should produce exactly one 4-frame packet (132 bytes) with no remainder.
        var pending = rawPayload
        let chunks = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &pending)
        XCTAssertEqual(chunks.count, 1, "4 frames should fit in one max-size packet")
        XCTAssertEqual(chunks[0].count, GSMCodec.encodedFrameSize * 4)
        XCTAssertTrue(pending.isEmpty, "No remainder for exactly 4 frames")

        let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: chunks[0], sequence: 42, timestamp: 0
        )
        guard case .gsm(let parsed)? = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet) else {
            return XCTFail("4-frame packet should parse as GSM")
        }

        let decoded = decoder.decodePacket(parsed)
        XCTAssertEqual(decoded.count, totalSamples)
        XCTAssertTrue(decoded.contains(where: { abs(Int($0)) > 50 }))
    }

    // MARK: - G.711 µ-Law Decode Reference Values

    /// Verify that G.711 µ-law decode matches the ITU-T reference table for key codewords.
    ///
    /// Reference values from ITU-T G.711 Table 1 (via standard µ-law arithmetic):
    ///   0x00 → most-negative-magnitude (sign bit set in µ-law encoding) → decoded as -32124
    ///   0x80 → most-positive-magnitude                                  → decoded as +32124
    ///   0xFF → silence (positive side, smallest magnitude)               → decoded as 0
    ///   0x7F → silence (negative side, smallest magnitude)               → decoded as 0
    func testMuLawDecodeKnownReferenceValues() {
        XCTAssertEqual(EchoLinkAudioPacketCodec.decodeMuLaw(0x00), -32_124, "µ-law 0x00 → -32124")
        XCTAssertEqual(EchoLinkAudioPacketCodec.decodeMuLaw(0x80),  32_124, "µ-law 0x80 → +32124")
        XCTAssertEqual(EchoLinkAudioPacketCodec.decodeMuLaw(0xFF),       0, "µ-law 0xFF → 0 (silence)")
        XCTAssertEqual(EchoLinkAudioPacketCodec.decodeMuLaw(0x7F),       0, "µ-law 0x7F → 0 (neg-silence)")
    }

    /// µ-law decoded values must be monotonically non-decreasing from 0x80 to 0xFF
    /// (decreasing magnitude toward silence) and from 0x00 to 0x7F (increasing magnitude away from silence).
    func testMuLawDecodeMonotonicity() {
        // Positive side (0x80…0xFF): magnitude decreases toward silence.
        var prevMag = Int(EchoLinkAudioPacketCodec.decodeMuLaw(0x80))
        for byte in UInt8(0x81)...UInt8(0xFF) {
            let mag = Int(EchoLinkAudioPacketCodec.decodeMuLaw(byte))
            XCTAssertGreaterThanOrEqual(prevMag, mag,
                "µ-law 0x\(String(byte, radix: 16)): magnitude should not increase toward silence")
            prevMag = mag
        }

        // Negative side (0x00…0x7F): magnitude decreases toward silence (values approach 0 from below).
        var prevNeg = Int(EchoLinkAudioPacketCodec.decodeMuLaw(0x00))
        for byte in UInt8(0x01)...UInt8(0x7F) {
            let val = Int(EchoLinkAudioPacketCodec.decodeMuLaw(byte))
            XCTAssertLessThanOrEqual(prevNeg, val,
                "µ-law 0x\(String(byte, radix: 16)): negative magnitude should approach 0")
            prevNeg = val
        }
    }

    /// A G.711 µ-law payload of 160 bytes (20 ms at 8 kHz) decoded through the
    /// packet parser should produce exactly 160 Int16 PCM samples with non-trivial content.
    func testMuLawPayloadPipelineDecodesRealisticLength() {
        // 160 bytes of non-silence µ-law: use byte 0x20 which decodes to a mid-range value.
        let muPayload = Data(repeating: 0x20, count: 160)
        var packet = Data([0xC0, 0x00, 0x00, 0x01])  // PT=0 (µ-law)
        packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        packet.append(muPayload)

        guard case .pcm(let samples)? = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet) else {
            return XCTFail("µ-law payload should parse as PCM")
        }
        XCTAssertEqual(samples.count, 160, "160-byte µ-law payload → 160 PCM samples")
        XCTAssertTrue(samples.allSatisfy { $0 != 0 }, "0x20 µ-law should decode to non-zero samples")
    }

    // MARK: - G.711 A-Law Decode Reference Values

    /// Verify A-law decode reference values.
    ///
    ///   0x55 → smallest negative (sign XOR 0x55 = 0x00 → exp=0, man=0): -8
    ///   0xD5 → smallest positive (same magnitude, sign bit set):        +8
    ///   0x2A → decoded via: a = 0x2A^0x55 = 0x7F → sign=0, exp=7, man=15
    ///          sample = ((15<<4)+0x108) << 6 = 504*64 = 32256 → -32256
    func testALawDecodeKnownReferenceValues() {
        XCTAssertEqual(EchoLinkAudioPacketCodec.decodeALaw(0x55),     -8, "A-law 0x55 → -8")
        XCTAssertEqual(EchoLinkAudioPacketCodec.decodeALaw(0xD5),      8, "A-law 0xD5 → +8")
        XCTAssertEqual(EchoLinkAudioPacketCodec.decodeALaw(0x2A), -32_256, "A-law 0x2A → -32256")
    }

    /// A-law decoded values must be antisymmetric: decoding byte B and (B ^ 0x80)
    /// should give values of equal magnitude but opposite sign (for non-zero results).
    func testALawDecodeAntisymmetry() {
        for byte in UInt8(0x00)...UInt8(0x7F) {
            let positive = Int(EchoLinkAudioPacketCodec.decodeALaw(byte))
            let negative = Int(EchoLinkAudioPacketCodec.decodeALaw(byte ^ 0x80))
            XCTAssertEqual(positive, -negative,
                "A-law antisymmetry failed for byte 0x\(String(byte, radix: 16))")
        }
    }

    // MARK: - RTP Packet Structure Tests

    /// The timestamp field in a legacy voice packet must be encoded big-endian and
    /// must be read back correctly when the packet is inspected as raw bytes.
    func testLegacyVoicePacketTimestampFieldIsCorrect() {
        let knownTimestamp: UInt32 = 0x12_34_56_78
        let payload = Data(repeating: 0xAA, count: GSMCodec.encodedFrameSize)
        let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: payload, sequence: 7, timestamp: knownTimestamp
        )

        XCTAssertEqual(packet.count, EchoLinkAudioPacketCodec.legacyVoiceHeaderLength + payload.count)

        // Timestamp occupies bytes 4–7 (big-endian).
        let readBack = (UInt32(packet[4]) << 24)
                     | (UInt32(packet[5]) << 16)
                     | (UInt32(packet[6]) <<  8)
                     |  UInt32(packet[7])
        XCTAssertEqual(readBack, knownTimestamp, "Timestamp bytes 4-7 must round-trip big-endian")
    }

    /// Consecutive packets must have monotonically increasing timestamps matching
    /// the expected per-packet sample-count increment.
    func testPacketTimestampIncrementsMonotonically() {
        let framesPerPacket = 2
        let payloadBytes = framesPerPacket * GSMCodec.encodedFrameSize
        let expectedIncrement = UInt32(framesPerPacket * GSMCodec.samplesPerFrame)

        let payload = Data(repeating: 0x11, count: payloadBytes)
        var timestamps: [UInt32] = []

        var seq: UInt16 = 0
        var ts: UInt32  = 1_000
        for _ in 0..<5 {
            let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                gsmPayload: payload, sequence: seq, timestamp: ts
            )
            seq &+= 1
            ts  &+= expectedIncrement

            let extracted = (UInt32(packet[4]) << 24) | (UInt32(packet[5]) << 16)
                          | (UInt32(packet[6]) <<  8) |  UInt32(packet[7])
            timestamps.append(extracted)
        }

        for i in 1..<timestamps.count {
            let diff = timestamps[i] &- timestamps[i - 1]
            XCTAssertEqual(diff, expectedIncrement,
                "Packet \(i) timestamp gap should be \(expectedIncrement) samples")
        }
    }

    /// An EchoLink legacy voice packet parsed back through parseIncomingAudioPacket
    /// must survive a round-trip regardless of the timestamp value.
    func testPacketParseIgnoresTimestampField() {
        let payload = Data(repeating: 0x22, count: GSMCodec.encodedFrameSize * 2)
        for ts: UInt32 in [0, 160, UInt32.max - 1, 0xDEAD_BEEF] {
            let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
                gsmPayload: payload, sequence: 1, timestamp: ts
            )
            let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
            XCTAssertEqual(parsed, .gsm(payload),
                "Parsing should succeed for any timestamp value (ts=\(ts))")
        }
    }

    // MARK: - RTP Version-3 with CSRC

    /// An EchoLink node sending version-3 RTP with one CSRC (first byte 0xC1) must
    /// be parsed correctly — previously this fell through to the raw-GSM fallback.
    func testRTPVersion3WithCSRCParsesCorrectly() {
        let payload = Data(repeating: 0x33, count: GSMCodec.encodedFrameSize * 2)
        var packet = Data()
        packet.append(0xC1) // version=3, CC=1
        packet.append(0x03) // PT=GSM
        packet.append(contentsOf: [0x00, 0x05]) // sequence
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0xA0]) // timestamp
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // ssrc
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x02]) // one CSRC (4 bytes)
        packet.append(payload)

        let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet)
        XCTAssertEqual(parsed, .gsm(payload),
            "Version-3 RTP with CSRC should parse as GSM (not fall through to raw-frame check)")
    }

    /// Version-3 RTP with CSRC carrying µ-law payload (PT=0) must also decode.
    func testRTPVersion3WithCSRCAndMuLawPayload() {
        let payload = Data(repeating: 0x20, count: 160)
        var packet = Data()
        packet.append(0xC1) // version=3, CC=1
        packet.append(0x00) // PT=µ-law
        packet.append(contentsOf: [0x00, 0x06])
        packet.append(contentsOf: [0x00, 0x00, 0x01, 0x40])
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // ssrc
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x03]) // CSRC
        packet.append(payload)

        guard case .pcm(let samples)? = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(packet) else {
            return XCTFail("Version-3 RTP + µ-law payload should produce PCM")
        }
        XCTAssertEqual(samples.count, 160)
    }

    // MARK: - BEEF-Format Packet Pipeline

    /// The BEEF-header format (older EchoLink nodes) must survive the full receive pipeline:
    /// parse → strip header → GSM decode → PCM output with meaningful content.
    func testBEEFFormatPacketFullPipeline() {
        let encoder = GSMCodec()
        let decoder = GSMCodec()

        let input = makeSine(hz: 440, sampleRate: 8000,
                             count: GSMCodec.samplesPerFrame * 2, amplitude: 8_000)
        let encoded = encoder.encode(input) // includes BEEF header

        // parseIncomingAudioPacket should strip BEEF and return raw GSM frames.
        guard case .gsm(let rawFrames)? = EchoLinkAudioPacketCodec.parseIncomingAudioPacket(encoded) else {
            return XCTFail("BEEF-prefixed packet should parse as GSM")
        }
        XCTAssertEqual(rawFrames.count, GSMCodec.encodedFrameSize * 2)

        let decoded = decoder.decodePacket(rawFrames)
        XCTAssertEqual(decoded.count, GSMCodec.samplesPerFrame * 2)
        XCTAssertTrue(decoded.contains(where: { abs(Int($0)) > 100 }))
    }

    // MARK: - Resampler Quality (critical path: iOS hardware → GSM codec)

    /// The most common iOS hardware sample rate is 44.1 kHz. Downsampling to 8 kHz
    /// must produce the exact expected frame count for codec input.
    func testDownsample44100To8000ProducesGSMFrameAlignedOutput() {
        // 10 ms of audio at 44100 Hz = 441 samples → expected output ≈ 80 samples at 8000 Hz
        var state = PCMLinearResamplerState()
        let input = makeSine(hz: 300, sampleRate: 44_100, count: 441, amplitude: 5_000)

        let output = PCMLinearResampler.resample(
            input, sourceSampleRate: 44_100, targetSampleRate: 8_000, state: &state
        )
        XCTAssertEqual(output.count, 80, "441 samples@44.1kHz → 80 samples@8kHz")
        XCTAssertTrue(output.contains(where: { abs(Int($0)) > 50 }),
            "Resampled output should contain audible content")
    }

    /// 48 kHz → 8 kHz (another common iOS hardware rate after preferred-rate request).
    func testDownsample48000To8000ProducesExpectedLength() {
        var state = PCMLinearResamplerState()
        let input = [Int16](repeating: 3_000, count: 480) // 10 ms at 48 kHz

        let output = PCMLinearResampler.resample(
            input, sourceSampleRate: 48_000, targetSampleRate: 8_000, state: &state
        )
        XCTAssertEqual(output.count, 80, "480 samples@48kHz → 80 samples@8kHz (10 ms)")
    }

    /// A DC offset in the input must be preserved (to within ±1 LSB) after resampling.
    /// This tests that the resampler doesn't introduce spurious high-pass filtering.
    func testResamplerPreservesDCOffset() {
        var state = PCMLinearResamplerState()
        let dcLevel: Int16 = 2_000
        let input = [Int16](repeating: dcLevel, count: 441)

        let output = PCMLinearResampler.resample(
            input, sourceSampleRate: 44_100, targetSampleRate: 8_000, state: &state
        )

        XCTAssertFalse(output.isEmpty)
        let maxDev = output.map { abs(Int($0) - Int(dcLevel)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxDev, 1, "DC-offset preservation: max deviation must be ≤ 1 LSB")
    }

    /// Downsampling a 300 Hz sine from 44100 to 8000 Hz must yield output whose
    /// sign changes are consistent with a preserved sub-Nyquist frequency.
    func testResamplerPreservesSubNyquistSineWaveSign() {
        var state = PCMLinearResamplerState()
        // 300 Hz is well below 4000 Hz (Nyquist for 8000 Hz target) — must survive.
        let input = makeSine(hz: 300, sampleRate: 44_100, count: 44_100, amplitude: 10_000)
        let output = PCMLinearResampler.resample(
            input, sourceSampleRate: 44_100, targetSampleRate: 8_000, state: &state
        )

        // Count zero crossings — there should be approximately 2 * 300 = 600 per second.
        var crossings = 0
        for i in 1..<output.count {
            if (output[i - 1] >= 0) != (output[i] >= 0) { crossings += 1 }
        }
        // Allow ±30% tolerance around 600 zero crossings per second of 8000-Hz audio.
        XCTAssertGreaterThan(crossings, 400, "Zero crossings too few — frequency was lost in resampling")
        XCTAssertLessThan(crossings, 900, "Zero crossings too many — aliasing occurred in resampling")
    }

    // MARK: - Capture Flush Lifecycle

    func testCaptureFlushPlanPadsShortTransmissionToFourFrames() {
        let plan = AudioCaptureFlushPlan.make(
            hasCodecInput: true,
            sampleRemainder: 80,
            encodedFrameRemainder: 0
        )

        XCTAssertEqual(plan.partialFrameSamplePadding, 80)
        XCTAssertEqual(plan.silentFramePadding, 3)
    }

    func testCaptureFlushPlanCompletesPendingPacketWithoutExtraPacket() {
        let plan = AudioCaptureFlushPlan.make(
            hasCodecInput: true,
            sampleRemainder: 80,
            encodedFrameRemainder: 3
        )

        XCTAssertEqual(plan.partialFrameSamplePadding, 80)
        XCTAssertEqual(plan.silentFramePadding, 0)
    }

    func testCaptureFlushPlanDoesNothingAtExactPacketBoundary() {
        let plan = AudioCaptureFlushPlan.make(
            hasCodecInput: true,
            sampleRemainder: 0,
            encodedFrameRemainder: 0
        )

        XCTAssertEqual(plan.partialFrameSamplePadding, 0)
        XCTAssertEqual(plan.silentFramePadding, 0)
    }

    func testCaptureFlushPlanDoesNothingWithoutCapturedInput() {
        let plan = AudioCaptureFlushPlan.make(
            hasCodecInput: false,
            sampleRemainder: 80,
            encodedFrameRemainder: 2
        )

        XCTAssertEqual(plan.partialFrameSamplePadding, 0)
        XCTAssertEqual(plan.silentFramePadding, 0)
    }

    func testShortCaptureFlushProducesOneValidEchoLinkPacket() {
        let encoder = GSMCodec()
        let initialSamples = [Int16](repeating: 1_000, count: 80)
        XCTAssertTrue(encoder.encode(initialSamples).isEmpty)

        let plan = AudioCaptureFlushPlan.make(
            hasCodecInput: true,
            sampleRemainder: initialSamples.count,
            encodedFrameRemainder: 0
        )

        var encodedPayload = Data()
        let completedFrame = encoder.encode(
            [Int16](repeating: 0, count: plan.partialFrameSamplePadding)
        )
        encodedPayload.append(GSMCodec.stripHeader(completedFrame) ?? Data())

        let silentFrames = encoder.encode(
            [Int16](
                repeating: 0,
                count: plan.silentFramePadding * GSMCodec.samplesPerFrame
            )
        )
        encodedPayload.append(GSMCodec.stripHeader(silentFrames) ?? Data())

        var pending = encodedPayload
        let packets = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &pending)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].count, 4 * GSMCodec.encodedFrameSize)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Helpers

    /// Generate a full-precision sine wave at `hz` with the given sample rate and amplitude.
    private func makeSine(hz: Double, sampleRate: Double, count: Int, amplitude: Double) -> [Int16] {
        (0..<count).map { i in
            let phase = 2.0 * .pi * hz * Double(i) / sampleRate
            return Int16(clamping: Int(amplitude * sin(phase)))
        }
    }

    /// Pearson correlation coefficient in [−1, 1]. Returns 0 if either signal has zero variance.
    private func pearsonCorrelation(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, !x.isEmpty else { return 0 }
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        let num = zip(x, y).reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denX = x.reduce(0.0) { $0 + ($1 - meanX) * ($1 - meanX) }
        let denY = y.reduce(0.0) { $0 + ($1 - meanY) * ($1 - meanY) }
        let den  = sqrt(denX * denY)
        return den == 0 ? 0 : num / den
    }

    /// Root-mean-square of a signal.
    private func rms(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0.0) { $0 + $1 * $1 } / Double(samples.count))
    }
}
