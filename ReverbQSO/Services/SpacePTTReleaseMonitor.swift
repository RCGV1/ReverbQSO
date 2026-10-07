// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(watchOS)
import Combine
import GameController
import UIKit
import SwiftUI
import os

/// Physical keyboard events do not depend on SwiftUI radio focus.
@MainActor
final class SpacePTTReleaseMonitor {
    static let shared = SpacePTTReleaseMonitor()
    let presses = PassthroughSubject<Void, Never>()
    private let logger = Logger(subsystem: "org.reverbqso.app", category: "SpacePTT")
    let releases = PassthroughSubject<Void, Never>()
    private var subscriptions = Set<AnyCancellable>()
    private var isSpaceHeld = false
    private var owner: UUID?
    private weak var boundInput: GCKeyboardInput?

    private init() {
        NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.bindKeyboard() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isSpaceHeld = false
                self?.boundInput = nil
                self?.releases.send(())
            }
            .store(in: &subscriptions)
        bindKeyboard()
    }

    func keyChanged(_ key: GCKeyCode, isPressed: Bool) {
        guard key == .spacebar else { return }
        logger.notice("Physical Space pressed=\(isPressed)")
        spaceChanged(isPressed: isPressed,
                     canStart: UIApplication.shared.applicationState == .active
                        && !Self.hasTextResponder() && !hasShortcutModifier)
    }

    /// Track physical edges so a repeated down cannot restart a cancelled hold.
    func spaceChanged(isPressed: Bool, canStart: Bool) {
        if isPressed {
            guard !isSpaceHeld else { return }
            isSpaceHeld = true
            guard canStart else {
                logger.notice("Physical Space ignored: inactive app, text input, or modifier")
                return
            }
            presses.send(())
        } else {
            isSpaceHeld = false
            releases.send(())
        }
    }

    func claim(_ candidate: UUID) -> Bool {
        guard owner == nil || owner == candidate else { return false }
        owner = candidate
        return true
    }

    func release(_ candidate: UUID) {
        if owner == candidate { owner = nil }
    }

    /// End a view-owned hold when that radio presents controls over the QSO.
    func cancelHold(for candidate: UUID) {
        guard owner == candidate else { return }
        owner = nil
        releases.send(())
    }

    func logEligibility(_ context: String, eligible: Bool, focused: Bool) {
        logger.notice("Space eligibility view=\(context, privacy: .public) eligible=\(eligible) radioFocus=\(focused)")
    }

    private var hasShortcutModifier: Bool {
        let keys: [GCKeyCode] = [.leftGUI, .rightGUI, .leftControl, .rightControl, .leftAlt, .rightAlt]
        return keys
            .contains { boundInput?.button(forKeyCode: $0)?.isPressed == true }
    }

    private static func hasTextResponder() -> Bool {
        func containsTextResponder(_ view: UIView) -> Bool {
            if view.isFirstResponder && view is UITextInput { return true }
            return view.subviews.contains(where: containsTextResponder)
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).filter(\.isKeyWindow)
            .contains(where: containsTextResponder)
    }

    private func bindKeyboard() {
        guard let input = GCKeyboard.coalesced?.keyboardInput else {
            logger.notice("No physical keyboard available")
            return
        }
        guard input !== boundInput else { return }
        logger.notice("Physical keyboard attached")
        boundInput = input
        // GCKeyboard reports physical transitions rather than typematic repeats.
        input.keyChangedHandler = { [weak self] _, _, key, pressed in
            guard key == .spacebar else { return }
            Task { @MainActor [weak self] in self?.keyChanged(key, isPressed: pressed) }
        }
    }
}
/// Route raw keyboard down only to the radio in the key window. This view
/// never becomes first responder and leaves UIKit text entry untouched.
struct SpacePTTKeyboardHandler: UIViewRepresentable {
    let onPress: () -> Void

    final class ObserverView: UIView {
        var onPress: (() -> Void)?
        var subscription: AnyCancellable?

        func deliverPress() {
            guard let window, window.isKeyWindow,
                  window.windowScene?.activationState == .foregroundActive else { return }
            var ancestor: UIView? = self
            while let view = ancestor {
                guard !view.isHidden, view.alpha > 0 else { return }
                ancestor = view.superview
            }
            onPress?()
        }
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.onPress = onPress
        view.subscription = SpacePTTReleaseMonitor.shared.presses.sink { [weak view] in
            view?.deliverPress()
        }
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onPress = onPress
    }

    static func dismantleUIView(_ view: ObserverView, coordinator: ()) {
        view.subscription = nil
        view.onPress = nil
    }
}
#endif
