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

    private(set) var correctionRatio = 1.0

    /// Resamples one packet using the current playback queue as clock feedback.
    /// Reset explicitly at a new talk spurt; an underrun still needs correction.
    func process(_ samples: [Int16], queuedSamples: Int, targetQueuedSamples: Int = 640) -> [Int16] {
        guard !samples.isEmpty else { return [] }

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

        let exactOutputCount = Double(samples.count) * correctionRatio
            + fractionalOutputSamples
        let outputCount = max(1, Int(exactOutputCount.rounded(.down)))
        fractionalOutputSamples = exactOutputCount - Double(outputCount)

        guard outputCount != samples.count, samples.count > 1, outputCount > 1 else {
            return samples
        }

        let sourceSpan = Double(samples.count - 1)
        let outputSpan = Double(outputCount - 1)
        let cutoff = outputCount < samples.count ? 0.95 * Double(outputCount) / Double(samples.count) : 1
        return (0..<outputCount).map { outputIndex in
            // Preserve packet joins. The complete packet is already available,
            // so the interpolation window adds no playback waiting or lookahead.
            if outputIndex == 0 { return samples[0] }
            if outputIndex == outputCount - 1 { return samples[samples.count - 1] }
            let position = Double(outputIndex) * sourceSpan / outputSpan
            let center = Int(position.rounded(.down))
            var sum = 0.0
            var weightSum = 0.0
            for index in (center - 15)...(center + 16) {
                let distance = position - Double(index)
                guard abs(distance) < 16 else { continue }
                let argument = Double.pi * cutoff * distance
                let sinc = abs(argument) < 1e-12 ? 1 : sin(argument) / argument
                let window = 0.5 * (1 + cos(Double.pi * distance / 16))
                let weight = cutoff * sinc * window
                sum += Double(samples[min(samples.count - 1, max(0, index))]) * weight
                weightSum += weight
            }
            return Int16(clamping: Int((sum / weightSum).rounded()))
        }
    }

    func reset() {
        smoothedQueueError = 0
        fractionalOutputSamples = 0
        catchupCorrection = 0
        correctionRatio = 1
    }
}
