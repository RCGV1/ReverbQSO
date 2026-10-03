// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum LiveTransportAudioPortPayloadKind: Equatable {
    case voice
    case control

    /// Control is checked first because legacy RTCP can share voice's 0xC0
    /// prefix and may legally arrive on the audio port.
    static func classify(_ data: Data) -> Self? {
        if !EchoLinkControlPacketCodec.parseEvents(from: data).isEmpty { return .control }
        guard let datagram = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(data) else {
            return .control
        }
        if case .unsupportedPayloadType = datagram.packet { return nil }
        return .voice
    }
}

enum LiveTransportMessageBufferError: Error, Equatable {
    case controlOverflow
    case multipleConsumers
}

/// A single-consumer transport buffer that bounds live voice latency while
/// retaining ordered control traffic.
final class LiveTransportMessageBuffer<Element: Sendable>: @unchecked Sendable {
    enum MessageKind: Equatable {
        case voice
        case control
    }

    private struct BufferedMessage {
        let element: Element
        let kind: MessageKind
        let insertedAt: TimeInterval?
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Element?, Error>
    }

    private let lock = NSLock()
    private let voiceCapacity: Int
    private let controlCapacity: Int
    private let maximumVoiceAge: TimeInterval
    private let now: () -> TimeInterval
    private var onConsumerCancellation: (() -> Void)?
    private var messages: [BufferedMessage] = []
    private var voiceCount = 0
    private var controlCount = 0
    private var waiter: Waiter?
    private var terminalResult: Result<Void, Error>?

    init(
        voiceCapacity: Int = 4,
        controlCapacity: Int = 128,
        maximumVoiceAge: TimeInterval = 0.24,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onConsumerCancellation: (() -> Void)? = nil
    ) {
        precondition(voiceCapacity > 0)
        precondition(controlCapacity > 0)
        precondition(maximumVoiceAge >= 0 && maximumVoiceAge.isFinite)
        self.voiceCapacity = voiceCapacity
        self.controlCapacity = controlCapacity
        self.maximumVoiceAge = maximumVoiceAge
        self.now = now
        self.onConsumerCancellation = onConsumerCancellation
    }

    func setOnConsumerCancellation(_ action: (() -> Void)?) {
        lock.lock()
        onConsumerCancellation = action
        lock.unlock()
    }

    var hasControlOverflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .failure(let error)? = terminalResult else { return false }
        return error as? LiveTransportMessageBufferError == .controlOverflow
    }

    /// Returns false when the buffer is terminal. A control overflow makes the
    /// buffer terminal and is delivered after already-buffered messages.
    @discardableResult
    func yield(_ element: Element, kind: MessageKind) -> Bool {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return false
        }

        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.continuation.resume(returning: element)
            return true
        }

        switch kind {
        case .voice:
            if voiceCount == voiceCapacity,
               let oldestVoice = messages.firstIndex(where: { $0.kind == .voice }) {
                messages.remove(at: oldestVoice)
                voiceCount -= 1
            }
            messages.append(BufferedMessage(element: element, kind: kind, insertedAt: now()))
            voiceCount += 1
        case .control:
            guard controlCount < controlCapacity else {
                terminalResult = .failure(LiveTransportMessageBufferError.controlOverflow)
                lock.unlock()
                return false
            }
            messages.append(BufferedMessage(element: element, kind: kind, insertedAt: nil))
            controlCount += 1
        }
        lock.unlock()
        return true
    }

    func next() async throws -> Element? {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                discardExpiredVoice(at: now())
                if !messages.isEmpty {
                    let message = messages.removeFirst()
                    decrementCount(for: message.kind)
                    lock.unlock()
                    continuation.resume(returning: message.element)
                } else if let terminalResult {
                    lock.unlock()
                    resume(continuation, with: terminalResult)
                } else if waiter != nil {
                    terminalResult = .failure(LiveTransportMessageBufferError.multipleConsumers)
                    let existingWaiter = waiter
                    waiter = nil
                    lock.unlock()
                    existingWaiter?.continuation.resume(
                        throwing: LiveTransportMessageBufferError.multipleConsumers
                    )
                    continuation.resume(throwing: LiveTransportMessageBufferError.multipleConsumers)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = Waiter(id: id, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancelWaiter(id: id)
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        let result: Result<Void, Error> = error.map(Result.failure) ?? .success(())
        terminalResult = result
        let pending = waiter
        waiter = nil
        lock.unlock()
        if let pending { resume(pending.continuation, with: result) }
    }

    func cancelConsumer() {
        finish(throwing: CancellationError())
    }

    private func cancelWaiter(id: UUID) {
        lock.lock()
        let pending: Waiter?
        if waiter?.id == id {
            pending = waiter
            waiter = nil
        } else {
            pending = nil
        }
        let cancellationAction = onConsumerCancellation
        lock.unlock()
        pending?.continuation.resume(throwing: CancellationError())
        cancellationAction?()
    }

    private func discardExpiredVoice(at currentTime: TimeInterval) {
        messages.removeAll { message in
            guard message.kind == .voice, let insertedAt = message.insertedAt,
                  currentTime - insertedAt > maximumVoiceAge else { return false }
            voiceCount -= 1
            return true
        }
    }

    private func decrementCount(for kind: MessageKind) {
        switch kind {
        case .voice: voiceCount -= 1
        case .control: controlCount -= 1
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<Element?, Error>,
        with result: Result<Void, Error>
    ) {
        switch result {
        case .success: continuation.resume(returning: nil)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
