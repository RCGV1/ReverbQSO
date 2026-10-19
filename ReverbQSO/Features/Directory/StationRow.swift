// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A single row in the station directory list.
struct StationRow: View {

    let station: Station
    var isFavorite: Bool = false
    var onSelect: (() -> Void)? = nil
    var onFavoriteTap: (() -> Void)? = nil
    var selectionHint: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let onSelect {
                Button(action: onSelect) {
                    stationContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(selectionHint ?? (station.type == .user ? "Show operator details" : "Show station details"))
            } else {
                stationContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let tap = onFavoriteTap {
                Button(action: tap) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 16))
                        .foregroundStyle(isFavorite ? .yellow : Color(.tertiaryLabel))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        }
        .padding(.vertical, 6)
    }

    private var stationContent: some View {
        HStack(spacing: 14) {
            // Type indicator pill
            typeIndicator

            // Main content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(station.callsign)
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .foregroundStyle(station.isBusy ? .secondary : .primary)
                    if let flag = station.callSignCountryFlag {
                        Text(flag)
                            .accessibilityHidden(true)
                    }
                }

                if let location = station.locationDisplay {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !station.displayDescription.isEmpty {
                    Text(station.displayDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Image(systemName: station.type.iconName)
                        .font(.caption2)
                        .foregroundStyle(typeColor.opacity(0.9))
                    Text(station.type.displayName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(typeColor.opacity(0.9))

                    if station.nodeNumber > 0 {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(station.nodeNumber)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if station.isBusy {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(station.isConnectionLimitReached ? "Full" : "Busy")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
                if let count = station.reportedConnections {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2")
                        Text(count.displayText)
                    }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Subviews

    private var typeIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(typeColor.opacity(0.18))
                .frame(width: 36, height: 36)
            Text(station.type.rawValue)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(typeColor)
        }
    }

    // MARK: - Helpers

    private var typeColor: Color {
        switch station.type {
        case .user:       return .orange
        case .link:       return .blue
        case .repeater:   return .green
        case .conference: return .purple
        }
    }

    private var accessibilityLabel: String {
        var parts = [station.callsign, station.type.displayName]
        if let country = station.callSignCountryName { parts.append(country) }
        if !station.displayDescription.isEmpty { parts.append(station.displayDescription) }
        if let count = station.reportedConnections { parts.append(count.displayText) }
        if let reason = station.connectionUnavailableReason { parts.append(reason) }
        if station.isBusy { parts.append("busy") }
        if isFavorite { parts.append("favorited") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Station.StationType helpers

private extension Station.StationType {
    var iconName: String {
        switch self {
        case .user:       return "person"
        case .link:       return "link"
        case .repeater:   return "arrow.triangle.2.circlepath"
        case .conference: return "person.3"
        }
    }
}
