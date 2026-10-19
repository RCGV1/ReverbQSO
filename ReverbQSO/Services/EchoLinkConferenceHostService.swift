// SPDX-License-Identifier: GPL-3.0-or-later

#if !os(watchOS)
import Combine
import Foundation
import os

/// Incoming GSM EchoLink transport for a personal station or a conference host.
/// It uses the logged-in callsign and opens sockets only when explicitly started.
@MainActor
final class EchoLinkConferenceHostService: ObservableObject {
    struct Ports: Sendable {
        let audio: UInt16
        let control: UInt16

        static let echolink = Ports(audio: 5198, control: 5199)
    }

    private struct LocalAudioRecipient {
        let id: UUID
        let host: String
        let port: UInt16
    }

    private struct QueuedLocalAudioPacket {
        let payload: Data
        let codec: EchoLinkVoiceCodec
        let sampleCount: Int
        let recipients: [LocalAudioRecipient]
    }

    private struct PeerVoiceClock {
        var sequence: UInt16 = 0
        var timestamp: UInt32 = 0
    }

    /// Manual clips and automatic QSO recordings share PCM, not their lifetime.
    @Published private(set) var isRecording = false
    @Published private(set) var isAutomaticallyRecording = false
    private var recordingCoordinator: QSORecordingCoordinator?
    private var publishedRecordingWarning: String?
    private let recordingDefaults: UserDefaults
    private let recordingFolder: URL?
    private var recordingPreferencesSubscription: AnyCancellable?

    func toggleRecording() {
        guard sessions.contains(where: { $0.state == .active }) else { return }
        prepareSessionRecording()
        recordingCoordinator?.toggleClip()
        publishRecordingState()
    }

    private func prepareSessionRecording() {
        guard recordingCoordinator == nil,
              sessions.contains(where: { $0.state == .active }) else { return }
        let coordinator = QSORecordingCoordinator(
            folder: recordingFolder, demo: isLocalDemo, defaults: recordingDefaults
        )
        recordingCoordinator = coordinator
        coordinator.startSession(callsign: isPersonalMode ? (sessions.first?.callsign ?? localCallsign) : localCallsign)
        let appendPCM: @MainActor ([Int16]) -> Void = { [weak self] samples in
            guard let self, self.isRecording || self.isAutomaticallyRecording else { return }
            self.recordingCoordinator?.append(samples)
            self.publishRecordingState()
        }
        audioEngine.onRecordingPCM = appendPCM
        onUnmonitoredReceivedPCM = appendPCM
        publishRecordingState()
    }

    private func publishRecordingState() {
        let clip = recordingCoordinator?.isRecordingClip ?? false
        let automatic = recordingCoordinator?.isAutomaticallyRecording ?? false
        if isRecording != clip { isRecording = clip }
        if isAutomaticallyRecording != automatic { isAutomaticallyRecording = automatic }
        let message = recordingCoordinator?.errorMessage
        if let message {
            errorMessage = message
        } else if let publishedRecordingWarning, errorMessage == publishedRecordingWarning {
            errorMessage = nil
        }
        publishedRecordingWarning = message
    }

    private func stopRecording() {
        recordingCoordinator?.stopSession()
        publishRecordingState()
        recordingCoordinator = nil
        audioEngine.onRecordingPCM = nil
        onUnmonitoredReceivedPCM = nil
        isRecording = false
        isAutomaticallyRecording = false
    }

    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var sessions: [InboundHostSession] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var talkerCallsign: String?
    @Published private(set) var isTransmitting = false
    @Published private(set) var inputLevel = 0.0
    @Published private(set) var outputLevel = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var maximumPeers = 0
    @Published private(set) var isPersonalMode = false
    @Published private(set) var pendingCall: InboundHostSession?
    @Published private(set) var isAnsweringPendingCall = false

    var callAccessPolicyProvider: (() -> CallAccessPolicy)?

    private let logger = Logger(subsystem: "org.reverbqso.app", category: "ConferenceHost")
    private let audioEngine: AudioEngine
    private let speexCodec = SpeexCodec()
    private var audioSocket: BoundUDPSocket?
    private var controlSocket: BoundUDPSocket?
    private var audioReceiveTask: Task<Void, Never>?
    private var controlReceiveTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var directory: EchoLinkDirectoryService?
    private var machine: InboundHostSessionMachine?
    private var floor = ConferenceFloorRouter()
    private var peerAudioCodecs: [UUID: ConferenceReceiveAudioCodec] = [:]
    /// Recording path when local speaker monitoring is disabled.
    var onUnmonitoredReceivedPCM: (@MainActor ([Int16]) -> Void)?
    private var localCallsign = ""
    private var ports = Ports.echolink
    private var peerVoiceClocks: [UUID: PeerVoiceClock] = [:]
    private var generation: UInt64 = 0
    private var isMonitoringAudio = false
    private let localTalkerID = UUID()
    private var captureStartTask: Task<Void, Never>?
    private var captureStopTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var queuedLocalAudio: [QueuedLocalAudioPacket] = []
    private var pendingLocalGSM = Data()
    private var speexCapablePeerIDs: Set<UUID> = []
    private var activeLocalTransmitCodecs: [UUID: EchoLinkVoiceCodec] = [:]
    private var transmissionGeneration: UInt64 = 0
    private let configurationProvider: @MainActor () -> EchoLinkProxyConfiguration
    private let prepareCaptureInput: @MainActor () async -> Bool
    private var isLocalDemo = false
    private var localDemoIncomingTask: Task<Void, Never>?
    private var localDemoStation: Station?

    init(
        configurationProvider: @escaping @MainActor () -> EchoLinkProxyConfiguration = { EchoLinkProxyConfiguration.load() },
        audioEngine injectedAudioEngine: AudioEngine? = nil,
        prepareCaptureInput: (@MainActor () async -> Bool)? = nil,
        recordingDefaults: UserDefaults = .standard,
        recordingFolder: URL? = nil
    ) {
        let audioEngine = injectedAudioEngine ?? AudioEngine()
        self.audioEngine = audioEngine
        self.configurationProvider = configurationProvider
        self.recordingDefaults = recordingDefaults
        self.recordingFolder = recordingFolder
        self.prepareCaptureInput = prepareCaptureInput ?? { [audioEngine] in
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            await audioEngine.prepareCaptureInput()
#else
            true
#endif
        }
        audioEngine.onCaptureStreamReset = { [weak self] in
            self?.pendingLocalGSM.removeAll(keepingCapacity: true)
            self?.speexCodec.resetEncoding()
        }
        audioEngine.onCaptureSuspended = { [weak self] in self?.setPTT(active: false) }
        recordingPreferencesSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recordingCoordinator?.refreshAutomaticRecording()
                self?.publishRecordingState()
            }
        audioEngine.$inputLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$inputLevel)
        audioEngine.$outputLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$outputLevel)
    }

    /// A fresh directory snapshot and free UDP ports are required before the
    /// station accepts calls. The outbound client cannot share these ports.
    func start(
        callsign: String,
        directory: EchoLinkDirectoryService,
        outbound: EchoLinkConnectionService,
        policy: InboundHostPolicy,
        ports: Ports = .echolink,
        monitorAudio: Bool = true
    ) async {
        await start(callsign: callsign, directory: directory, outbound: outbound,
                    policy: policy, ports: ports, monitorAudio: monitorAudio, personal: false)
    }

    func startPersonal(
        callsign: String,
        directory: EchoLinkDirectoryService,
        outbound: EchoLinkConnectionService,
        ports: Ports = .echolink,
        monitorAudio: Bool = true
    ) async {
        await start(callsign: callsign, directory: directory, outbound: outbound,
                    policy: InboundHostPolicy(maximumPeers: 1, allowsConferenceServers: false),
                    ports: ports, monitorAudio: monitorAudio, personal: true)
    }

    private func start(
        callsign: String,
        directory: EchoLinkDirectoryService,
        outbound: EchoLinkConnectionService,
        policy: InboundHostPolicy,
        ports: Ports,
        monitorAudio: Bool,
        personal: Bool
    ) async {
        guard !isRunning, !isStarting, !isStopping else { return }
        errorMessage = nil
        if outbound.isLocalDemoMode {
            guard outbound.session == nil else {
                errorMessage = "Leave the current QSO before receiving incoming calls."
                return
            }
            startLocalDemo(
                callsign: outbound.localCallsign,
                policy: policy,
                monitorAudio: monitorAudio,
                personal: personal
            )
            return
        }
        guard policy.isValid, (personal ? policy.maximumPeers == 1 : policy.maximumPeers >= 2) else {
            errorMessage = "Choose a conference limit from 2 to 99 stations."
            return
        }
        guard ports.audio != 0, ports.control != 0, ports.audio != ports.control else {
            errorMessage = "Choose distinct audio and control UDP ports."
            return
        }
        guard directory.isLoggedIn, !callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Sign in to EchoLink before hosting."
            return
        }
        if personal, !Self.isPersonalCallsign(callsign) {
            errorMessage = "Sign in with a personal callsign to receive individual calls."
            return
        }
        guard (directory.effectiveTransport?.configuration.mode ?? configurationProvider().mode) == .direct else {
            errorMessage = "Select Direct in Network Settings to receive incoming calls on UDP 5198 and 5199."
            return
        }
        guard !directory.registeredThroughProxy else {
            errorMessage = "Sign out and back in using Direct mode before hosting; this EchoLink registration still points to a proxy."
            return
        }
        guard outbound.session == nil else {
            errorMessage = "Leave the current QSO before receiving incoming calls."
            return
        }

        isStarting = true
        generation &+= 1
        let startingGeneration = generation
        guard await directory.refresh(), generation == startingGeneration,
              directory.isLoggedIn, directory.lastSuccessfulSnapshotAt != nil else {
            if generation == startingGeneration {
                errorMessage = directory.error?.localizedDescription ?? "The directory could not be refreshed."
                isStarting = false
            }
            return
        }

        do {
            let audio = try BoundUDPSocket(localPort: ports.audio)
            let control = try BoundUDPSocket(localPort: ports.control)
            guard generation == startingGeneration else {
                audio.close()
                control.close()
                return
            }
            self.audioSocket = audio
            self.controlSocket = control
            self.directory = directory
            self.machine = InboundHostSessionMachine(policy: policy, isEnabled: true)
            self.ports = ports
            self.localCallsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            self.maximumPeers = policy.maximumPeers
            self.isPersonalMode = personal
            self.pendingCall = nil
            self.isLocalDemo = false
            self.localDemoStation = nil
            self.peerVoiceClocks = [:]
            self.isMonitoringAudio = monitorAudio
            self.floor.reset()
            self.sessions = []
            self.messages = []
            self.talkerCallsign = nil
            self.isTransmitting = false
            self.queuedLocalAudio = []
            self.pendingLocalGSM = Data()
            self.speexCapablePeerIDs = []
            self.activeLocalTransmitCodecs = [:]
            self.isRunning = true
            self.isStarting = false
            audioEngine.resetCodecState()
            audioEngine.onCapturedAudio = { [weak self] data in
                self?.enqueueLocalGSM(data)
            }
            audioEngine.onCapturedPCM = { [weak self] samples in
                self?.enqueueLocalSpeex(samples)
            }
            if monitorAudio { audioEngine.startPlayback() }
            controlReceiveTask = Task { [weak self] in await self?.receiveControl() }
            audioReceiveTask = Task { [weak self] in await self?.receiveAudio() }
            maintenanceTask = Task { [weak self] in await self?.maintain() }
            if !(await directory.setAvailableForCalls(true)) {
                errorMessage = "Could not advertise availability in the EchoLink directory."
                await stop()
                return
            }
            logger.info("Incoming host started callsign=\(self.localCallsign, privacy: .public) maxPeers=\(policy.maximumPeers)")
        } catch {
            guard generation == startingGeneration else { return }
            errorMessage = "Could not open UDP \(ports.audio)/\(ports.control): \(error.localizedDescription)"
            isStarting = false
        }
    }

    func stop() async {
        stopRecording()
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        generation &+= 1
        transmissionGeneration &+= 1
        isStarting = false
        localDemoIncomingTask?.cancel()
        localDemoIncomingTask = nil
        guard isRunning else { return }
        isRunning = false
        if let directory, !(await directory.setAvailableForCalls(false)) {
            errorMessage = "Could not mark this station Busy; signing out of EchoLink."
            await directory.logout()
        }
        captureStartTask?.cancel()
        captureStopTask?.cancel()
        audioSendTask?.cancel()
        captureStartTask = nil
        captureStopTask = nil
        audioSendTask = nil
        queuedLocalAudio.removeAll()
        pendingLocalGSM.removeAll()
        activeLocalTransmitCodecs.removeAll()
        speexCapablePeerIDs.removeAll()
        peerVoiceClocks.removeAll()
        speexCodec.resetEncoding()
        isTransmitting = false
        let departing = machine?.setEnabled(false) ?? []
        let bye = EchoLinkControlPacketCodec.buildBYEPacket(reason: "Conference closed")
        if let controlSocket {
            for peer in departing {
                try? await controlSocket.send(bye, to: peer.sourceIPv4Address, port: peer.controlPort)
            }
        }
        controlReceiveTask?.cancel()
        audioReceiveTask?.cancel()
        maintenanceTask?.cancel()
        controlReceiveTask = nil
        audioReceiveTask = nil
        maintenanceTask = nil
        controlSocket?.close()
        audioSocket?.close()
        controlSocket = nil
        audioSocket = nil
        audioEngine.stopAll()
        audioEngine.onCapturedAudio = nil
        audioEngine.onCapturedPCM = nil
        isMonitoringAudio = false
        machine = nil
        directory = nil
        floor.reset()
        sessions = []
        peerAudioCodecs.removeAll()
        pendingCall = nil
        isAnsweringPendingCall = false
        isPersonalMode = false
        isLocalDemo = false
        localDemoStation = nil
        talkerCallsign = nil
        logger.info("Incoming host stopped")
    }

    /// Press-and-hold local PTT. Each active peer receives its negotiated codec.
    /// A remote speaker or an outgoing QSO prevents the Mac from taking the floor.
    func setPTT(active: Bool) {
        if active {
            guard isRunning, !isTransmitting, captureStopTask == nil,
                  (!isPersonalMode || !sessions.isEmpty),
                  talkerCallsign == nil else { return }
            transmissionGeneration &+= 1
            let txGeneration = transmissionGeneration
            isTransmitting = true
            pendingLocalGSM.removeAll(keepingCapacity: true)
            speexCodec.resetEncoding()
            activeLocalTransmitCodecs = Dictionary(uniqueKeysWithValues:
                (machine?.sessions ?? []).filter { $0.state == .active }.map { peer in
                    let codec: EchoLinkVoiceCodec = speexCodec.isEncoderAvailable
                        && speexCapablePeerIDs.contains(peer.id) ? .speex : .gsm
                    return (peer.id, codec)
                }
            )
            _ = floor.listeners(
                for: localTalkerID,
                activeIDs: [localTalkerID] + (machine?.sessions.filter { $0.state == .active }.map(\.id) ?? []),
                at: .now
            )
            publishTalker()
            captureStartTask = Task { [weak self] in
                guard let self, !Task.isCancelled,
                      self.transmissionGeneration == txGeneration,
                      self.isTransmitting else { return }
                let prepared = await self.prepareCaptureInput()
                guard !Task.isCancelled, self.isRunning,
                      self.transmissionGeneration == txGeneration, self.isTransmitting else { return }
                let started = prepared ? await self.audioEngine.startCapture() : false
                guard !Task.isCancelled, self.isRunning,
                      self.transmissionGeneration == txGeneration, self.isTransmitting else {
                    if started { self.audioEngine.stopCapture() }
                    return
                }
                self.captureStartTask = nil
                if !started {
                    self.isTransmitting = false
                    self.floor.remove(self.localTalkerID)
                    self.publishTalker()
                    self.errorMessage = "Microphone input is unavailable for PTT."
                }
            }
        } else {
            guard isTransmitting, captureStopTask == nil else { return }
            captureStartTask?.cancel()
            captureStartTask = nil
            let txGeneration = transmissionGeneration
            captureStopTask = Task { [weak self] in
                guard let self else { return }
                _ = await self.audioEngine.stopCaptureAndFlushPendingBuffers()
                guard self.transmissionGeneration == txGeneration else { return }
                self.flushLocalSpeex()
                if let sendTask = self.audioSendTask { await sendTask.value }
                guard self.transmissionGeneration == txGeneration else { return }
                self.pendingLocalGSM.removeAll(keepingCapacity: true)
                self.activeLocalTransmitCodecs.removeAll(keepingCapacity: true)
                self.floor.remove(self.localTalkerID)
                self.isTransmitting = false
                self.captureStopTask = nil
                self.publishTalker()
            }
        }
    }

    private func enqueueLocalGSM(_ encodedData: Data) {
        guard isRunning, isTransmitting,
              let gsm = GSMCodec.stripHeader(encodedData), !gsm.isEmpty else { return }
        pendingLocalGSM.append(gsm)
        for payload in EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &pendingLocalGSM) {
            let sampleCount = payload.count / GSMCodec.encodedFrameSize * GSMCodec.samplesPerFrame
            enqueueLocalPacket(payload, codec: .gsm, sampleCount: sampleCount)
        }
    }

    private func enqueueLocalSpeex(_ samples: [Int16]) {
        guard isRunning, isTransmitting, !samples.isEmpty,
              activeLocalTransmitCodecs.values.contains(.speex) else { return }
        guard let payloads = speexCodec.encode(samples) else {
            activeLocalTransmitCodecs = activeLocalTransmitCodecs.mapValues { _ in .gsm }
            return
        }
        for payload in payloads {
            enqueueLocalSpeexPayload(payload)
        }
    }

    private func flushLocalSpeex() {
        guard activeLocalTransmitCodecs.values.contains(.speex),
              let payload = speexCodec.flushEncoding() else { return }
        enqueueLocalSpeexPayload(payload)
    }

    private func enqueueLocalSpeexPayload(_ payload: Data) {
        enqueueLocalPacket(payload, codec: .speex, sampleCount: SpeexCodec.samplesPerPacket)
    }

    private func enqueueLocalPacket(_ payload: Data, codec: EchoLinkVoiceCodec, sampleCount: Int) {
        let recipients = (machine?.sessions ?? []).compactMap { peer -> LocalAudioRecipient? in
            guard peer.state == .active,
                  (activeLocalTransmitCodecs[peer.id] ?? .gsm) == codec else { return nil }
            return LocalAudioRecipient(id: peer.id, host: peer.sourceIPv4Address, port: peer.audioPort)
        }
        guard !recipients.isEmpty else { return }
        if queuedLocalAudio.count >= 128 {
            queuedLocalAudio.removeFirst(queuedLocalAudio.count - 127)
        }
        queuedLocalAudio.append(QueuedLocalAudioPacket(
            payload: payload, codec: codec, sampleCount: sampleCount, recipients: recipients
        ))
        if audioSendTask == nil {
            audioSendTask = Task { [weak self] in await self?.drainLocalAudio() }
        }
    }

    private func drainLocalAudio() async {
        while !Task.isCancelled, isRunning, !queuedLocalAudio.isEmpty {
            let queued = queuedLocalAudio.removeFirst()
            for recipient in queued.recipients
                where machine?.sessions.contains(where: { $0.id == recipient.id && $0.state == .active }) == true {
                let packet = buildVoicePacket(
                    payload: queued.payload,
                    codec: queued.codec,
                    sampleCount: queued.sampleCount,
                    peerID: recipient.id
                )
                try? await audioSocket?.send(packet, to: recipient.host, port: recipient.port)
            }
        }
        audioSendTask = nil
        if isRunning, !queuedLocalAudio.isEmpty {
            audioSendTask = Task { [weak self] in await self?.drainLocalAudio() }
        }
    }

    func disconnect(id: UUID) async {
        guard let peer = machine?.sessions.first(where: { $0.id == id }) else { return }
        let bye = EchoLinkControlPacketCodec.buildBYEPacket(reason: "Disconnected by host")
        if let controlSocket {
            try? await controlSocket.send(bye, to: peer.sourceIPv4Address, port: peer.controlPort)
        }
        machine?.remove(id: id)
        removePeerTransmitState(id: id)
        floor.remove(id)
        publishSessions()
        await syncHostAvailability()
        await broadcastInfo("\(peer.callsign) left")
    }

    func acceptPendingCall() async {
        guard isPersonalMode, let pendingCall,
              !isAnsweringPendingCall,
              machine?.sessions.contains(where: { $0.id == pendingCall.id && $0.state == .pending }) == true else { return }
        let station = Station(callsign: pendingCall.callsign, ipAddress: pendingCall.sourceIPv4Address,
                              type: pendingCall.stationType)
        if let reason = (callAccessPolicyProvider?() ?? CallAccessPolicyStore.load(demo: isLocalDemo)).rejection(
            for: station, direction: .incoming, countryCode: station.callSignCountryCode
        ) {
            errorMessage = reason
            await declinePendingCall(reason: reason)
            return
        }
        isAnsweringPendingCall = true
        defer { isAnsweringPendingCall = false }
        let acknowledgement = EchoLinkControlPacketCodec.buildSDESPacket(
            callsign: localCallsign, audioPort: ports.audio,
            advertiseSpeex: speexCodec.isEncoderAvailable
        )
        do {
            if !isLocalDemo {
                guard let controlSocket else { return }
                try await controlSocket.send(acknowledgement, to: pendingCall.sourceIPv4Address,
                                             port: pendingCall.controlPort)
            }
            guard machine?.activate(id: pendingCall.id, now: .now) == true else { return }
            self.pendingCall = nil
            publishSessions()
            if isLocalDemo, let localDemoStation {
                LocalDemoAccount.messages(for: localDemoStation, account: localCallsign)
                    .forEach(appendMessage)
            }
        } catch {
            machine?.remove(id: pendingCall.id)
            removePeerTransmitState(id: pendingCall.id)
            self.pendingCall = nil
            errorMessage = "Could not answer the incoming call."
            await syncHostAvailability()
        }
    }

    func declinePendingCall() async {
        await declinePendingCall(reason: "Declined")
    }

    private func declinePendingCall(reason: String) async {
        guard isPersonalMode, !isAnsweringPendingCall, let pendingCall else { return }
        machine?.remove(id: pendingCall.id)
        removePeerTransmitState(id: pendingCall.id)
        self.pendingCall = nil
        let bye = EchoLinkControlPacketCodec.buildBYEPacket(reason: reason)
        try? await controlSocket?.send(bye, to: pendingCall.sourceIPv4Address,
                                      port: pendingCall.controlPort)
        await syncHostAvailability()
    }

    func expirePendingCalls(now: Date) async {
        guard isPersonalMode, !isAnsweringPendingCall, let pendingCall,
              now.timeIntervalSince(pendingCall.admittedAt) >= 10 else { return }
        await declinePendingCall(reason: "No answer")
    }

    private func syncHostAvailability() async {
        guard isRunning, let directory else { return }
        let available = machine?.availability == .on
        if !(await directory.setAvailableForCalls(available)) {
            errorMessage = "Could not update EchoLink availability."
            await stop()
        }
    }

    #if DEBUG
    /// UI-only fixture. It never opens sockets or registers with EchoLink.
    func installSimulatorDemoIncomingCall(callsign: String = "K6DEMO") {
        guard !isRunning else { return }
        let station = Station(callsign: callsign, ipAddress: "127.0.0.1", type: .user)
        machine = InboundHostSessionMachine(policy: .init(maximumPeers: 1), isEnabled: true)
        localCallsign = "W6DEMO"
        maximumPeers = 1
        isPersonalMode = true
        isLocalDemo = true
        isRunning = true
        installLocalDemoIncomingCall(station: station)
    }
    #endif

    func sendChat(_ text: String) async -> Bool {
        guard isRunning, !sessions.isEmpty,
              let body = Self.sanitizedChatBody(text) else { return false }
        if isLocalDemo {
            appendMessage(ChatMessage(sender: localCallsign, body: body, isOutgoing: true))
            return true
        }
        guard let audioSocket else { return false }
        let packet = EchoLinkControlPacketCodec.buildNDATAChatPacket(sender: localCallsign, message: body)
        var sent = false
        for peer in sessions {
            do {
                try await audioSocket.send(packet, to: peer.sourceIPv4Address, port: peer.audioPort)
                sent = true
            } catch {
                logger.warning("Conference chat send failed callsign=\(peer.callsign, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        guard sent else {
            errorMessage = "Could not send the conference message."
            return false
        }
        appendMessage(ChatMessage(sender: localCallsign, body: body, isOutgoing: true))
        return true
    }

    private func receiveControl() async {
        guard let socket = controlSocket else { return }
        while isRunning && !Task.isCancelled {
            do {
                let datagram = try await socket.receive(maximumBytes: 4_096)
                await handleControl(datagram)
            } catch is CancellationError {
                break
            } catch {
                if !Task.isCancelled && isRunning {
                    errorMessage = "Conference control socket stopped: \(error.localizedDescription)"
                    await stop()
                }
                break
            }
        }
    }

    private func handleControl(_ datagram: BoundUDPSocket.Datagram) async {
        for event in EchoLinkControlPacketCodec.parseEvents(from: datagram.data) {
            switch event {
            case .sdes(let info):
                await handleSDES(info, from: datagram)
            case .bye:
                guard let peer = machine?.sessions.first(where: {
                    $0.sourceIPv4Address == datagram.sourceHost && $0.controlPort == datagram.sourcePort
                }) else { continue }
                machine?.remove(id: peer.id)
                removePeerTransmitState(id: peer.id)
                if pendingCall?.id == peer.id { pendingCall = nil }
                floor.remove(peer.id)
                publishSessions()
                await syncHostAvailability()
                await broadcastInfo("\(peer.callsign) left")
            case .info, .chat:
                break
            }
        }
    }

    private func handleSDES(_ info: EchoLinkSDESInfo, from datagram: BoundUDPSocket.Datagram) async {
        guard let name = info.preferredDisplayName, let directory else { return }
        let now = Date()
        if let existing = machine?.sessions.first(where: {
            $0.sourceIPv4Address == datagram.sourceHost && $0.controlPort == datagram.sourcePort
        }) {
            guard name.split(whereSeparator: \.isWhitespace).first?.uppercased() == existing.callsign else { return }
            if info.supportsSpeex { speexCapablePeerIDs.insert(existing.id) }
            machine?.recordActivity(id: existing.id, now: now)
            return
        }

        let claim = InboundCallClaim(advertisedName: name, sourceIPv4Address: datagram.sourceHost, receivedAt: now)
        guard let verified = try? VerifiedInboundHostPeer.verify(
            claim: claim,
            stations: directory.stations,
            directoryUpdatedAt: directory.lastSuccessfulSnapshotAt,
            now: now,
            maxDirectoryAge: 90
        ).get() else {
            logger.warning("Rejected unverified conference caller source=\(datagram.sourceHost, privacy: .public)")
            return
        }

        if let reason = (callAccessPolicyProvider?() ?? CallAccessPolicyStore.load(demo: isLocalDemo)).rejection(
            for: verified.station, direction: .incoming, countryCode: verified.station.callSignCountryCode
        ) {
            let bye = EchoLinkControlPacketCodec.buildBYEPacket(reason: reason)
            try? await controlSocket?.send(bye, to: datagram.sourceHost, port: datagram.sourcePort)
            return
        }

        let audioPort: Int
        if info.privateItems.contains(where: { $0.hasPrefix("P") }) {
            guard let advertisedPort = Self.advertisedAudioPort(info.privateItems) else { return }
            audioPort = advertisedPort
        } else {
            audioPort = 5198
        }
        guard case .success(let admitted) = machine?.admit(
            verified, controlPort: Int(datagram.sourcePort), audioPort: audioPort, now: now
        ) else {
            let bye = EchoLinkControlPacketCodec.buildBYEPacket(reason: "Busy or access denied")
            try? await controlSocket?.send(bye, to: datagram.sourceHost, port: datagram.sourcePort)
            return
        }
        if info.supportsSpeex { speexCapablePeerIDs.insert(admitted.id) }

        if isPersonalMode {
            pendingCall = admitted
            await syncHostAvailability()
            return
        }

        let acknowledgement = EchoLinkControlPacketCodec.buildSDESPacket(
            callsign: localCallsign, audioPort: ports.audio,
            advertiseSpeex: speexCodec.isEncoderAvailable
        )
        do {
            try await controlSocket?.send(acknowledgement, to: datagram.sourceHost, port: datagram.sourcePort)
            guard machine?.activate(id: admitted.id, now: Date()) == true else { return }
            publishSessions()
            await syncHostAvailability()
            await sendInfo("\(localCallsign) conference: \(sessions.count)/\(maximumPeers) connected", to: admitted)
            await broadcastInfo("\(admitted.callsign) joined", excluding: admitted.id)
            logger.info("Admitted conference peer callsign=\(admitted.callsign, privacy: .public)")
        } catch {
            machine?.remove(id: admitted.id)
            removePeerTransmitState(id: admitted.id)
            publishSessions()
        }
    }

    private func receiveAudio() async {
        guard let socket = audioSocket else { return }
        while isRunning && !Task.isCancelled {
            do {
                let datagram = try await socket.receive(maximumBytes: 4_096)
                await handleAudio(datagram)
            } catch is CancellationError {
                break
            } catch {
                if !Task.isCancelled && isRunning {
                    errorMessage = "Conference audio socket stopped: \(error.localizedDescription)"
                    await stop()
                }
                break
            }
        }
    }

    private func handleAudio(_ datagram: BoundUDPSocket.Datagram) async {
        guard let peer = machine?.sessions.first(where: {
            $0.state == .active && $0.sourceIPv4Address == datagram.sourceHost
                && $0.audioPort == datagram.sourcePort
        }) else { return }
        let now = Date()

        if let event = EchoLinkControlPacketCodec.parseEvents(from: datagram.data).first {
            if case .chat(_, let body) = event, let safeBody = Self.sanitizedChatBody(body) {
                machine?.recordActivity(id: peer.id, now: now)
                let packet = EchoLinkControlPacketCodec.buildNDATAChatPacket(sender: peer.callsign, message: safeBody)
                await broadcastAudio(packet, excluding: peer.id)
                appendMessage(ChatMessage(sender: peer.callsign, body: safeBody))
            }
            return
        }

        guard let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(datagram.data) else { return }
        let codec: ConferenceReceiveAudioCodec
        if let existing = peerAudioCodecs[peer.id] {
            codec = existing
        } else {
            guard peerAudioCodecs.count < 99 else { return }
            codec = ConferenceReceiveAudioCodec()
            peerAudioCodecs[peer.id] = codec
        }
        guard let decoded = codec.decode(parsed) else { return }
        machine?.recordActivity(id: peer.id, now: now)
        let gsm = decoded.gsmPayload

        guard !isTransmitting else { return }
        let active = machine?.sessions.filter { $0.state == .active } ?? []
        let previousTalker = floor.talkerID
        let listenerIDs = floor.listeners(for: peer.id, activeIDs: active.map(\.id), at: now)
        guard floor.talkerID == peer.id else { return }
        if previousTalker != peer.id {
            publishTalker()
            await broadcastInfo("\(peer.callsign) talking")
        }
        if isMonitoringAudio {
            audioEngine.playReceivedPCM(
                decoded.samples,
                metadata: parsed.metadata,
                nativeConcealment: decoded.nativeConcealment
            )
        } else {
            onUnmonitoredReceivedPCM?(decoded.samples)
        }
        guard !gsm.isEmpty else { return }
        let sampleCount = gsm.count / GSMCodec.encodedFrameSize * GSMCodec.samplesPerFrame
        for listener in active where listenerIDs.contains(listener.id) {
            let packet = buildVoicePacket(
                payload: gsm, codec: .gsm, sampleCount: sampleCount, peerID: listener.id
            )
            try? await audioSocket?.send(packet, to: listener.sourceIPv4Address, port: listener.audioPort)
        }
    }

    private func maintain() async {
        var secondsSinceKeepalive = 0
        var secondsSinceRefresh = 0
        while isRunning && !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
            guard isRunning && !Task.isCancelled else { break }
            if !isTransmitting, let finished = floor.expire(at: .now) {
                let callsign = sessions.first(where: { $0.id == finished })?.callsign
                publishTalker()
                if let callsign { await broadcastInfo("\(callsign) stopped transmitting") }
            }
            for peer in machine?.sessions ?? [] where Date().timeIntervalSince(peer.lastActivityAt) >= 90 {
                await disconnect(id: peer.id)
            }
            await expirePendingCalls(now: .now)
            secondsSinceKeepalive += 1
            if secondsSinceKeepalive >= 20 {
                secondsSinceKeepalive = 0
                let keepalive = EchoLinkControlPacketCodec.buildSDESPacket(
                    callsign: localCallsign, audioPort: ports.audio,
                    advertiseSpeex: speexCodec.isEncoderAvailable
                )
                for peer in machine?.sessions ?? [] where peer.state == .active {
                    try? await controlSocket?.send(keepalive, to: peer.sourceIPv4Address, port: peer.controlPort)
                }
            }
            secondsSinceRefresh += 1
            if secondsSinceRefresh >= 60 {
                secondsSinceRefresh = 0
                if let directory {
                    _ = await directory.refresh()
                    if !directory.isLoggedIn {
                        errorMessage = "EchoLink sign-in ended, so conference hosting stopped."
                        await stop()
                        break
                    }
                }
            }
        }
    }

    private func sendInfo(_ text: String, to peer: InboundHostSession) async {
        let packet = EchoLinkControlPacketCodec.buildNDATAInfoPacket(message: text)
        try? await audioSocket?.send(packet, to: peer.sourceIPv4Address, port: peer.audioPort)
    }

    private func broadcastInfo(_ text: String, excluding excludedID: UUID? = nil) async {
        let packet = EchoLinkControlPacketCodec.buildNDATAInfoPacket(message: text)
        await broadcastAudio(packet, excluding: excludedID)
    }

    private func broadcastAudio(_ packet: Data, excluding excludedID: UUID? = nil) async {
        for peer in machine?.sessions ?? [] where peer.state == .active && peer.id != excludedID {
            try? await audioSocket?.send(packet, to: peer.sourceIPv4Address, port: peer.audioPort)
        }
    }

    private func publishSessions() {
        sessions = machine?.sessions.filter { $0.state == .active } ?? []
        if isPersonalMode, sessions.isEmpty { setPTT(active: false) }
        if sessions.isEmpty { stopRecording() }
        else { prepareSessionRecording() }
        let activeIDs = Set(sessions.map(\.id))
        peerAudioCodecs = peerAudioCodecs.filter { activeIDs.contains($0.key) }
        let admittedIDs = Set((machine?.sessions ?? []).map(\.id))
        speexCapablePeerIDs.formIntersection(admittedIDs)
        activeLocalTransmitCodecs = activeLocalTransmitCodecs.filter { admittedIDs.contains($0.key) }
        peerVoiceClocks = peerVoiceClocks.filter { admittedIDs.contains($0.key) }
        queuedLocalAudio = queuedLocalAudio.compactMap { queued in
            let recipients = queued.recipients.filter { admittedIDs.contains($0.id) }
            return recipients.isEmpty ? nil : QueuedLocalAudioPacket(
                payload: queued.payload, codec: queued.codec,
                sampleCount: queued.sampleCount, recipients: recipients
            )
        }
        publishTalker()
    }

    private func removePeerTransmitState(id: UUID) {
        speexCapablePeerIDs.remove(id)
        activeLocalTransmitCodecs.removeValue(forKey: id)
        peerVoiceClocks.removeValue(forKey: id)
        queuedLocalAudio = queuedLocalAudio.compactMap { queued in
            let recipients = queued.recipients.filter { $0.id != id }
            return recipients.isEmpty ? nil : QueuedLocalAudioPacket(
                payload: queued.payload, codec: queued.codec,
                sampleCount: queued.sampleCount, recipients: recipients
            )
        }
    }

    private func buildVoicePacket(
        payload: Data,
        codec: EchoLinkVoiceCodec,
        sampleCount: Int,
        peerID: UUID
    ) -> Data {
        var clock = peerVoiceClocks[peerID] ?? PeerVoiceClock()
        let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: payload, sequence: clock.sequence, timestamp: clock.timestamp, codec: codec
        )
        clock.sequence &+= 1
        clock.timestamp &+= UInt32(max(0, sampleCount))
        peerVoiceClocks[peerID] = clock
        return packet
    }

    private func publishTalker() {
        talkerCallsign = isTransmitting ? localCallsign : sessions.first(where: { $0.id == floor.talkerID })?.callsign
    }

    private func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
    }

    private func startLocalDemo(
        callsign: String,
        policy: InboundHostPolicy,
        monitorAudio: Bool,
        personal: Bool
    ) {
        guard policy.isValid, (personal ? policy.maximumPeers == 1 : policy.maximumPeers >= 2) else {
            errorMessage = "Choose a conference limit from 2 to 99 stations."
            return
        }
        generation &+= 1
        let startingGeneration = generation
        localCallsign = callsign
        maximumPeers = policy.maximumPeers
        isPersonalMode = personal
        isLocalDemo = true
        isMonitoringAudio = monitorAudio
        machine = InboundHostSessionMachine(policy: policy, isEnabled: true)
        ports = .echolink
        pendingCall = nil
        localDemoStation = nil
        sessions = []
        peerAudioCodecs.removeAll()
        messages = []
        talkerCallsign = nil
        isTransmitting = false
        queuedLocalAudio = []
        pendingLocalGSM = Data()
        speexCapablePeerIDs = []
        activeLocalTransmitCodecs = [:]
        peerVoiceClocks = [:]
        speexCodec.resetEncoding()
        floor.reset()
        isStarting = false
        isRunning = true
        audioEngine.resetCodecState()
        audioEngine.onCapturedAudio = { [weak self] data in
            self?.enqueueLocalGSM(data)
        }
        audioEngine.onCapturedPCM = { [weak self] samples in
            self?.enqueueLocalSpeex(samples)
        }
        if monitorAudio { audioEngine.startPlayback() }

        localDemoIncomingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled, self.isRunning, self.isLocalDemo,
                  self.generation == startingGeneration,
                  let station = LocalDemoAccount.stations.first(where: { $0.type == .user })
            else { return }
            self.installLocalDemoIncomingCall(station: station)
            self.localDemoIncomingTask = nil
        }
    }

    private func installLocalDemoIncomingCall(station: Station) {
        guard isRunning, isLocalDemo else { return }
        let now = Date()
        let claim = InboundCallClaim(
            advertisedName: station.callsign,
            sourceIPv4Address: station.ipAddress,
            receivedAt: now
        )
        guard let verified = try? VerifiedInboundHostPeer.verify(
            claim: claim,
            stations: [station],
            directoryUpdatedAt: now,
            now: now,
            maxDirectoryAge: 60
        ).get(),
        case .success(let peer) = machine?.admit(
            verified,
            controlPort: 5199,
            audioPort: 5198,
            now: now
        ) else { return }

        localDemoStation = station
        if isPersonalMode {
            pendingCall = peer
        } else if machine?.activate(id: peer.id, now: now) == true {
            publishSessions()
            LocalDemoAccount.messages(for: station, account: localCallsign)
                .forEach(appendMessage)
        }
    }

    private static func sanitizedChatBody(_ text: String) -> String? {
        let body = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\0", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.utf8.count <= 1_024 else { return nil }
        return body
    }

    static func advertisedAudioPort(_ privateItems: [String]) -> Int? {
        for item in privateItems where item.hasPrefix("P") {
            guard let port = Int(item.dropFirst()), (1...65535).contains(port) else { return nil }
            return port
        }
        return nil
    }

    private static func isPersonalCallsign(_ value: String) -> Bool {
        let callsign = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return !callsign.isEmpty && !callsign.contains("*") &&
            !callsign.hasSuffix("-R") && !callsign.hasSuffix("-L")
    }
}
#endif
