// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A large circular Push-To-Talk button that activates on press-and-hold.
///
/// Triggers haptic feedback on press and release. Calls `onStateChange` with
/// `true` when pressed and `false` when released.
struct PTTButton: View {

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Binding var isActive: Bool
    var isEnabled = true
    var size: CGFloat = 120
    var onStateChange: ((Bool) -> Void)?

    @State private var isPressed = false
    @State private var suppressGestureUntilRelease = false
    @State private var accessibilityTransmitting = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var pressStartUptime: TimeInterval?

    private var isTransmitting: Bool { isPressed || isActive }

    var body: some View {
        ZStack {
            // Pulse ring (only while active)
            if isTransmitting {
                Circle()
                    .stroke(Color.green.opacity(0.35), lineWidth: 2)
                    .frame(width: size + 24, height: size + 24)
                    .scaleEffect(pulseScale)
                    .opacity(2 - pulseScale)  // fades as it expands
            }

            // Main button
            Circle()
                .fill(
                    isTransmitting
                        ? LinearGradient(colors: [.green, Color.green.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: size, height: size)
                .shadow(color: isTransmitting ? .green.opacity(0.4) : .black.opacity(0.15), radius: isTransmitting ? 14 : 6, y: 4)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: isTransmitting ? "mic.fill" : "mic")
                            .font(.system(size: 36, weight: .semibold))
                        Text("PTT")
                            .font(.callout.bold())
                    }
                    .foregroundStyle(isTransmitting ? .white : .primary)
                }
                .scaleEffect(isTransmitting ? 0.95 : 1.0)
                .opacity(isEnabled ? 1 : 0.55)
        }
        // Reserve the animated ring's full extent so it cannot cover RX/TX meters.
        .frame(width: size + 48, height: size + 48)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isTransmitting)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled, !isPressed, !suppressGestureUntilRelease else { return }
                    isPressed = true
                    pressStartUptime = ProcessInfo.processInfo.systemUptime
                    isActive = true
                    onStateChange?(true)
                    VoiceDiagnosticLog.record("PTT UI gesture began")
                    triggerHaptic(.medium)
                    startPulse()
                }
                .onEnded { _ in
                    suppressGestureUntilRelease = false
                    if isPressed { releasePress(cause: "gesture ended") }
                }
        )
        // Expose the compound visual control as one VoiceOver element. Without
        // this, the mic symbol and PTT label can be discovered as duplicate
        // Push to Talk controls on iPad and Mac accessibility trees.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Push to Talk")
        .accessibilityHint(
            !isEnabled ? "Unavailable until the channel and microphone are ready."
                : isPressed ? "Transmitting. Release to stop."
                : isActive ? "Transmitting. Press and release to stop."
                : voiceOverEnabled ? "Double-tap to start transmitting, then double-tap again to stop."
                : "Press and hold to transmit."
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard isEnabled || accessibilityTransmitting else { return }
            if accessibilityTransmitting {
                accessibilityTransmitting = false
                isActive = false
                onStateChange?(false)
                pulseScale = 1.0
            } else {
                accessibilityTransmitting = true
                isActive = true
                onStateChange?(true)
                startPulse()
            }
        }
        .onAppear {
            if isActive { startPulse() }
        }
        .onChange(of: isActive) { _, active in
            if active && !isPressed {
                startPulse()
            } else if !active && isPressed {
                suppressGestureUntilRelease = true
                releasePress(cause: "binding became inactive")
            } else if !isPressed {
                accessibilityTransmitting = active && accessibilityTransmitting
                pulseScale = 1.0
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            guard !enabled else { return }
            if isPressed {
                suppressGestureUntilRelease = true
                releasePress(cause: "control disabled")
            } else if accessibilityTransmitting {
                accessibilityTransmitting = false
                isActive = false
                onStateChange?(false)
                pulseScale = 1.0
            }
        }
        .onDisappear {
            if isPressed { releasePress(cause: "control disappeared") }
            guard accessibilityTransmitting else { return }
            accessibilityTransmitting = false
            isActive = false
            onStateChange?(false)
            pulseScale = 1.0
        }
    }

    private func releasePress(cause: String) {
        recordRelease(cause: cause)
        isPressed = false
        isActive = false
        onStateChange?(false)
        triggerHaptic(.light)
        pulseScale = 1.0
    }

    private func recordRelease(cause: String) {
        let duration = pressStartUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        VoiceDiagnosticLog.record("PTT UI release cause=\(cause) heldSeconds=\(String(format: "%.2f", duration))")
        pressStartUptime = nil
    }

    private func startPulse() {
        guard isTransmitting else { return }
        withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
            pulseScale = 1.15
        }
    }

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
#if targetEnvironment(simulator)
        // Avoid known CoreHaptics missing resource warnings on Simulator.
        return
#else
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
#endif
    }
}
