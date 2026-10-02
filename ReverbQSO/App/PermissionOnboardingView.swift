// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
#if targetEnvironment(macCatalyst)
import UserNotifications
#endif

struct PermissionOnboardingView: View {
    let onContinue: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsPinnedContinue = true

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if usesTwoColumns(for: geometry.size.width) {
                        HStack(alignment: .center, spacing: 72) {
                            header(expanded: true)
                                .frame(maxWidth: 600, alignment: .leading)

                            VStack(alignment: .leading, spacing: 22) {
                                permissionChoices
                                continueAction
                            }
                            .frame(maxWidth: 620, alignment: .leading)
                        }
                        .frame(maxWidth: 1400)
                    } else {
                        VStack(alignment: .leading, spacing: 22) {
                            header(expanded: false)
                            permissionChoices

                            if usesInlineContinue(for: geometry.size.width) {
                                continueAction
                            }
                        }
                        .frame(maxWidth: geometry.size.width >= 600 ? 700 : 480, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, usesTwoColumns(for: geometry.size.width) ? 36 : 24)
                .padding(.vertical, 24)
                .frame(minHeight: geometry.size.height, alignment: usesInlineContinue(for: geometry.size.width) ? .center : .top)
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                showsPinnedContinue = !usesInlineContinue(for: width)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if showsPinnedContinue {
                continueAction
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                    .background(.regularMaterial)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var permissionChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicrophonePermissionControl()

            #if targetEnvironment(macCatalyst)
            MacMessagePermissionControl()
            #endif
        }
    }

    private func usesTwoColumns(for width: CGFloat) -> Bool {
        guard !dynamicTypeSize.isAccessibilitySize else { return false }
        #if targetEnvironment(macCatalyst)
        return width >= 1100
        #else
        return width >= 900
        #endif
    }

    private func usesInlineContinue(for width: CGFloat) -> Bool {
        #if targetEnvironment(macCatalyst)
        usesTwoColumns(for: width)
        #else
        width >= 600
        #endif
    }

    private var continueAction: some View {
        Button(action: onContinue) {
            HStack {
                Spacer()
                Text("Continue")
                Image(systemName: "arrow.right")
                Spacer()
            }
            .font(.headline)
            .frame(minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func header(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: expanded ? 92 : 66, height: expanded ? 92 : 66)
                Image(systemName: "waveform.path")
                    .font(.system(size: expanded ? 40 : 28, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("ReverbQSO")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(.tint)

                Text("Get on the air")
                    .font(.system(expanded ? .largeTitle : .title, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

            }
        }
    }
}

struct MicrophonePermissionControl: View {
    var isEmbeddedInSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: MicrophoneAuthorizationState = .notDetermined
    @State private var isRequesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(.tint)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                Text("Microphone")
                    .font(.headline)
                Spacer(minLength: 8)
                PermissionStatusBadge(title: status.title, isAllowed: status == .granted)
            }

            Text("Used only while you hold push to talk.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if status == .notDetermined {
                Button("Enable Microphone") {
                    isRequesting = true
                    Task {
                        _ = await MicrophoneAccess.request()
                        status = MicrophoneAccess.status
                        isRequesting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isRequesting)
            } else if status == .denied {
                Text("Transmitting requires microphone access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") { openAppSettings() }
            }
        }
        .padding(isEmbeddedInSettings ? 0 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !isEmbeddedInSettings {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
        .task { status = MicrophoneAccess.status }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { status = MicrophoneAccess.status }
        }
    }
}

private struct PermissionStatusBadge: View {
    let title: String
    let isAllowed: Bool

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isAllowed ? Color.green : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isAllowed ? Color.green.opacity(0.12) : Color.secondary.opacity(0.12), in: Capsule())
            .accessibilityAddTraits(.isStaticText)
    }
}

private extension MicrophoneAuthorizationState {
    var title: String {
        switch self {
        case .notDetermined: "Not asked"
        case .granted: "Allowed"
        case .denied: "Off"
        }
    }
}

@MainActor
private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}

#if targetEnvironment(macCatalyst)
struct MacMessagePermissionControl: View {
    var isEmbeddedInSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var isRequesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(.tint)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                Text(isEmbeddedInSettings ? "Notification permission" : "Message alerts")
                    .font(.headline)
                Spacer(minLength: 8)
                PermissionStatusBadge(
                    title: status == .authorized || status == .provisional ? "Allowed" : status == .denied ? "Off" : "Not asked",
                    isAllowed: status == .authorized || status == .provisional
                )
            }

            if !isEmbeddedInSettings {
                Text("Alerts and sounds for new messages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status == .notDetermined {
                Button("Allow Message Alerts") {
                    isRequesting = true
                    Task {
                        let granted = (try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound])) == true
                        if granted { UserDefaults.standard.set(true, forKey: MacMessageNotifier.enabledKey) }
                        await refresh()
                        MacMessageNotifier.refreshAuthorizationStatus()
                        isRequesting = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRequesting)
            } else if status == .denied {
                Text("Turn on notifications in System Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(isEmbeddedInSettings ? 0 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !isEmbeddedInSettings {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
#endif
