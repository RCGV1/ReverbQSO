// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ReverbQSO

@MainActor
final class RecordingAudioSessionTests: XCTestCase {
    func testPlaybackDoesNotChangeAudioSessionDuringLiveQSO() throws {
        var activations = 0
        let audio = RecordingAudioSession(activate: { activations += 1 }, deactivate: {})
        let owner = NSObject()
        audio.beginLiveAudio(owner: owner)
        XCTAssertThrowsError(try audio.beginPlayback(id: UUID(), onStop: {}))
        XCTAssertEqual(activations, 0)
        audio.endLiveAudio(owner: owner)
        try audio.beginPlayback(id: UUID(), onStop: {})
        XCTAssertEqual(activations, 1)
    }

    func testQSOStopsRecordingBeforeTakingAudioWithoutDeactivatingLiveSession() throws {
        var stopped = false
        var deactivations = 0
        let audio = RecordingAudioSession(activate: {}, deactivate: { deactivations += 1 })
        let id = UUID()
        try audio.beginPlayback(id: id) {
            stopped = true
            audio.endPlayback(id: id)
        }
        let owner = NSObject()
        audio.beginLiveAudio(owner: owner)
        XCTAssertTrue(stopped)
        XCTAssertEqual(deactivations, 0)
    }

    func testMultipleQSOOwnersMustAllReleaseAudioBeforePlayback() throws {
        let audio = RecordingAudioSession(activate: {}, deactivate: {})
        let first = NSObject(), second = NSObject()
        audio.beginLiveAudio(owner: first)
        audio.beginLiveAudio(owner: second)
        audio.endLiveAudio(owner: first)
        XCTAssertThrowsError(try audio.beginPlayback(id: UUID(), onStop: {}))
        audio.endLiveAudio(owner: second)
        XCTAssertNoThrow(try audio.beginPlayback(id: UUID(), onStop: {}))
    }

    func testDestroyedQSOOwnerDoesNotBlockPlayback() throws {
        let audio = RecordingAudioSession(activate: {}, deactivate: {})
        var owner: NSObject? = NSObject()
        audio.beginLiveAudio(owner: owner!)
        owner = nil
        XCTAssertNoThrow(try audio.beginPlayback(id: UUID(), onStop: {}))
    }

    func testOldPlayerCompletionCannotStopNewPlayback() throws {
        var stopped = false
        var deactivations = 0
        let audio = RecordingAudioSession(activate: {}, deactivate: { deactivations += 1 })
        let oldID = UUID(), newID = UUID()
        try audio.beginPlayback(id: oldID) { stopped = true }
        try audio.beginPlayback(id: newID, onStop: {})
        XCTAssertTrue(stopped)
        audio.endPlayback(id: oldID)
        XCTAssertEqual(deactivations, 0)
        audio.endPlayback(id: newID)
        XCTAssertEqual(deactivations, 1)
    }

    func testFinalLiveOwnerDeactivatesSessionExactlyOnce() {
        var deactivations = 0
        let audio = RecordingAudioSession(activate: {}, deactivate: { deactivations += 1 })
        let first = NSObject(), second = NSObject()
        audio.beginLiveAudio(owner: first)
        audio.beginLiveAudio(owner: second)
        audio.endLiveAudio(owner: first)
        XCTAssertEqual(deactivations, 0, "Another QSO or host still owns live audio")
        audio.endLiveAudio(owner: second)
        XCTAssertEqual(deactivations, 1, "Disconnect must release the microphone route")
        audio.endLiveAudio(owner: second)
        audio.endLiveAudio(owner: NSObject())
        XCTAssertEqual(deactivations, 1)
    }

    func testStaleLiveReleaseCannotDeactivateSavedRecordingPlayback() throws {
        var deactivations = 0
        let audio = RecordingAudioSession(activate: {}, deactivate: { deactivations += 1 })
        let owner = NSObject()
        audio.beginLiveAudio(owner: owner)
        audio.endLiveAudio(owner: owner)
        XCTAssertEqual(deactivations, 1)
        let playbackID = UUID()
        try audio.beginPlayback(id: playbackID, onStop: {})
        audio.endLiveAudio(owner: owner)
        XCTAssertEqual(deactivations, 1, "Saved recording retains session ownership")
        audio.endPlayback(id: playbackID)
        XCTAssertEqual(deactivations, 2)
    }

    func testExpiredOtherLiveOwnerDoesNotPreventFinalSessionRelease() {
        var deactivations = 0
        let audio = RecordingAudioSession(activate: {}, deactivate: { deactivations += 1 })
        var expired: NSObject? = NSObject()
        let remaining = NSObject()
        audio.beginLiveAudio(owner: expired!)
        audio.beginLiveAudio(owner: remaining)
        expired = nil
        audio.endLiveAudio(owner: remaining)
        XCTAssertEqual(deactivations, 1)
    }

    func testFailedSessionActivationDoesNotLeavePlaybackOwner() {
        var deactivations = 0
        let audio = RecordingAudioSession(activate: { throw CocoaError(.fileReadUnknown) },
                                          deactivate: { deactivations += 1 })
        let id = UUID()
        XCTAssertThrowsError(try audio.beginPlayback(id: id, onStop: {}))
        audio.endPlayback(id: id)
        XCTAssertEqual(deactivations, 1, "A failed activation must release any partially acquired session")
    }

    func testFailedReplacementActivationReleasesPreviousPlaybackSession() throws {
        var activations = 0
        var sessionActive = false
        var stoppedPrevious = false
        var deactivations = 0
        let audio = RecordingAudioSession(activate: {
            activations += 1
            if activations == 2 { throw CocoaError(.fileReadUnknown) }
            sessionActive = true
        }, deactivate: {
            sessionActive = false
            deactivations += 1
        })
        let firstID = UUID(), secondID = UUID()
        try audio.beginPlayback(id: firstID) {
            stoppedPrevious = true
            audio.endPlayback(id: firstID)
        }
        XCTAssertTrue(sessionActive)

        XCTAssertThrowsError(try audio.beginPlayback(id: secondID, onStop: {}))

        XCTAssertTrue(stoppedPrevious)
        XCTAssertFalse(sessionActive, "The stopped recording must not retain audio after replacement fails")
        XCTAssertEqual(deactivations, 1)
        audio.endPlayback(id: firstID)
        audio.endPlayback(id: secondID)
        XCTAssertEqual(deactivations, 1, "Stale completions must not release another owner's audio")
    }
}
