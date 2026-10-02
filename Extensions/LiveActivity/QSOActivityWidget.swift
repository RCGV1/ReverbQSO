// SPDX-License-Identifier: GPL-3.0-or-later

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ReverbQSOLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        QSOActivityWidget()
    }
}

struct QSOActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QSOActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.isTransmitting ? "mic.fill" : "waveform")
                    .foregroundStyle(context.state.isTransmitting ? .red : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.callsign)
                        .font(.headline.monospaced())
                    Text(context.state.status)
                        .font(.caption)
                }
                Spacer()
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
            }
            .padding()
            .widgetURL(URL(string: "reverbqso://qso"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.callsign, systemImage: "dot.radiowaves.left.and.right")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.status)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                }
            } compactLeading: {
                Image(systemName: context.state.isTransmitting ? "mic.fill" : "waveform")
            } compactTrailing: {
                Text(context.attributes.callsign)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "waveform")
            }
            .widgetURL(URL(string: "reverbqso://qso"))
        }
    }
}
