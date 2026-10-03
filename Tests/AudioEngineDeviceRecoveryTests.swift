// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import XCTest
@testable import ReverbQSO

@MainActor
final class AudioEngineDeviceRecoveryTests: XCTestCase {
    func testInterruptionBlocksPlaybackAndStillRecordsReceivedSamples() async {
        let engine = AudioEngine()
        engine.startPlayback()
        defer { engine.stopAll() }
        postInterruption(.began)
        await settle()
        XCTAssertFalse(engine.isRunning)
        var recorded: [Int16] = []
        engine.onRecordingPCM = { recorded = $0 }
        engine.playReceivedPCM([100, -100])
        XCTAssertEqual(recorded, [100, -100])
        XCTAssertFalse(engine.isRunning)
    }

    func testInterruptionWithoutResumeDoesNotRestartOnReceivedAudio() async {
        let engine = AudioEngine()
        engine.startPlayback()
        defer { engine.stopAll() }
        postInterruption(.began)
        await settle()
        postInterruption(.ended)
        await settle()
        engine.playReceivedPCM([100, -100])
        XCTAssertFalse(engine.isRunning)
    }

    func testStoppedSessionCannotRestartAfterInterruptionOrMediaReset() async {
        let engine = AudioEngine()
        engine.startPlayback()
        postInterruption(.began)
        await settle()
        engine.stopAll()
        postInterruption(.ended, options: .shouldResume)
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification,
                                        object: AVAudioSession.sharedInstance())
        await settle()
        XCTAssertFalse(engine.isRunning)
    }

    private func postInterruption(_ type: AVAudioSession.InterruptionType,
                                  options: AVAudioSession.InterruptionOptions = []) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), userInfo: [
                AVAudioSessionInterruptionTypeKey: NSNumber(value: type.rawValue),
                AVAudioSessionInterruptionOptionKey: NSNumber(value: options.rawValue)
            ])
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
}
