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
    @EnvironmentObject var appState: AppState
    @State private var selectedCallsign = ""
    @State private var favoriteState = false
    @State private var report: StationRFReport?
    @State private var isLoadingReport = false
    @State private var reportFailed = false
    @State private var reportLoadGeneration = UUID()

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

                            if !station.displayDescription.isEmpty {
                                infoRow(icon: "text.quote", label: "Description", value: station.displayDescription)
                            }

                            if let count = station.reportedConnections {
                                infoRow(icon: "person.2", label: "Connections", value: count.displayText)
                                infoRow(icon: "person.2.badge.gearshape", label: "Advertised connection limit", value: "\(count.limit)")
                            }

                            if station.type == .link || station.type == .repeater {
                                stationReport
                            }

                        }
                        .padding(.horizontal, 24)
                        if !station.isRelayOnly, savedCallsigns.count > 1 {
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
                // Keep scrolled content inside its viewport, below the title bar
                // and above the pinned connection controls.
                .clipped()

                // Connect button at bottom
                if !station.isRelayOnly {
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
                        .disabled(!isOnline || station.connectionUnavailableReason != nil)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        if let reason = !isOnline ? "Station is no longer online." : station.connectionUnavailableReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .padding(.top, 8)
                        }
                    }
                    .padding(.bottom, 16)
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
        .task(id: reportTaskID) {
            await loadStationReport()
        }
        .onAppear {
            selectedCallsign = currentCallsign
            favoriteState = isFavorite
        }
    }

    // MARK: - Subviews

    private var stationReport: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Station report")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isLoadingReport {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading report…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if reportFailed {
                Text("Report unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let report {
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.status)
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 4) {
                        Text("Updated \(relativeDate(report.updatedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityValue(report.updatedAt.formatted(date: .complete, time: .shortened))
                    }
                    if !report.comment.isEmpty {
                        Text(report.comment)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } else {
                Text("No report available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Station reports do not confirm call availability.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var reportTaskID: String {
        "\(station.callsign.uppercased())-\(station.nodeNumber)"
    }

    @MainActor
    private func loadStationReport() async {
        guard station.type == .link || station.type == .repeater else { return }

        let generation = UUID()
        reportLoadGeneration = generation
        report = nil
        reportFailed = false
        isLoadingReport = true
        defer {
            if reportLoadGeneration == generation {
                isLoadingReport = false
            }
        }

        if isOfflineDemo {
            // Keep simulator demos deterministic and offline. Only the demo repeater
            // has a local report; other demo stations exercise the empty state.
            if station.type == .repeater {
                report = StationRFReport(
                    callsign: station.callsign,
                    nodeNumber: station.nodeNumber,
                    updatedAt: Date.now.addingTimeInterval(-120),
                    status: "Operational",
                    comment: "Demo repeater report"
                )
            }
            return
        }

        do {
            let fetched = try await StationRFReportClient.shared.report(for: station)
            guard !Task.isCancelled, reportLoadGeneration == generation else { return }
            report = fetched
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, reportLoadGeneration == generation else { return }
            reportFailed = true
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let clampedDate = min(date, .now)
        return clampedDate.formatted(.relative(presentation: .named))
    }

    private var isOfflineDemo: Bool {
        if appState.isDemoMode { return true }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        return SimulatorDemoData.isEnabled
#else
        return false
#endif
    }

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
