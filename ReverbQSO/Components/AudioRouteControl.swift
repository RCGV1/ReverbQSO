// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) && !targetEnvironment(macCatalyst)
import MediaPlayer
import SwiftUI

/// Apple's route button includes Bluetooth hands-free devices used by voice chat.
struct SystemAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let picker = MPVolumeView()
        picker.showsVolumeSlider = false
        picker.showsRouteButton = true
        picker.tintColor = .label
        return picker
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
#endif
