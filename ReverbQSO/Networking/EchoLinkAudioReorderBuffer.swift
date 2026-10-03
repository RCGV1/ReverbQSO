// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reorders a small number of out-of-order RTP-style voice packets without
/// adding latency to packets that arrive in sequence.
struct EchoLinkAudioReorderBuffer {
    private static let gapWaitInterval: TimeInterval = 0.040
    private static let restartInactivityInterval: TimeInterval = 2
    private static let maximumPendingPackets = 4
    private static let maximumTrackedStreams = 32

    private struct PendingPacket {
        let data: Data
        let receivedAt: TimeInterval
    }

    private struct StreamState {
        var lastDeliveredSequence: UInt16
        var lastActivityAt: TimeInterval
        var pending: [UInt16: PendingPacket] = [:]
    }

    private var streamsBySSRC: [UInt32: StreamState] = [:]

    var nextDeadline: TimeInterval? {
        streamsBySSRC.values.compactMap { stream in
            stream.pending.values.map(\.receivedAt).min().map { $0 + Self.gapWaitInterval }
        }.min()
    }

    var pendingPacketCount: Int {
        streamsBySSRC.values.reduce(0) { $0 + $1.pending.count }
    }

    var trackedStreamCount: Int { streamsBySSRC.count }

    mutating func insert(
        _ data: Data,
        metadata: EchoLinkVoicePacketMetadata?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [Data] {
        guard let metadata else { return [data] }

        if var stream = streamsBySSRC[metadata.ssrc] {
            if now - stream.lastActivityAt >= Self.restartInactivityInterval {
                streamsBySSRC[metadata.ssrc] = StreamState(
                    lastDeliveredSequence: metadata.sequenceNumber,
                    lastActivityAt: now
                )
                return [data]
            }

            let distance = Int(metadata.sequenceNumber &- stream.lastDeliveredSequence)
            guard distance != 0, distance < 0x8000 else { return [] }
            guard stream.pending[metadata.sequenceNumber] == nil else { return [] }
            stream.lastActivityAt = now

            if distance == 1 {
                stream.lastDeliveredSequence = metadata.sequenceNumber
                var output = [data]
                output.append(contentsOf: releaseContiguousPackets(from: &stream))
                streamsBySSRC[metadata.ssrc] = stream
                return output
            }

            stream.pending[metadata.sequenceNumber] = PendingPacket(data: data, receivedAt: now)
            var output: [Data] = []
            if stream.pending.count > Self.maximumPendingPackets {
                output = skipGapAndRelease(from: &stream)
            }
            streamsBySSRC[metadata.ssrc] = stream
            return output
        }

        evictStreamIfNeeded()
        streamsBySSRC[metadata.ssrc] = StreamState(
            lastDeliveredSequence: metadata.sequenceNumber,
            lastActivityAt: now
        )
        return [data]
    }

    mutating func drain(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [Data] {
        let expiredSSRCs = streamsBySSRC.compactMap { ssrc, stream -> (UInt32, TimeInterval)? in
            guard let oldest = stream.pending.values.map(\.receivedAt).min() else { return nil }
            let deadline = oldest + Self.gapWaitInterval
            return deadline <= now ? (ssrc, deadline) : nil
        }.sorted {
            $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1
        }.map(\.0)

        var output: [Data] = []
        for ssrc in expiredSSRCs {
            guard var stream = streamsBySSRC[ssrc] else { continue }
            output.append(contentsOf: skipGapAndRelease(from: &stream))
            streamsBySSRC[ssrc] = stream
        }
        return output
    }

    mutating func reset() {
        streamsBySSRC.removeAll(keepingCapacity: true)
    }

    private func releaseContiguousPackets(from stream: inout StreamState) -> [Data] {
        var output: [Data] = []
        while let packet = stream.pending.removeValue(forKey: stream.lastDeliveredSequence &+ 1) {
            stream.lastDeliveredSequence &+= 1
            output.append(packet.data)
        }
        return output
    }

    private func skipGapAndRelease(from stream: inout StreamState) -> [Data] {
        guard let nextSequence = stream.pending.keys.min(by: {
            ($0 &- stream.lastDeliveredSequence) < ($1 &- stream.lastDeliveredSequence)
        }), let packet = stream.pending.removeValue(forKey: nextSequence) else {
            return []
        }

        stream.lastDeliveredSequence = nextSequence
        var output = [packet.data]
        output.append(contentsOf: releaseContiguousPackets(from: &stream))
        return output
    }

    private mutating func evictStreamIfNeeded() {
        guard streamsBySSRC.count >= Self.maximumTrackedStreams,
              let leastRecentSSRC = streamsBySSRC.min(by: {
                  $0.value.lastActivityAt < $1.value.lastActivityAt
              })?.key else { return }
        streamsBySSRC.removeValue(forKey: leastRecentSSRC)
    }
}
