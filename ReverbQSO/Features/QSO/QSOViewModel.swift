// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine

/// View model for the active QSO session view.
@MainActor
final class QSOViewModel: ObservableObject {

    // MARK: - Published State

    @Published var isRecording = false
    @Published var isAutomaticallyRecording = false
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
    @Published var audioInputDevices: [AudioInputDevice] = []
    @Published var selectedAudioInputDeviceID: String?
    @Published var watchAudioOutputAvailable = false
    @Published var usesWatchAudioOutput = false
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
    private var chatNotificationCursor = ChatMessageNotificationCursor()

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

    func setAudioInputDevice(id: String?) { connectionService.setAudioInputDevice(id: id) }
    func setWatchAudioOutput(_ selected: Bool) { connectionService.setWatchAudioOutput(selected) }

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

    func cancelConnection() {
        if connectionService.isReconnecting {
            // Reconnect clears the presentation session while it refreshes the
            // directory. Disconnect advances the service's reconnect generation
            // so an in-flight lookup cannot install a new session afterward.
            Task { await connectionService.disconnect() }
        } else {
            connectionService.cancelPendingConnection()
        }
        timerTask?.cancel()
    }

    func reconnect() async {
        await connectionService.reconnect()
    }

    var canReconnect: Bool {
        reconnectCandidate != nil && reconnectCandidate?.isRelayOnly != true
            && (session == nil || session?.state == .disconnected)
            && !isReconnecting
    }

    var canCancelConnection: Bool {
        session?.state == .connecting || connectionService.isReconnecting
    }

    var shouldDismissAfterDisconnect: Bool {
        let state = connectionService.session?.state
        return (state == nil || state == .disconnected)
            && !connectionService.isReconnecting
            && connectionService.error == nil
    }

    func dismissError() {
        connectionService.clearError()
    }

    func sendChat(message: String) async {
        await connectionService.sendChat(message: message)
    }

    func markMessagesRead() {
        hasIncomingMessages = false
    }

    var hasStationActivity: Bool {
        !sysopInfo.isEmpty || !chatMessages.isEmpty
    }

    // MARK: - Binding

    private func bindToService() {
        connectionService.$isRecording.receive(on: DispatchQueue.main).assign(to: &$isRecording)
        connectionService.$isAutomaticallyRecording.receive(on: DispatchQueue.main).assign(to: &$isAutomaticallyRecording)

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
        connectionService.$audioInputDevices.assign(to: &$audioInputDevices)
        connectionService.$selectedAudioInputDeviceID.assign(to: &$selectedAudioInputDeviceID)
        connectionService.$watchAudioOutputAvailable.assign(to: &$watchAudioOutputAvailable)
        connectionService.$usesWatchAudioOutput.assign(to: &$usesWatchAudioOutput)

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
                let newIncomingMessages = self.chatNotificationCursor.newIncomingMessages(in: messages)
                if messages.isEmpty {
                    self.hasIncomingMessages = false
                } else if !newIncomingMessages.isEmpty {
                    self.hasIncomingMessages = true
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
