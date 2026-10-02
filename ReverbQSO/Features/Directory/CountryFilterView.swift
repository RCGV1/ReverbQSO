// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Native searchable country picker for EchoLink's callsign-prefix locations.
struct CountryFilterView: View {
    let countries: [DirectoryViewModel.CountryOption]
    @Binding var selectedCode: String

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredCountries: [DirectoryViewModel.CountryOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return countries }
        return countries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.code.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selectedCode = ""
                    dismiss()
                } label: {
                    selectionRow(title: "All countries", code: "")
                }
                .foregroundStyle(.primary)

                Section("Countries") {
                    ForEach(filteredCountries) { country in
                        Button {
                            selectedCode = country.code
                            dismiss()
                        } label: {
                            selectionRow(title: country.name, code: country.code)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Country")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Country name or code")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func selectionRow(title: String, code: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selectedCode == code {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
