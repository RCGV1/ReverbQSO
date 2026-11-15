// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Repairs only joins exposed by shortening native decoder concealment.
/// Decoder state must already have advanced across the entire loss interval.
final class ReceiveNativeConcealmentSmoother {
    private static let boundaryBlendSamples = 32
    private static let recoveryBlendSamples = 80
    private var previous: EchoLinkVoicePacketMetadata?
    private var lastArrival = -Double.infinity
    private var lastOutputSample: Int16?

    func process(_ received: [Int16], concealed: [Int16], metadata: EchoLinkVoicePacketMetadata?,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                 maximumConcealmentSamples: Int = 1280) -> [Int16] {
        guard !received.isEmpty else { return [] }
        let count = min(concealed.count, max(0, min(1280, maximumConcealmentSamples)))
        var retained = Array(concealed.suffix(count))
        var speech = received
        if count < concealed.count, let previous, let metadata, let lastOutputSample,
           metadata.ssrc == previous.ssrc, metadata.payloadType == previous.payloadType,
           now.isFinite, now >= lastArrival, now - lastArrival < 0.5,
           (2...3).contains(Int(metadata.sequenceNumber &- previous.sequenceNumber)) {
            // The original native leading transition was discarded with the prefix.
            for index in 0..<min(Self.boundaryBlendSamples, count) {
                retained[index] = blend(lastOutputSample, retained[index],
                    weight: Double(index + 1) / Double(Self.boundaryBlendSamples))
            }
            if count < Self.boundaryBlendSamples {
                // A tiny or empty tail changes the boundary expected by the
                // decoder's recovery. Join from what will actually be played.
                let preceding = retained.last ?? lastOutputSample
                let blendCount = min(Self.recoveryBlendSamples, speech.count)
                for index in 0..<blendCount {
                    speech[index] = blend(preceding, speech[index],
                        weight: Double(index + 1) / Double(blendCount))
                }
            }
        }
        self.previous = metadata
        lastArrival = now
        lastOutputSample = speech.last
        return retained + speech
    }

    func reset() {
        previous = nil
        lastArrival = -Double.infinity
        lastOutputSample = nil
    }

    private func blend(_ preceding: Int16, _ sample: Int16, weight: Double) -> Int16 {
        Int16(clamping: Int((Double(preceding) * (1 - weight) + Double(sample) * weight).rounded()))
    }
}
