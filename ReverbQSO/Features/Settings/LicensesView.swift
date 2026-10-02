// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LicensesView: View {
    private let licenses = [
        ("ReverbQSO · GPLv3", "GPL-3.0"),
        ("GSM codec", "libgsm-COPYRIGHT"),
        ("Speex codec", "libspeex-COPYING"),
        ("Original source notices", "Upstream-MIT")
    ]
    var body: some View {
        List(licenses, id: \.1) { title, file in
            NavigationLink(title) {
                ScrollView {
                    Text(licenseText(file))
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            }
        }.navigationTitle("Licenses")
    }
    private func licenseText(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text is unavailable in this build."
        }
        return text
    }
}
