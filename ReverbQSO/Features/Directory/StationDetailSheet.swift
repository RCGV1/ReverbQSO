// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Sheet presenting full details for a station with favorite toggle and connect action.
struct StationDetailSheet: View {

    let station: Station
    let isOnline: Bool
    let isFavorite: Bool
    let currentCallsign: String
    let savedCallsigns: [String]
    var onFavoriteToggle: () -> Void
    var onConnect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCallsign = ""
    @State private var favoriteState = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        // Callsign hero
                        VStack(spacing: 8) {
                            Text(station.callsign)
                                .font(.system(size: 36, weight: .bold, design: .monospaced))
                                .foregroundStyle(.primary)

                            typeBadge
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                        // Info cards
                        VStack(spacing: 12) {
                            if !isOnline {
                                Label("Station is no longer online", systemImage: "wifi.slash")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            if station.nodeNumber > 0 {
                                infoRow(
                                    icon: "number",
                                    label: station.type == .user ? "EchoLink ID" : "Node",
                                    value: "\(station.nodeNumber)"
                                )
                            }

                            if let country = station.callSignCountryName {
                                infoRow(
                                    icon: "globe.americas",
                                    label: "Callsign country",
                                    value: country
                                )
                            }

                            if let location = station.locationDisplay {
                                infoRow(
                                    icon: "mappin.and.ellipse",
                                    label: "Advertised location",
                                    value: location
                                )
                            }

                            if !station.description.isEmpty {
                                infoRow(icon: "text.quote", label: "Description", value: station.description)
                            }

                            if station.isBusy {
                                HStack(spacing: 10) {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(.red)
                                        .frame(width: 24)
                                    Text("Busy — not accepting new connections")
                                        .font(.subheadline)
                                        .foregroundStyle(.red)
                                    Spacer()
                                }
                                .padding(12)
                                .background(Color.red.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(.horizontal, 24)
                        if savedCallsigns.count > 1 {
                            Picker("Connect as", selection: $selectedCallsign) {
                                ForEach(savedCallsigns, id: \.self) { callsign in
                                    Text(callsign).tag(callsign)
                                }
                            }
                            .padding(.horizontal, 24)
                        }

                        // Favorite toggle
                        Button {
                            onFavoriteToggle()
                            favoriteState.toggle()
                        } label: {
                            Label(
                                favoriteState ? "Remove from Favorites" : "Add to Favorites",
                                systemImage: favoriteState ? "star.fill" : "star"
                            )
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .tint(favoriteState ? .yellow : .primary)
                        .padding(.horizontal, 24)

                    }
                }

                // Connect button at bottom
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        onConnect(selectedCallsign.isEmpty ? currentCallsign : selectedCallsign)
                        dismiss()
                    } label: {
                        Label(
                            station.type == .user ? "Call Operator" : "Connect",
                            systemImage: "phone.fill"
                        )
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(station.isBusy || !isOnline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle(station.type == .user ? "Operator" : "Station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            selectedCallsign = currentCallsign
            favoriteState = isFavorite
        }
    }

    // MARK: - Subviews

    private var typeBadge: some View {
        Text(station.type.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(typeColor.opacity(0.15))
            .foregroundStyle(typeColor)
            .clipShape(Capsule())
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var typeColor: Color {
        switch station.type {
        case .user:       return .orange
        case .link:       return .blue
        case .repeater:   return .green
        case .conference: return .purple
        }
    }
}
