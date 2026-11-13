// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Applies a small, feedback-driven sample-rate correction to received PCM.
///
/// The playback queue is the clock-error signal. Sustained growth produces
/// slightly fewer samples, while sustained depletion produces slightly more.
/// Packet timing and loss remain the responsibility of the jitter buffer.
final class ReceiveClockCompensator {
    private static let queueErrorForMaximumCorrection = 240.0
    private static let maximumCorrection = 0.005
    private static let feedbackSmoothing = 0.02
    // Clock drift needs tiny corrections. A burst needs faster recovery so
    // extra speech does not remain queued for tens of seconds. Taper catch-up
    // near the jitter target and keep total sample shortening within 3%.
    private static let catchupDeadbandSamples = 128.0 // 16 ms
    private static let catchupRangeSamples = 640.0 // 80 ms
    private static let maximumCatchup = 0.025
    private static let catchupSmoothing = 0.08

    private var smoothedQueueError = 0.0
    private var fractionalOutputSamples = 0.0
    private var catchupCorrection = 0.0
    private var sourceHistory: [Int16] = []

    private(set) var correctionRatio = 1.0

    /// Resamples one packet using the current playback queue as clock feedback.
    /// Reset explicitly at a new talk spurt; an underrun still needs correction.
    func process(_ samples: [Int16], queuedSamples: Int, targetQueuedSamples: Int = 640) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        defer { sourceHistory = Array(samples.suffix(17)) }

        let queueError = Double(max(0, queuedSamples) - max(0, targetQueuedSamples))
        let normalizedError = max(
            -1,
            min(1, queueError / Self.queueErrorForMaximumCorrection)
        )
        smoothedQueueError += Self.feedbackSmoothing * (normalizedError - smoothedQueueError)
        let excess = max(0, queueError - Self.catchupDeadbandSamples)
        let desiredCatchup = Self.maximumCatchup * min(1, excess / Self.catchupRangeSamples)
        if queueError <= 0 {
            // A stalled/depleted renderer needs lead, not residual catch-up.
            catchupCorrection = 0
        } else {
            catchupCorrection += Self.catchupSmoothing * (desiredCatchup - catchupCorrection)
        }
        correctionRatio = 1 - (Self.maximumCorrection * smoothedQueueError) - catchupCorrection

        let previousFraction = fractionalOutputSamples
        let exactOutputCount = Double(samples.count) * correctionRatio
            + fractionalOutputSamples
        let outputCount = max(1, Int(exactOutputCount.rounded(.down)))
        fractionalOutputSamples = exactOutputCount - Double(outputCount)

        guard samples.count > 1, outputCount > 1,
              correctionRatio != 1 || previousFraction != 0 else {
            return samples
        }

        let cutoff = outputCount < samples.count ? 0.95 * Double(outputCount) / Double(samples.count) : 1
        return (0..<outputCount).map { outputIndex in
            // Invert cumulative output time even when this packet's count is
            // unchanged, rather than restarting sample phase at its endpoints.
            let position = (Double(outputIndex + 1) - previousFraction) / correctionRatio - 1
            let center = Int(position.rounded(.down))
            // Keep the past-side kernel when future support is unavailable;
            // narrowing both sides attenuates upper-speech-band packet edges.
            let radius = 16.0
            let truncated = center + 16 >= samples.count
            var sum = 0.0
            var weightSum = 0.0
            var minimum = Int16.max
            var maximum = Int16.min
            for index in (center - 15)...min(center + 16, samples.count - 1) {
                let distance = position - Double(index)
                guard abs(distance) < radius else { continue }
                let argument = Double.pi * cutoff * distance
                let sinc = abs(argument) < 1e-12 ? 1 : sin(argument) / argument
                let window = 0.5 * (1 + cos(Double.pi * distance / radius))
                let weight = cutoff * sinc * window
                let value: Int16
                if index < 0, !sourceHistory.isEmpty {
                    value = sourceHistory[max(0, sourceHistory.count + index)]
                } else {
                    value = samples[min(samples.count - 1, max(0, index))]
                }
                sum += Double(value) * weight
                weightSum += weight
                if truncated {
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                }
            }
            // Missing future taps cannot constrain asymmetric-kernel overshoot.
            // Bound only those outputs to the available support's PCM envelope.
            let value = sum / weightSum
            let bounded = truncated ? min(Double(maximum), max(Double(minimum), value)) : value
            return Int16(clamping: Int(bounded.rounded()))
        }
    }

    func reset() {
        smoothedQueueError = 0
        fractionalOutputSamples = 0
        catchupCorrection = 0
        correctionRatio = 1
        sourceHistory.removeAll(keepingCapacity: true)
    }
}
