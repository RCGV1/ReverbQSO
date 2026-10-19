// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
#if DEBUG
import AVFoundation
#endif

@main
@MainActor
struct ReverbQSOWatchApp: App {
    @StateObject private var model: WatchAppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model: WatchAppModel
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--watch-standalone-ptt-reconnect-probe") {
            model = WatchAppModel(
                connectionService: EchoLinkConnectionService(localDemoPlayback: { _ in })
            )
        } else {
            model = WatchAppModel()
        }
        #else
        model = WatchAppModel()
        #endif
        _model = StateObject(wrappedValue: model)
        WatchPTTIntentBridge.shared.model = model
        #if DEBUG
        Task { @MainActor in
            if ProcessInfo.processInfo.arguments.contains("--watch-stale-command-reply-probe") {
                model.runStalePhoneCommandReplyProbe()
            }
            if ProcessInfo.processInfo.arguments.contains("--watch-standalone-ptt-reconnect-probe") {
                await model.runStandalonePTTReconnectProbe()
            }
            if ProcessInfo.processInfo.arguments.contains("--watch-companion-model-probe") {
                await model.runModelAudioReceiveProbe()
            }
            if ProcessInfo.processInfo.arguments.contains("--watch-companion-audio-probe") {
                await WatchCompanionAudioProbe.run()
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .onAppear { model.setForeground(scenePhase == .active) }
                .onChange(of: scenePhase) { _, phase in
                    model.setForeground(phase == .active)
                }
        }
    }
}

#if DEBUG
/// Offline regression for the Watch-only player; never connects to EchoLink.
@MainActor
private enum WatchCompanionAudioProbe {
    static func run() async {
        let player = WatchReceiveAudioPlayer()
        NSLog("WATCH_AUDIO_PROBE started")
        guard player.debugRenderedPlaybackSampleTime == nil else {
            NSLog("WATCH_AUDIO_PROBE unexpected timeline before attachment")
            return
        }
        for cycle in 0..<3 {
            let completedBefore = player.completedPlaybackBufferCount
            for sequence in 0..<100 {
                if cycle == 1, sequence == 50 {
                    NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
                        object: AVAudioSession.sharedInstance(), userInfo: [
                            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                        ])
                }
                if cycle == 2, sequence == 50 {
                    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification,
                        object: AVAudioSession.sharedInstance())
                }
                var packet = Data([0x80, 100, 0, UInt8(sequence), 0, 0, 0, 0, 0, 0, 0, 1])
                packet.append(Data(repeating: 0xD5, count: 160))
                guard player.play(packet) else {
                    NSLog("WATCH_AUDIO_PROBE playback rejected cycle=\(cycle)")
                    player.stop()
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard player.completedPlaybackBufferCount > completedBefore else {
                NSLog("WATCH_AUDIO_PROBE no completed native playback cycle=\(cycle)")
                player.stop()
                return
            }
            player.stop()
        }
        NSLog("WATCH_AUDIO_PROBE passed completed=\(player.completedPlaybackBufferCount)")
    }
}
#endif
