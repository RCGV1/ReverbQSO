// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A small colored capsule label showing station type (L/R/C) and busy state.
struct StatusBadge: View {

    let stationType: Station.StationType
    var isBusy: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(stationType.rawValue)
                .font(.caption2.bold())

            if isBusy {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(badgeColor.opacity(0.15))
        .foregroundStyle(badgeColor)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(badgeColor.opacity(0.3), lineWidth: 1)
        )
        .accessibilityLabel(accessibilityText)
    }

    private var badgeColor: Color {
        if isBusy { return .red }
        switch stationType {
        case .user: return .orange
        case .link: return .blue
        case .repeater: return .green
        case .conference: return .purple
        }
    }

    private var accessibilityText: String {
        let typeText = stationType.displayName
        let busyText = isBusy ? ", busy" : ""
        return "\(typeText)\(busyText)"
    }
}
