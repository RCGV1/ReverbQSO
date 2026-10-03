// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct DirectoryFiltersMenu: View {
    @ObservedObject var viewModel: DirectoryViewModel
    let onChooseCountry: () -> Void

    var body: some View {
        Menu {
            if viewModel.browseGroup == .nodes {
                Section("Node type") {
                    Picker("Node type", selection: $viewModel.typeFilter) {
                        Text("All nodes").tag(Station.StationType?.none)
                        Text("Links").tag(Station.StationType?.some(.link))
                        Text("Repeaters").tag(Station.StationType?.some(.repeater))
                        Text("Conferences").tag(Station.StationType?.some(.conference))
                    }
                    .pickerStyle(.inline)
                }
            }

            Section {
                Button(action: onChooseCountry) {
                    Label(viewModel.countryFilter.isEmpty ? "Country…" : "Country: \(viewModel.countryFilterTitle)",
                          systemImage: "globe")
                }

                Picker("Sort by", selection: $viewModel.sortOrder) {
                    ForEach(DirectoryViewModel.SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }

            if viewModel.hasActiveFilters {
                Section {
                    Button("Clear Filters", systemImage: "xmark") {
                        viewModel.clearFilters()
                    }
                }
            }
        } label: {
            Label("Filters", systemImage: viewModel.hasActiveFilters
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityValue(viewModel.filterSummary)
        .accessibilityIdentifier("directory-filters")
    }
}
