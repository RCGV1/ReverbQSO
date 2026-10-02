// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct CallRestrictionsView: View {
    @StateObject private var store: CallAccessPolicyStore
    private let countryOptions: [CountryOption]
    @State private var countrySearch = ""
    @State private var blockedText: String
    @State private var allowedText: String
    init(demo: Bool = false) {
        let initial = CallAccessPolicyStore(demo: demo)
        _store = StateObject(wrappedValue: initial)
        _blockedText = State(initialValue: initial.policy.blockedCallsigns.sorted().joined(separator: ", "))
        _allowedText = State(initialValue: initial.policy.allowedCallsigns.sorted().joined(separator: ", "))
        countryOptions = Locale.Region.isoRegions.map { code in
            let identifier = code.identifier
            return CountryOption(
                code: identifier,
                name: Locale.current.localizedString(forRegionCode: identifier) ?? identifier
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        Form {
            Section("Apply To") {
                Toggle("Incoming calls", isOn: $store.policy.applyToIncoming)
                Toggle("Outgoing calls", isOn: $store.policy.applyToOutgoing)
            }
            Section("Station Types") {
                ForEach(Station.StationType.allCases, id: \.self) { type in
                    Toggle(type.displayName, isOn: Binding(
                        get: { store.policy.allowedTypes.contains(type) },
                        set: { enabled in
                            if enabled { store.policy.allowedTypes.insert(type) }
                            else { store.policy.allowedTypes.remove(type) }
                        }
                    ))
                }
            }
            Section {
                TextField("Blocked callsigns", text: callsignBinding(allowed: false), axis: .vertical)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Toggle("Only allow listed callsigns", isOn: $store.policy.useAllowList)
                if store.policy.useAllowList {
                    TextField("Allowed callsigns", text: callsignBinding(allowed: true), axis: .vertical)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if store.policy.allowedCallsigns.isEmpty {
                        Label("Add a callsign to allow connections.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
            } header: { Text("Callsigns") } footer: {
                Text("Separate callsigns with commas. Include -L or -R for a link or repeater.")
            }
            Section {
                NavigationLink {
                    countryList
                } label: {
                    LabeledContent("Blocked countries", value: "\(store.policy.blockedCountries.count)")
                }
            } footer: {
                Text("Country restrictions use the callsign prefix, not the station’s physical location.")
            }
        }
        .navigationTitle("Call Restrictions")
        .navigationBarTitleDisplayMode(.inline)
    }
    private var countries: [CountryOption] {
        guard !countrySearch.isEmpty else { return countryOptions }
        return countryOptions.filter {
            $0.name.localizedCaseInsensitiveContains(countrySearch)
                || $0.code.localizedCaseInsensitiveContains(countrySearch)
        }
    }
    private var countryList: some View {
        List(countries) { country in
            Toggle(country.name, isOn: Binding(
                get: { store.policy.blockedCountries.contains(country.code) },
                set: { blocked in
                    if blocked { store.policy.blockedCountries.insert(country.code) }
                    else { store.policy.blockedCountries.remove(country.code) }
                }
            ))
        }
        .searchable(text: $countrySearch, prompt: "Countries")
        .navigationTitle("Blocked Countries")
    }
    private func callsignBinding(allowed: Bool) -> Binding<String> {
        Binding(
            get: { allowed ? allowedText : blockedText },
            set: { value in
                if allowed { allowedText = value } else { blockedText = value }
                let values = Set(value.split(whereSeparator: { $0 == "," || $0 == "\n" })
                    .map { CallAccessPolicy.normalize(String($0)) }.filter { !$0.isEmpty })
                if allowed { store.policy.allowedCallsigns = values }
                else { store.policy.blockedCallsigns = values }
            }
        )
    }
}

private struct CountryOption: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}
