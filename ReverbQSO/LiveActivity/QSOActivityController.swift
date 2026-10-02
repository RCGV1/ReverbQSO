// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) && !targetEnvironment(macCatalyst)
@preconcurrency import ActivityKit
import Combine
import Foundation

/// Runs one ActivityKit operation at a time, retaining the newest state while one awaits.
@MainActor
final class LatestActivityUpdateQueue<Value> {
    private var pending: Value?
    private var task: Task<Void, Never>?
    private let process: @MainActor (Value) async -> Void

    init(process: @escaping @MainActor (Value) async -> Void) {
        self.process = process
    }

    func submit(_ value: Value) {
        pending = value
        guard task == nil else { return }
        task = Task {
            while let value = pending {
                pending = nil
                await process(value)
            }
            task = nil
        }
    }

    func waitUntilIdle() async {
        await task?.value
    }
}

@MainActor
final class QSOActivityController {
    private struct Snapshot {
        let session: QSOSession?
        let isRemoteTransmitting: Bool
    }

    private var activity: Activity<QSOActivityAttributes>?
    private var hasReconciledExistingActivities = false
    private var cancellables = Set<AnyCancellable>()
    private var hubSubscription: AnyCancellable?
    private weak var connectionService: EchoLinkConnectionService?
    private lazy var updates = LatestActivityUpdateQueue<Snapshot> { [weak self] snapshot in
        await self?.sync(session: snapshot.session, isRemoteTransmitting: snapshot.isRemoteTransmitting)
    }

    func observe(_ hub: QSOHub) {
        observe(hub.activeService)
        hubSubscription = hub.objectWillChange.sink { [weak self, weak hub] _ in
            Task { @MainActor [weak self, weak hub] in
                guard let self, let hub else { return }
                self.observe(hub.activeService)
            }
        }
    }

    func observe(_ service: EchoLinkConnectionService) {
        guard connectionService !== service else { return }
        cancellables.removeAll()
        connectionService = service
        service.$session
            .combineLatest(service.$isRemoteTransmitting)
            .sink { [weak self, weak service] _, _ in
                Task { @MainActor [weak self, weak service] in
                    guard let self, let service, self.connectionService === service else { return }
                    self.updates.submit(Snapshot(
                        session: service.session,
                        isRemoteTransmitting: service.isRemoteTransmitting
                    ))
                }
            }
            .store(in: &cancellables)
    }

    private func sync(session: QSOSession?, isRemoteTransmitting: Bool) async {
        if !hasReconciledExistingActivities {
            hasReconciledExistingActivities = true
            // ActivityKit outlives the app process. A fresh connection service has
            // no matching QSO to restore, so retire activities left by a crash or
            // process eviction before publishing the current state.
            for existing in Activity<QSOActivityAttributes>.activities {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
        }

        guard let session, session.state == .connected else {
            if let activity {
                await activity.end(nil, dismissalPolicy: .immediate)
                self.activity = nil
            }
            return
        }

        let state = QSOActivityAttributes.ContentState(
            status: session.isPTTActive ? "Transmitting" : isRemoteTransmitting ? "Receiving" : "Connected",
            isTransmitting: session.isPTTActive
        )
        if activity?.attributes.callsign != session.station.callsign
            || activity?.attributes.startedAt != session.startTime {
            if let activity {
                await activity.end(nil, dismissalPolicy: .immediate)
                self.activity = nil
            }
        }
        if let activity {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(
                attributes: QSOActivityAttributes(
                    callsign: session.station.callsign,
                    startedAt: session.startTime
                ),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        }
    }
}
#endif
