// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct DirectoryFiltersView: View {
    @ObservedObject var viewModel: DirectoryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Show") {
                    if viewModel.browseGroup == .nodes {
                        Picker("Node type", selection: $viewModel.typeFilter) {
                            Text("All nodes").tag(Station.StationType?.none)
                            Text("Links").tag(Station.StationType?.some(.link))
                            Text("Repeaters").tag(Station.StationType?.some(.repeater))
                            Text("Conferences").tag(Station.StationType?.some(.conference))
                        }
                        .pickerStyle(.menu)
                    }

                    NavigationLink {
                        CountryFilterView(
                            countries: viewModel.availableCountries,
                            selectedCode: $viewModel.countryFilter
                        )
                    } label: {
                        LabeledContent("Country", value: viewModel.countryFilterTitle)
                    }
                }

                Section("Sort by") {
                    Picker("Sort by", selection: $viewModel.sortOrder) {
                        ForEach(DirectoryViewModel.SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if viewModel.hasActiveFilters {
                    Section {
                        Button("Clear Filters") { viewModel.clearFilters() }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 440, idealHeight: 520)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}
