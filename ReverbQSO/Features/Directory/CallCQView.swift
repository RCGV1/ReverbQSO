// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct CallCQView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: CallCQService
    let onMatch: (Station) -> Void

    @State private var preferences = CallCQPreferences.default

    private var languages: [String] {
        Locale.LanguageCode.isoLanguageCodes.map(\.identifier).sorted {
            Self.languageName($0).localizedStandardCompare(Self.languageName($1)) == .orderedAscending
        }
    }
    private var countries: [String] {
        Locale.Region.isoRegions.map(\.identifier).sorted {
            Self.countryName($0).localizedStandardCompare(Self.countryName($1)) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch service.state {
                case .waiting:
                    waitingView
                case .failed(let message):
                    failureView(message)
                case .idle, .matched:
                    preferencesForm
                }
            }
            .navigationTitle("Call CQ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task {
                            await service.cancel()
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: service.state) { _, state in
                guard case .matched(let station) = state else { return }
                dismiss()
                onMatch(station)
                service.reset()
            }
            .onDisappear {
                guard service.state == .waiting else { return }
                Task { await service.cancel() }
            }
        }
    }

    private var preferencesForm: some View {
        Form {
            Section {
                NavigationLink {
                    CallCQLanguageSelectionView(
                        languages: languages,
                        selectedCodes: $preferences.languageCodes
                    )
                } label: {
                    LabeledContent("Languages", value: languageSummary)
                        .accessibilityLabel("Languages, \(languageSummary)")
                }
                Picker("Country", selection: countrySelection) {
                    Text("Accept Any").tag("")
                    ForEach(countries, id: \.self) { code in
                        Text(Self.countryName(code)).tag(code)
                    }
                }
            } header: {
                Text("Preferences")
            } footer: {
                Text("Matching uses your spoken language, accepted country, and node types.")
            }

            Section("Connect to") {
                nodeTypeToggle("Single User Nodes", type: .user)
                nodeTypeToggle("Simplex Links (-L)", type: .link)
                nodeTypeToggle("Repeater Links (-R)", type: .repeater)
            }

            Section {
                Toggle("Skip recent contacts", isOn: $preferences.avoidRecentContacts)
            } footer: {
                Text("Avoid stations from your recent non-conference QSOs.")
            }

            Section {
                Button {
                    Task { await service.start(preferences: preferences) }
                } label: {
                    Label("Call CQ", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .disabled(preferences.nodeTypes.isEmpty || preferences.languageCodes.isEmpty)
                .accessibilityIdentifier("call-cq-start")
            }
        }
    }

    private var waitingView: some View {
        ContentUnavailableView {
            Label("Calling CQ…", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text("Waiting for another station with matching preferences.")
        } actions: {
            Button("Cancel", role: .cancel) {
                Task { await service.cancel() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("call-cq-cancel")
        }
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Call CQ Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Change Preferences") { service.reset() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func nodeTypeToggle(_ title: String, type: Station.StationType) -> some View {
        Toggle(title, isOn: Binding(
            get: { preferences.nodeTypes.contains(type) },
            set: { enabled in
                if enabled { preferences.nodeTypes.insert(type) }
                else { preferences.nodeTypes.remove(type) }
            }
        ))
    }

    private var languageSummary: String {
        let names = preferences.languageCodes
            .map(Self.languageName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        switch names.count {
        case 0: return "None"
        case 1: return names[0]
        case 2: return names.joined(separator: ", ")
        default: return "\(names.count) selected"
        }
    }

    private var countrySelection: Binding<String> {
        Binding(
            get: { preferences.countryCodes.first ?? "" },
            set: { preferences.countryCodes = $0.isEmpty ? [] : [$0] }
        )
    }

    private static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

private struct CallCQLanguageSelectionView: View {
    let languages: [String]
    @Binding var selectedCodes: Set<String>
    @State private var searchText = ""

    private var filteredLanguages: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return languages }
        return languages.filter { code in
            code.localizedCaseInsensitiveContains(query)
                || languageName(code).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List(filteredLanguages, id: \.self) { code in
            Button {
                if selectedCodes.contains(code) { selectedCodes.remove(code) }
                else { selectedCodes.insert(code) }
            } label: {
                HStack {
                    Text(languageName(code))
                    Spacer()
                    if selectedCodes.contains(code) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
            }
            .foregroundStyle(.primary)
            .accessibilityValue(selectedCodes.contains(code) ? "Selected" : "Not selected")
        }
        .navigationTitle("Languages")
        .searchable(text: $searchText, prompt: "Search languages")
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}
