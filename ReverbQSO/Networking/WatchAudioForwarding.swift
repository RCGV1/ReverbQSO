// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct WatchAudioFrame: Codable, Sendable {
    let version: Int
    let streamID: UUID
    let sequence: UInt64
    let sentAt: Date
    let datagram: Data

    static func decode(_ data: Data) -> WatchAudioFrame? {
        guard data.count <= 8_192,
              let frame = try? JSONDecoder().decode(Self.self, from: data),
              frame.version == 1, !frame.datagram.isEmpty, frame.datagram.count <= 4_096 else { return nil }
        return frame
    }
}

struct WatchAudioReceiveSequence {
    private var streamID: UUID?
    private var lastSequence: UInt64?

    mutating func accept(_ frame: WatchAudioFrame, expectedStreamID: UUID?, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(frame.sentAt)
        guard frame.streamID == expectedStreamID, age.isFinite, age >= -2, age <= 1 else { return false }
        if streamID != frame.streamID {
            streamID = frame.streamID
            lastSequence = nil
        }
        guard lastSequence.map({ frame.sequence > $0 }) ?? true else { return false }
        lastSequence = frame.sequence
        return true
    }
}

/// One acknowledged message at a time; slow links discard queued old speech.
@MainActor
final class WatchAudioForwarder {
    typealias Send = (Data, @escaping (Data) -> Void, @escaping (Error) -> Void) -> Void
    private let send: Send
    var onFailure: (() -> Void)?
    private var queue: [WatchAudioFrame] = []
    private var streamID: UUID?
    private var sequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var inFlight = false
    private var timeout: Task<Void, Never>?

    init(send: @escaping Send) { self.send = send }

    func forward(_ datagram: Data, streamID: UUID) {
        guard !datagram.isEmpty, datagram.count <= 4_096 else { return }
        if self.streamID != streamID { stop(); self.streamID = streamID }
        sequence &+= 1
        if queue.count >= 3 { queue.removeFirst() }
        queue.append(WatchAudioFrame(version: 1, streamID: streamID, sequence: sequence,
                                    sentAt: Date(), datagram: datagram))
        drain()
    }

    func stop() {
        generation &+= 1
        timeout?.cancel()
        timeout = nil
        queue.removeAll()
        inFlight = false
        streamID = nil
        sequence = 0
    }

    private func drain() {
        guard !inFlight else { return }
        queue.removeAll { Date().timeIntervalSince($0.sentAt) > 0.35 }
        guard !queue.isEmpty else { return }
        let frame = queue.removeFirst()
        guard let data = try? JSONEncoder().encode(frame) else { fail(); return }
        inFlight = true
        generation &+= 1
        let token = generation
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard let self, self.generation == token else { return }
            self.fail()
        }
        send(data, { [weak self] reply in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                guard reply == Data([1]) else { self.fail(); return }
                self.timeout?.cancel()
                self.timeout = nil
                self.inFlight = false
                self.drain()
            }
        }, { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.fail()
            }
        })
    }

    private func fail() { stop(); onFailure?() }
    deinit { timeout?.cancel() }
}
