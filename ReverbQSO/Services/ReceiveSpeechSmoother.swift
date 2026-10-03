// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Applies concealment only to confirmed short sequence gaps, never idle tails.
/// A talker/codec change resets history so one station cannot replay another.
final class ReceiveSpeechSmoother {
    private let concealer = ReceivePacketLossConcealer()
    private var previous: EchoLinkVoicePacketMetadata?
    private var previousCount = 0
    private var lastArrival = -Double.infinity
    func process(_ samples: [Int16], metadata: EchoLinkVoicePacketMetadata?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        var gap: [Int16] = []
        if let metadata, let previous, metadata.ssrc == previous.ssrc,
           metadata.payloadType == previous.payloadType, now - lastArrival < 0.5, now >= lastArrival {
            let distance = Int(metadata.sequenceNumber &- previous.sequenceNumber)
            if (2...3).contains(distance), previousCount <= 640 {
                let timestampGap = metadata.timestamp &- (previous.timestamp &+ UInt32(previousCount))
                // Older peers send constant timestamps. Use sequence duration only then.
                let plausibleTimestamp = metadata.timestamp != previous.timestamp &&
                    timestampGap >= UInt32(min(80, previousCount)) && timestampGap <= 1280
                let missing = plausibleTimestamp ? Int(timestampGap) : (distance - 1) * previousCount
                if (1...1280).contains(missing) {
                    gap = concealer.conceal(sampleCount: missing)
                } else { concealer.reset() }
            } else if distance != 1 { concealer.reset() }
        } else { concealer.reset() }
        let speech = concealer.processReceived(samples)
        self.previous = metadata
        previousCount = samples.count
        lastArrival = now
        return gap + speech
    }
    func reset() {
        concealer.reset()
        previous = nil
        previousCount = 0
        lastArrival = -Double.infinity
    }
}
