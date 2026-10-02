// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine

/// View model for the active QSO session view.
@MainActor
final class QSOViewModel: ObservableObject {

    // MARK: - Published State

    @Published var isRecording = false
    @Published var session: QSOSession?
    @Published var isConnected = false
    @Published var isPTTActive = false
    @Published var isMuted = false
    @Published var sysopInfo = ""
    @Published var stationCallsign = ""
    @Published var elapsedTime: TimeInterval = 0
    @Published var inputLevel: Double = 0.0
    @Published var outputLevel: Double = 0.0
    @Published var audioOutputRouteName = "System Audio"
    @Published var audioOutputPreference: AudioOutputPreference = .speaker
    @Published var isRemoteTransmitting = false
    @Published var remotePadAllowed = false
    @Published var isSendingDTMF = false
    @Published var canTransmit = false
    @Published var activeNodeParticipants: [ActiveNodeParticipant] = []
    @Published var errorTitle = "Connection Error"
    @Published var errorMessage: String?
    @Published var reconnectCandidate: Station?
    @Published var isReconnecting = false
    @Published var audioStatusMessage: String?
    @Published var chatMessages: [ChatMessage] = []
    @Published var hasIncomingMessages = false

    // MARK: - Dependencies

    private let connectionService: EchoLinkConnectionService
    private var cancellables = Set<AnyCancellable>()
    private var timerTask: Task<Void, Never>?

    var localCallsign: String {
        connectionService.localCallsign
    }

    init(connectionService: EchoLinkConnectionService) {
        self.connectionService = connectionService
        bindToService()
    }

    // MARK: - Actions

    func togglePTT(active: Bool) {
        connectionService.sendPTT(active: active)
    }

    func toggleRecording() { connectionService.toggleRecording() }

    func toggleMute() {
        connectionService.toggleMute()
    }

    func setAudioOutputPreference(_ preference: AudioOutputPreference) {
        connectionService.setAudioOutputPreference(preference)
    }

    func sendRemoteDTMF(_ digits: String) {
        connectionService.sendRemoteDTMF(digits)
    }

    var canSendRemoteDTMF: Bool {
        connectionService.canSendRemoteDTMF
    }

    func disconnect() async {
        await connectionService.disconnect()
        timerTask?.cancel()
    }

    func reconnect() async {
        await connectionService.reconnect()
    }

    var canReconnect: Bool {
        reconnectCandidate != nil
            && (session == nil || session?.state == .disconnected)
            && !isReconnecting
    }

    func dismissError() {
        connectionService.clearError()
    }

    func sendChat(message: String) async {
        await connectionService.sendChat(message: message)
    }

    // MARK: - Binding

    private func bindToService() {
        connectionService.$isRecording.receive(on: DispatchQueue.main).assign(to: &$isRecording)

        connectionService.$session
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                guard let self else { return }
                self.session = session
                self.isConnected = session?.state == .connected
                self.canTransmit = self.connectionService.canTransmit
                self.isPTTActive = session?.isPTTActive ?? false
                self.isMuted = session?.isMuted ?? false
                self.sysopInfo = session?.sysopInfo ?? ""
                self.stationCallsign = session?.station.callsign ?? ""

                if session?.state == .connected {
                    self.startTimer(from: session?.startTime ?? Date())
                } else {
                    self.timerTask?.cancel()
                    if session?.state == .disconnected { self.elapsedTime = 0 }
                }
            }
            .store(in: &cancellables)

        connectionService.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                self.errorMessage = error?.localizedDescription
                if let connectionError = error as? ConnectionError,
                   case .remoteBye = connectionError {
                    self.errorTitle = "Connection Ended"
                } else {
                    self.errorTitle = "Connection Error"
                }
            }
            .store(in: &cancellables)

        connectionService.$reconnectCandidate
            .receive(on: DispatchQueue.main)
            .assign(to: &$reconnectCandidate)

        connectionService.$isReconnecting
            .receive(on: DispatchQueue.main)
            .assign(to: &$isReconnecting)

        connectionService.$inputLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$inputLevel)

        connectionService.$outputLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$outputLevel)

        connectionService.$audioOutputRouteName
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioOutputRouteName)

        connectionService.$audioOutputPreference
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioOutputPreference)

        connectionService.$isRemoteTransmitting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRemoteTransmitting in
                guard let self else { return }
                self.isRemoteTransmitting = isRemoteTransmitting
                self.canTransmit = self.connectionService.canTransmit
            }
            .store(in: &cancellables)

        connectionService.$remotePadAllowed
            .receive(on: DispatchQueue.main)
            .assign(to: &$remotePadAllowed)

        connectionService.$isSendingDTMF
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sending in
                guard let self else { return }
                self.isSendingDTMF = sending
                self.canTransmit = self.connectionService.canTransmit
            }
            .store(in: &cancellables)

        connectionService.$incomingChatMessages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                guard let self else { return }
                self.chatMessages = messages
                if messages.isEmpty {
                    self.hasIncomingMessages = false
                } else if !self.hasIncomingMessages {
                    self.hasIncomingMessages = messages.contains { !$0.isOutgoing }
                }
            }
            .store(in: &cancellables)

        connectionService.$audioStatusMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioStatusMessage)

        connectionService.$isCaptureReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard let self else { return }
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
                self.canTransmit = self.isConnected && !self.isRemoteTransmitting && !self.isSendingDTMF && ready
#else
                self.canTransmit = self.connectionService.canTransmit
#endif
            }
            .store(in: &cancellables)

        connectionService.$activeNodeParticipants
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeNodeParticipants)
    }

    private func startTimer(from startTime: Date) {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                elapsedTime = Date().timeIntervalSince(startTime)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    var formattedElapsedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

}
