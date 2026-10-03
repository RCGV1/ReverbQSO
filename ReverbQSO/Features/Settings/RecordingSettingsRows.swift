// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct RecordingSettingsRows: View {
    @AppStorage private var alwaysRecord: Bool

    init(demo: Bool = false) {
        _alwaysRecord = AppStorage(wrappedValue: false, RecordingPreferences.alwaysRecordKey(demo: demo))
    }

    var body: some View {
        Toggle("Always Record", isOn: $alwaysRecord)
        Text("Automatically saves each QSO. You can still record clips.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
