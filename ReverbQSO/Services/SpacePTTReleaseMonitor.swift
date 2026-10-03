// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(watchOS)
import Combine
import GameController

/// Keyboard releases are independent of SwiftUI's current focused responder.
@MainActor
final class SpacePTTReleaseMonitor {
    static let shared = SpacePTTReleaseMonitor()
    let releases = PassthroughSubject<Void, Never>()
    private var subscriptions = Set<AnyCancellable>()
    private weak var boundInput: GCKeyboardInput?

    private init() {
        NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.bindKeyboard() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.boundInput = nil
                self?.releases.send(())
            }
            .store(in: &subscriptions)
        bindKeyboard()
    }

    func keyChanged(_ key: GCKeyCode, isPressed: Bool) {
        guard key == .spacebar, !isPressed else { return }
        releases.send(())
    }

    private func bindKeyboard() {
        guard let input = GCKeyboard.coalesced?.keyboardInput, input !== boundInput else { return }
        boundInput = input
        // Observe releases only: SwiftUI still owns shortcut eligibility and
        // normal text input. Repeats cannot toggle PTT through this listener.
        input.keyChangedHandler = { [weak self] _, _, key, pressed in
            guard key == .spacebar, !pressed else { return }
            Task { @MainActor [weak self] in self?.keyChanged(key, isPressed: pressed) }
        }
    }
}
#endif
