// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ReverbQSO

@MainActor
final class AudioEngineOfflineTests: XCTestCase {
    func testDisabledHardwareRejectsCaptureAndNeverStartsPlayback() async {
        let engine = AudioEngine(hardwareEnabled: false)
        defer { engine.stopAll() }

        engine.startPlayback()
        engine.startPlayback(rebuildGraph: true)
        engine.setOutputPreference(engine.outputPreference)
        engine.setInputDevice(id: engine.selectedInputDeviceID)
        for requestPermission in [false, true] {
            let prepared = await engine.prepareCaptureInput(requestPermission: requestPermission)
            let started = await engine.startCapture(requestPermission: requestPermission)
            XCTAssertFalse(prepared)
            XCTAssertFalse(started)
        }

        XCTAssertFalse(engine.isCapturing)
        XCTAssertFalse(engine.isCaptureReady)
        XCTAssertFalse(engine.isPreparingCapture)
        XCTAssertFalse(engine.capturePreparationFailed)
        XCTAssertTrue(engine.availableInputDevices.isEmpty)
        assertNoHardwarePlayback(engine)
#if DEBUG
        XCTAssertThrowsError(try engine.beginAuditRenderCapture(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")))
#endif
    }

    func testReceivedPCMRetainsRecordingAndLevelsWithoutRenderingEvenWhenMuted() {
        let engine = AudioEngine(hardwareEnabled: false)
        defer { engine.stopAll() }
        let speech: [Int16] = [5_000, -5_000, 5_000, -5_000]
        var recordings: [[Int16]] = []
        engine.onRecordingPCM = { recordings.append($0) }

        engine.beginRXWindowAfterPTT()
        engine.playReceivedPCM(speech, diagnoseFirstRXAfterPTT: true)
        XCTAssertEqual(engine.outputLevel, 0.5, accuracy: 0.000_001)
        engine.setReceiveOutputMuted(true)
        engine.playReceivedPCM(speech, nativeConcealment: [30_000, -30_000])
        engine.finishRXWindowAfterPTT()

        XCTAssertEqual(recordings, [speech, speech])
        XCTAssertEqual(engine.outputLevel, 0.5, accuracy: 0.000_001)
        assertNoHardwarePlayback(engine)

        engine.playReceivedPCM([0, 0, 0, 0])
        XCTAssertEqual(engine.outputLevel, 0)
        XCTAssertEqual(recordings.last, [0, 0, 0, 0])
    }

    func testEncodedReceiveUsesRealGSMDecoderAndResetState() throws {
        let engine = AudioEngine(hardwareEnabled: false)
        defer { engine.stopAll() }
        var recordings: [[Int16]] = []
        engine.onRecordingPCM = { recordings.append($0) }
        let speech = (0..<640).map { Int16($0 % 40 < 20 ? 10_000 : -10_000) }
        let packet = GSMCodec().encode(speech)
        let expected = GSMCodec().decodePacket(packet)

        engine.playReceivedAudio(packet)
        XCTAssertEqual(recordings, [expected])
        XCTAssertEqual(expected.count, speech.count)
        XCTAssertGreaterThan(engine.outputLevel, 0.01)
        engine.resetCodecState()
        engine.playReceivedAudio(packet)
        XCTAssertEqual(recordings, [expected, expected])
        assertNoHardwarePlayback(engine)
    }

    func testReceiveLevelExpiresWithoutHardwarePlayback() async throws {
        let engine = AudioEngine(hardwareEnabled: false)
        defer { engine.stopAll() }
        engine.playReceivedPCM([10_000, -10_000])
        XCTAssertGreaterThan(engine.outputLevel, 0)

        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(engine.outputLevel, 0)
        assertNoHardwarePlayback(engine)
    }

    func testSynchronousTransmitFlushPreservesPartialGSMTailExactlyOnce() throws {
        let engine = AudioEngine(hardwareEnabled: false)
        defer { engine.stopAll() }
        let speech = (0..<701).map { Int16($0 % 40 < 20 ? 10_000 : -10_000) }
        var packets: [Data] = []
        var capturedPCM: [Int16] = []
        engine.onCapturedAudio = { packets.append($0) }
        engine.onCapturedPCM = { capturedPCM.append(contentsOf: $0) }

        engine.encodeTransmitPCM(speech)
        XCTAssertEqual(packets.count, 1)
        let tail = engine.stopCaptureAndFlush()

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets.last, tail)
        XCTAssertEqual(capturedPCM, speech)
        let payload = try packets.reduce(into: Data()) {
            $0.append(try XCTUnwrap(GSMCodec.stripHeader($1)))
        }
        let padded = speech + Array(repeating: Int16(0), count: 1_280 - speech.count)
        XCTAssertEqual(payload, GSMCodec.stripHeader(GSMCodec().encode(padded)))
        XCTAssertEqual(GSMCodec().decodePacket(payload).count, 1_280)
        XCTAssertTrue(engine.stopCaptureAndFlush().isEmpty)
        XCTAssertEqual(packets.count, 2)
        assertNoHardwarePlayback(engine)
    }

    func testPendingBufferFlushDeliversTailAndResetsForTheNextTurn() async throws {
        let engine = AudioEngine(hardwareEnabled: false)
        defer { engine.stopAll() }
        let speech: [Int16] = [10_000, -10_000, 10_000]
        var packets: [Data] = []
        engine.onCapturedAudio = { packets.append($0) }

        engine.encodeTransmitPCM(speech)
        XCTAssertTrue(packets.isEmpty)
        let firstTail = await engine.stopCaptureAndFlushPendingBuffers()
        XCTAssertEqual(firstTail.count, 1)
        XCTAssertEqual(packets, firstTail)
        let payload = try XCTUnwrap(GSMCodec.stripHeader(try XCTUnwrap(firstTail.first)))
        XCTAssertEqual(GSMCodec().decodePacket(payload).count, 640)
        let repeatedTail = await engine.stopCaptureAndFlushPendingBuffers()
        XCTAssertTrue(repeatedTail.isEmpty)
        XCTAssertEqual(packets, firstTail)

        engine.encodeTransmitPCM(speech)
        let secondTail = await engine.stopCaptureAndFlushPendingBuffers()
        XCTAssertEqual(secondTail, firstTail)
        XCTAssertEqual(packets, firstTail + secondTail)
        assertNoHardwarePlayback(engine)
    }

    func testResetAndRepeatedTeardownDiscardStaleTransmitState() async {
        let engine = AudioEngine(hardwareEnabled: false)
        var packets: [Data] = []
        engine.onCapturedAudio = { packets.append($0) }
        engine.encodeTransmitPCM([1_000])
        engine.resetCodecState()
        XCTAssertTrue(engine.stopCaptureAndFlush().isEmpty)
        XCTAssertTrue(packets.isEmpty)

        engine.playReceivedPCM([5_000, -5_000])
        engine.encodeTransmitPCM([2_000])
        engine.stopAll()
        engine.stopAll()
        XCTAssertEqual(engine.outputLevel, 0)
        XCTAssertEqual(engine.inputLevel, 0)
        let discardedTail = await engine.stopCaptureAndFlushPendingBuffers()
        XCTAssertTrue(discardedTail.isEmpty)
        XCTAssertTrue(packets.isEmpty)

        let silence = Array(repeating: Int16(0), count: 640)
        engine.encodeTransmitPCM(silence)
        XCTAssertEqual(packets, [GSMCodec().encode(silence)])
        engine.stopAll()
        assertNoHardwarePlayback(engine)
    }

    func testLevelExpiryTaskDoesNotRetainOfflineEngine() {
        weak var releasedEngine: AudioEngine?
        do {
            let engine = AudioEngine(hardwareEnabled: false)
            releasedEngine = engine
            engine.playReceivedPCM([5_000, -5_000])
        }
        XCTAssertNil(releasedEngine)
    }

    private func assertNoHardwarePlayback(
        _ engine: AudioEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(engine.isRunning, file: file, line: line)
        XCTAssertEqual(engine.receiveReorderHeadroomSamples, 0, file: file, line: line)
        XCTAssertEqual(engine.livePlaybackDiagnostics.bufferedMilliseconds, 0, file: file, line: line)
        XCTAssertEqual(engine.livePlaybackDiagnostics.deviceDelayMilliseconds, 0, file: file, line: line)
#if DEBUG
        XCTAssertEqual(engine.auditPlaybackSnapshot["actualEngineRunning"], 0, file: file, line: line)
        XCTAssertEqual(engine.auditPlaybackSnapshot["scheduledSamples"], 0, file: file, line: line)
        XCTAssertEqual(engine.auditPlaybackSnapshot["remainingSamples"], 0, file: file, line: line)
        XCTAssertTrue(engine.auditPlaybackSchedule.isEmpty, file: file, line: line)
#endif
    }
}
