// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Native loss recovery runs before the next valid decode, in stream order.
/// Validation uses an independent decoder so corrupt packets cannot reset speech history.
final class SpeexReceiveStreamDecoder {
    struct Audio {
        let received: [Int16]
        let concealed: [Int16]
    }
    private struct Stream {
        let codec = SpeexCodec()
        var metadata: EchoLinkVoicePacketMetadata?
        var lastArrival = -Double.infinity
    }
    private let validator = SpeexCodec()
    private var streams: [UInt64: Stream] = [:]

    func decode(_ payload: Data, metadata: EchoLinkVoicePacketMetadata?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Audio? {
        guard validator.decodePacket(payload) != nil else { return nil }
        let key = metadata.map { UInt64($0.ssrc) } ?? (UInt64(UInt32.max) + 1)
        if streams[key] == nil, streams.count >= 8, let oldest = streams.min(by: { $0.value.lastArrival < $1.value.lastArrival })?.key {
            streams.removeValue(forKey: oldest)
        }
        var stream = streams[key] ?? Stream()
        var concealed: [Int16] = []
        if let metadata, let previous = stream.metadata, now - stream.lastArrival < 0.5 {
            let distance = Int(metadata.sequenceNumber &- previous.sequenceNumber)
            guard distance > 0, distance < 0x8000 else { return nil }
            if (2...3).contains(distance) {
                let missingSamples = (distance - 1) * SpeexCodec.samplesPerPacket
                concealed = stream.codec.concealMissingSamples(missingSamples) ?? []
            } else if distance != 1 { stream.codec.reset() }
        } else if stream.lastArrival == -Double.infinity || now - stream.lastArrival >= 0.5 {
            stream.codec.reset()
        }
        guard let received = stream.codec.decodePacket(payload) else { return nil }
        stream.metadata = metadata
        stream.lastArrival = now
        streams[key] = stream
        return Audio(received: received, concealed: concealed)
    }
    func reset() {
        streams.removeAll(keepingCapacity: true)
        validator.reset()
    }
}
