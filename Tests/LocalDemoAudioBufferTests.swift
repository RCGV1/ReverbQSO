// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class LocalDemoAudioBufferTests: XCTestCase {
    func testRecordingIsLimitedToThirtySecondsOfCompleteGSMPackets() {
        var buffer = LocalDemoAudioBuffer()
        let packet = Data(repeating: 0xD0, count: 132)
        for _ in 0..<375 { XCTAssertTrue(buffer.append(packet)) }
        XCTAssertFalse(buffer.append(packet))
        XCTAssertEqual(buffer.packets.count, 375)
        XCTAssertEqual(buffer.takePackets().count, 375)
        XCTAssertTrue(buffer.packets.isEmpty)
    }

    func testMalformedPacketsDoNotConsumeRecordingCapacity() {
        var buffer = LocalDemoAudioBuffer()
        for length in [0, 1, 33, 131, 133] {
            XCTAssertFalse(buffer.append(Data(repeating: 0, count: length)))
        }
        XCTAssertTrue(buffer.packets.isEmpty)
        XCTAssertTrue(buffer.append(Data(repeating: 0, count: 132)))
        buffer.clear()
        XCTAssertTrue(buffer.packets.isEmpty)
    }
}
