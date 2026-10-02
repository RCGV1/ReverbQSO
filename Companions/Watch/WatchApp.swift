// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
@MainActor
struct ReverbQSOWatchApp: App {
    @StateObject private var model: WatchAppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = WatchAppModel()
        _model = StateObject(wrappedValue: model)
        WatchPTTIntentBridge.shared.model = model
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else { return }
                    model.endPTT()
                }
        }
    }
}
