// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A segmented horizontal bar showing audio signal level (0.0 – 1.0).
///
/// Animates smoothly when the level changes. Colour transitions from green
/// (low) through yellow (mid) to red (high).
struct SignalMeter: View {

    /// Signal level in range 0.0 (silent) to 1.0 (full scale).
    let level: Double

    /// Short label shown to the left of the meter.
    var label: String = "Signal"

    private let segmentCount = 12
    private let segmentSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 3
    private let height: CGFloat = 14

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            GeometryReader { geo in
                let totalSpacing = segmentSpacing * CGFloat(segmentCount - 1)
                let segWidth = (geo.size.width - totalSpacing) / CGFloat(segmentCount)

                HStack(spacing: segmentSpacing) {
                    ForEach(0..<segmentCount, id: \.self) { i in
                        let threshold = Double(i) / Double(segmentCount)
                        let active = level > threshold

                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(active ? segmentColor(index: i) : Color(.systemGray5))
                            .frame(width: segWidth)
                            .animation(.linear(duration: 0.05), value: level)
                    }
                }
            }
            .frame(height: height)
        }
        .accessibilityLabel("\(label): \(Int(level * 100))%")
    }

    private func segmentColor(index: Int) -> Color {
        let fraction = Double(index) / Double(segmentCount)
        if fraction < 0.6 { return .green }
        if fraction < 0.8 { return .yellow }
        return .red
    }
}
