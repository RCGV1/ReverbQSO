// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ReverbQSO

final class MacMenuBarProtocolTests: XCTestCase {
    func testCommandIsDeliveredOnceWithoutNotificationUserInfo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = UUID()
        let now = Date()
        try MacMenuBarProtocol.writeCommand(.holdPTT, id: session, directory: folder, now: now)
        let command = MacMenuBarProtocol.consumeCommand(directory: folder, now: now)
        XCTAssertEqual(command?.type, .holdPTT)
        XCTAssertEqual(command?.id, session)
        XCTAssertNil(MacMenuBarProtocol.consumeCommand(directory: folder, now: now))
    }

    func testStaleAndFutureCommandsCannotStartTransmit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        try MacMenuBarProtocol.writeCommand(.holdPTT, id: UUID(), directory: folder, now: now.addingTimeInterval(-5))
        XCTAssertNil(MacMenuBarProtocol.consumeCommand(directory: folder, now: now))
        try MacMenuBarProtocol.writeCommand(.holdPTT, id: UUID(), directory: folder, now: now.addingTimeInterval(5))
        XCTAssertNil(MacMenuBarProtocol.consumeCommand(directory: folder, now: now))
    }

    func testAppGroupContainerIsSharedInsteadOfSeparateSandboxHomes() {
        let group = URL(fileURLWithPath: "/test/group", isDirectory: true)
        let first = MacMenuBarProtocol.directory(groupContainer: group, home: "/test/app-one")
        let second = MacMenuBarProtocol.directory(groupContainer: group, home: "/test/app-two")
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.path.hasPrefix(group.path))
    }

    func testBundledLoginItemPathIsDistinguishedFromStandaloneApp() {
        XCTAssertTrue(MacMenuBarProtocol.isBundledLoginItem(
            bundleURL: URL(fileURLWithPath: "/Applications/ReverbQSO.app/Contents/Library/LoginItems/ReverbQSO Menu Bar.app")
        ))
        XCTAssertFalse(MacMenuBarProtocol.isBundledLoginItem(
            bundleURL: URL(fileURLWithPath: "/Applications/ReverbQSO Menu Bar.app")
        ))
    }
}
