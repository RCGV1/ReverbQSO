// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ReverbQSO

final class EchoLinkProxySendLifecycleTests: XCTestCase {
    func testSuccessfulSendDoesNotRetireConnection() async throws {
        let probe = SendProbe()
        let task = Task {
            try await EchoLinkProxySendLifecycle.run(
                timeout: .milliseconds(50),
                start: probe.start,
                retire: probe.retire
            )
        }
        await waitUntilStarted(probe)
        probe.complete()

        try await task.value
        try? await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(probe.retireCount, 0)
    }

    func testTimeoutRetiresOnceAndLateCompletionIsIgnored() async {
        let probe = SendProbe()
        do {
            try await EchoLinkProxySendLifecycle.run(
                timeout: .milliseconds(10),
                start: probe.start,
                retire: probe.retire
            )
            XCTFail("Expected send timeout")
        } catch EchoLinkProxyClient.ClientError.sendTimedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(probe.retireCount, 1)
        probe.complete()
        XCTAssertEqual(probe.retireCount, 1)
    }

    func testCancellationRetiresOnceAndLateTimeoutAndCompletionAreIgnored() async {
        let probe = SendProbe()
        let task = Task {
            try await EchoLinkProxySendLifecycle.run(
                timeout: .milliseconds(50),
                start: probe.start,
                retire: probe.retire
            )
        }
        await waitUntilStarted(probe)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.retireCount, 1)

        probe.complete()
        try? await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(probe.retireCount, 1)
    }

    func testAlreadyCancelledSendRetiresOnceWithoutStartingWrite() async {
        let probe = SendProbe()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await EchoLinkProxySendLifecycle.run(
                timeout: .seconds(1),
                start: probe.start,
                retire: probe.retire
            )
        }

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.startCount, 0)
        XCTAssertEqual(probe.retireCount, 1)
    }

    private func waitUntilStarted(_ probe: SendProbe) async {
        for _ in 0..<100 where !probe.hasStarted { await Task.yield() }
        XCTAssertTrue(probe.hasStarted)
    }
}

private final class SendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Error?) -> Void)?
    private var starts = 0
    private var retirements = 0

    var hasStarted: Bool {
        lock.withLock { completion != nil }
    }

    var retireCount: Int {
        lock.withLock { retirements }
    }

    var startCount: Int {
        lock.withLock { starts }
    }

    func start(_ completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock {
            starts += 1
            self.completion = completion
        }
    }

    func retire() {
        lock.withLock { retirements += 1 }
    }

    func complete(error: Error? = nil) {
        let pending = lock.withLock { completion }
        pending?(error)
    }
}
