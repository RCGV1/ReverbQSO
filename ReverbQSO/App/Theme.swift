// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// App-wide design tokens. Use these instead of raw values so changes
/// propagate everywhere at once.
enum Theme {

    // MARK: - Spacing

    static let xs: CGFloat  =  4
    static let sm: CGFloat  =  8
    static let md: CGFloat  = 16
    static let lg: CGFloat  = 24
    static let xl: CGFloat  = 32
    static let xxl: CGFloat = 48

    // MARK: - Corner Radii

    static let radiusSm: CGFloat = 8
    static let radiusMd: CGFloat = 14
    static let radiusLg: CGFloat = 20
    static let radiusFull: CGFloat = 999

    // MARK: - Type scale (augments system fonts)

    static let callsignFont = Font.system(size: 42, weight: .bold, design: .monospaced)
    static let timerFont    = Font.system(size: 18, weight: .medium, design: .monospaced)

    // MARK: - Semantic Colors

    /// Connected / active / transmitting
    static let txGreen  = Color(red: 0.18, green: 0.80, blue: 0.44)
    /// Incoming / receiving
    static let rxBlue   = Color(red: 0.20, green: 0.60, blue: 1.00)
    /// Warning / busy
    static let busyRed  = Color(red: 1.00, green: 0.27, blue: 0.27)
    /// Offline / idle
    static let idleGray = Color(.systemGray3)

    // MARK: - Station type tints

    static func tint(for type: Station.StationType, busy: Bool) -> Color {
        if busy { return busyRed }
        switch type {
        case .user:       return Color.orange
        case .link:       return rxBlue
        case .repeater:   return txGreen
        case .conference: return Color.purple
        }
    }

    // MARK: - View helpers

    /// Frosted-glass card background that adapts to dark / light mode.
    static func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
    }
}

// MARK: - Convenience Modifiers

extension View {
    /// Wraps the view in a frosted-glass card.
    func cardStyle(padding: CGFloat = Theme.md) -> some View {
        self
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
    }
}
