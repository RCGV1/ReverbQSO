// SPDX-License-Identifier: GPL-3.0-or-later

/// Applies a small, feedback-driven sample-rate correction to received PCM.
///
/// The playback queue is the clock-error signal. Sustained growth produces
/// slightly fewer samples, while sustained depletion produces slightly more.
/// Packet timing and loss remain the responsibility of the jitter buffer.
final class ReceiveClockCompensator {
    private static let queueErrorForMaximumCorrection = 240.0
    private static let maximumCorrection = 0.005
    private static let feedbackSmoothing = 0.02

    private var smoothedQueueError = 0.0
    private var fractionalOutputSamples = 0.0

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
        correctionRatio = 1 - (Self.maximumCorrection * smoothedQueueError)

        let exactOutputCount = Double(samples.count) * correctionRatio
            + fractionalOutputSamples
        let outputCount = max(1, Int(exactOutputCount.rounded(.down)))
        fractionalOutputSamples = exactOutputCount - Double(outputCount)

        guard outputCount != samples.count, samples.count > 1, outputCount > 1 else {
            return samples
        }

        let sourceSpan = Double(samples.count - 1)
        let outputSpan = Double(outputCount - 1)
        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) * sourceSpan / outputSpan
            let lowerIndex = Int(sourcePosition.rounded(.down))
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = sourcePosition - Double(lowerIndex)
            let interpolated = Double(samples[lowerIndex])
                + (Double(samples[upperIndex]) - Double(samples[lowerIndex])) * fraction
            return Int16(clamping: Int(interpolated.rounded()))
        }
    }

    func reset() {
        smoothedQueueError = 0
        fractionalOutputSamples = 0
        correctionRatio = 1
    }
}
