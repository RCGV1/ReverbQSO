// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import os

/// Errors that can occur during a QSO connection.
enum ConnectionError: LocalizedError {
    case alreadyConnected
    case connectionFailed(String)
    case handshakeTimedOut
    case notConnected
    case remoteBye(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyConnected: return "Already connected to a station."
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        case .handshakeTimedOut: return "Connection failed: the remote station did not acknowledge the EchoLink handshake."
        case .notConnected: return "Not connected to any station."
        case .remoteBye(let message): return message
        case .sendFailed(let reason): return "Send failed: \(reason)"
        }
    }
}

struct EchoLinkSDESInfo: Equatable {
    var cname: String?
    var name: String?
    var email: String?
    var phone: String?
    var tool: String?
    var priv: String?
    var privateItems: [String] = []

    var supportsSpeex: Bool {
        (privateItems + [priv].compactMap { $0 }).contains { item in
            item.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
                .contains { $0 == "SPEEX" }
        }
    }

    var preferredDisplayName: String? {
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let cname {
            let trimmed = cname.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

enum EchoLinkControlEvent: Equatable {
    case sdes(EchoLinkSDESInfo)
    case bye(reason: String?)
    case info(String)
    case chat(sender: String, body: String)
}

enum EchoLinkPTTTransition {
    static func shouldQueuePress(isPTTActive: Bool, releaseInProgress: Bool) -> Bool {
        isPTTActive && releaseInProgress
    }
}

enum EchoLinkControlPacketCodec {
    private static let rtcpPayloadTypeSR: UInt8 = 200
    private static let rtcpPayloadTypeRR: UInt8 = 201
    private static let rtcpPayloadTypeSDES: UInt8 = 202
    private static let rtcpPayloadTypeBYE: UInt8 = 203

    private static let sdesTypeEnd: UInt8 = 0
    private static let sdesTypeCNAME: UInt8 = 1
    private static let sdesTypeNAME: UInt8 = 2
    private static let sdesTypeEMAIL: UInt8 = 3
    private static let sdesTypePHONE: UInt8 = 4
    private static let sdesTypeTOOL: UInt8 = 6
    private static let sdesTypePRIV: UInt8 = 8

    static func buildSDESPacket(
        callsign: String,
        tool: String? = "ReverbQSO/1.0",
        phone: String = "08:30",
        includePadding: Bool = false,
        rtpVersion: UInt8 = 3,
        audioPort: UInt16 = 5198,
        advertiseSpeex: Bool = true
    ) -> Data {
        var packet = Data()

        // RTCP Receiver Report (required first block).
        packet.append(rtcpHeaderByte(version: rtpVersion, sourceCount: 0))
        packet.append(rtcpPayloadTypeRR)
        packet.append(0x00)
        packet.append(0x01)
        packet.append(contentsOf: [0, 0, 0, 0]) // SSRC=0

        let normalizedCallsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let displayName = normalizedCallsign.count >= 15
            ? normalizedCallsign
            : normalizedCallsign + String(repeating: " ", count: 15 - normalizedCallsign.count)

        var sdesBody = Data()
        sdesBody.append(contentsOf: [0, 0, 0, 0]) // SSRC=0
        // These legacy values match the long-standing EchoLib handshake used by
        // EchoLink-compatible nodes. The actual identity is carried in NAME.
        appendSDESItem(type: sdesTypeCNAME, text: "CALLSIGN", to: &sdesBody)
        appendSDESItem(type: sdesTypeNAME, text: displayName, to: &sdesBody)
        appendSDESItem(type: sdesTypeEMAIL, text: "CALLSIGN", to: &sdesBody)
        appendSDESItem(type: sdesTypePHONE, text: phone, to: &sdesBody)
        if let tool, !tool.isEmpty {
            appendSDESItem(type: sdesTypeTOOL, text: tool, to: &sdesBody)
        }
        // EchoLib peers inspect only the first PRIV item. The legacy SPEEX
        // capability is bare ASCII, so it must precede RFC-shaped port/pad items.
        if advertiseSpeex {
            appendSDESItem(type: sdesTypePRIV, text: "SPEEX", to: &sdesBody)
        }
        appendSDESPrivateItem(prefix: "P", value: String(audioPort), to: &sdesBody)
        appendSDESPrivateItem(prefix: "D", value: "0", to: &sdesBody)
        sdesBody.append(sdesTypeEnd)
        padToWordBoundary(&sdesBody)
        if includePadding {
            // The official client pads its final SDES block by one RTCP word.
            sdesBody.append(contentsOf: [0x00, 0x00, 0x00, 0x04])
        }

        // RTCP length field counts 32-bit words of header+body minus one.
        let sdesLengthWordsMinus1 = UInt16(sdesBody.count / 4)
        packet.append(rtcpHeaderByte(version: rtpVersion, sourceCount: 1, isPadded: includePadding))
        packet.append(rtcpPayloadTypeSDES)
        packet.append(UInt8((sdesLengthWordsMinus1 >> 8) & 0xFF))
        packet.append(UInt8(sdesLengthWordsMinus1 & 0xFF))
        packet.append(sdesBody)
        return packet
    }

    static func buildBYEPacket(reason: String = "jan2002", rtpVersion: UInt8 = 3) -> Data {
        var packet = Data()

        packet.append(rtcpHeaderByte(version: rtpVersion, sourceCount: 0))
        packet.append(rtcpPayloadTypeRR)
        packet.append(0x00)
        packet.append(0x01)
        packet.append(contentsOf: [0, 0, 0, 0]) // SSRC=0

        var byeBody = Data()
        byeBody.append(contentsOf: [0, 0, 0, 0]) // SSRC=0
        let reasonBytes = Array(reason.utf8)
        byeBody.append(UInt8(min(reasonBytes.count, 255)))
        byeBody.append(contentsOf: reasonBytes.prefix(255))
        padToWordBoundary(&byeBody)

        // RTCP length field counts 32-bit words of header+body minus one.
        let byeLengthWordsMinus1 = UInt16(byeBody.count / 4)
        packet.append(rtcpHeaderByte(version: rtpVersion, sourceCount: 1))
        packet.append(rtcpPayloadTypeBYE)
        packet.append(UInt8((byeLengthWordsMinus1 >> 8) & 0xFF))
        packet.append(UInt8(byeLengthWordsMinus1 & 0xFF))
        packet.append(byeBody)
        return packet
    }

    static func buildNDATAInfoPacket(message: String) -> Data {
        var packet = Data()
        packet.append(contentsOf: "oNDATA\r".utf8)
        packet.append(contentsOf: message.utf8)
        packet.append(0x00)
        return packet
    }

    static func buildNDATAChatPacket(sender: String, message: String) -> Data {
        var packet = Data()
        packet.append(contentsOf: "oNDATA".utf8)
        packet.append(contentsOf: "\(sender)>\(message)\r\n".utf8)
        packet.append(0x00)
        return packet
    }

    static func parseEvents(from data: Data) -> [EchoLinkControlEvent] {
        guard !data.isEmpty else { return [] }

        let rtcpEvents = parseRTCPCompound(data)
        if !rtcpEvents.isEmpty {
            return rtcpEvents
        }

        if let ndataEvent = parseNDATA(data) {
            return [ndataEvent]
        }

        return []
    }

    // MARK: - Private

    private static func rtcpHeaderByte(
        version: UInt8,
        sourceCount: UInt8,
        isPadded: Bool = false
    ) -> UInt8 {
        ((version & 0x03) << 6)
            | (isPadded ? 0x20 : 0)
            | (sourceCount & 0x1F)
    }

    private static func appendSDESItem(type: UInt8, text: String, to data: inout Data) {
        let bytes = Array(text.utf8)
        let length = min(bytes.count, 255)
        data.append(type)
        data.append(UInt8(length))
        data.append(contentsOf: bytes.prefix(length))
    }

    private static func appendSDESPrivateItem(prefix: String, value: String, to data: inout Data) {
        let prefixBytes = Array(prefix.utf8.prefix(255))
        let valueBytes = Array(value.utf8)
        let payloadLength = min(1 + prefixBytes.count + valueBytes.count, 255)

        data.append(sdesTypePRIV)
        data.append(UInt8(payloadLength))
        data.append(UInt8(prefixBytes.count))
        data.append(contentsOf: prefixBytes)
        let remainingValueBytes = max(0, payloadLength - 1 - prefixBytes.count)
        data.append(contentsOf: valueBytes.prefix(remainingValueBytes))
    }

    private static func padToWordBoundary(_ data: inout Data) {
        while data.count % 4 != 0 {
            data.append(0x00)
        }
    }

    private static func parseRTCPCompound(_ data: Data) -> [EchoLinkControlEvent] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }

        var offset = 0
        var events: [EchoLinkControlEvent] = []
        var sawValidRTCPBlock = false

        while offset + 4 <= bytes.count {
            let version = bytes[offset] >> 6
            guard version == 2 || version == 3 else {
                return []
            }

            let payloadType = bytes[offset + 1]
            let lengthWordsMinus1 = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            let blockLength = (lengthWordsMinus1 + 1) * 4
            guard blockLength >= 4, offset + blockLength <= bytes.count else {
                return []
            }

            sawValidRTCPBlock = true
            let block = Data(bytes[offset..<(offset + blockLength)])
            switch payloadType {
            case rtcpPayloadTypeSDES:
                if let sdes = parseSDESBlock(block) {
                    events.append(.sdes(sdes))
                }
            case rtcpPayloadTypeBYE:
                events.append(.bye(reason: parseBYEReason(block)))
            case rtcpPayloadTypeRR, rtcpPayloadTypeSR:
                break
            default:
                break
            }

            offset += blockLength
        }

        guard sawValidRTCPBlock, offset == bytes.count else {
            return []
        }

        return events
    }

    private static func parseBYEReason(_ block: Data) -> String? {
        let bytes = [UInt8](block)
        guard bytes.count >= 4 else { return nil }

        var payloadEnd = bytes.count
        if bytes[0] & 0x20 != 0 {
            let paddingCount = Int(bytes[bytes.count - 1])
            guard paddingCount > 0, paddingCount <= bytes.count - 4 else { return nil }
            payloadEnd -= paddingCount
        }

        let sourceCount = Int(bytes[0] & 0x1F)
        let reasonLengthOffset = 4 + (sourceCount * 4)
        guard reasonLengthOffset < payloadEnd else { return nil }

        let reasonLength = Int(bytes[reasonLengthOffset])
        guard reasonLength > 0,
              reasonLengthOffset + 1 + reasonLength <= payloadEnd else { return nil }

        let reasonBytes = bytes[(reasonLengthOffset + 1)..<(reasonLengthOffset + 1 + reasonLength)]
        let reason = String(decoding: reasonBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }

    private static func parseSDESBlock(_ block: Data) -> EchoLinkSDESInfo? {
        let bytes = [UInt8](block)
        guard bytes.count >= 8 else { return nil }

        let sourceCount = Int(bytes[0] & 0x1F)
        guard sourceCount > 0 else { return nil }

        var info = EchoLinkSDESInfo()
        var offset = 4

        for _ in 0..<sourceCount {
            guard offset + 4 <= bytes.count else { return nil }
            offset += 4 // SSRC

            while offset < bytes.count {
                let itemType = bytes[offset]
                offset += 1

                if itemType == sdesTypeEnd {
                    while offset % 4 != 0, offset < bytes.count {
                        offset += 1
                    }
                    break
                }

                guard offset < bytes.count else { return nil }
                let itemLength = Int(bytes[offset])
                offset += 1
                guard offset + itemLength <= bytes.count else { return nil }

                let itemBytes = Array(bytes[offset..<(offset + itemLength)])
                let text = String(decoding: itemBytes, as: UTF8.self)
                switch itemType {
                case sdesTypeCNAME:
                    if info.cname == nil { info.cname = text }
                case sdesTypeNAME:
                    if info.name == nil { info.name = text }
                case sdesTypeEMAIL:
                    if info.email == nil { info.email = text }
                case sdesTypePHONE:
                    if info.phone == nil { info.phone = text }
                case sdesTypeTOOL:
                    if info.tool == nil { info.tool = text }
                case sdesTypePRIV:
                    let decodedPrivateItem = decodeSDESPrivateItem(itemBytes)
                    if info.priv == nil { info.priv = decodedPrivateItem }
                    info.privateItems.append(decodedPrivateItem)
                default:
                    break
                }
                offset += itemLength
            }
        }

        if info.cname == nil,
           info.name == nil,
           info.email == nil,
           info.phone == nil,
           info.tool == nil,
           info.priv == nil {
            return nil
        }
        return info
    }

    private static func decodeSDESPrivateItem(_ bytes: [UInt8]) -> String {
        guard let prefixLength = bytes.first.map(Int.init),
              prefixLength <= bytes.count - 1 else {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(decoding: bytes.dropFirst(), as: UTF8.self)
    }

    private static func parseNDATA(_ data: Data) -> EchoLinkControlEvent? {
        guard data.count >= 6 else { return nil }
        guard Data(data.prefix(6)) == Data("oNDATA".utf8) else { return nil }

        var payload = Data(data.dropFirst(6))
        if payload.count >= 5 {
            // Some nodes append a four-byte binary identifier after NDATA text.
            let trailerStart = payload.index(payload.endIndex, offsetBy: -4)
            let byteBeforeTrailer = payload[payload.index(before: trailerStart)]
            let nulIndex = payload.firstIndex(of: 0)
            let lastPayloadIndex = payload.index(before: payload.endIndex)
            let nulHasFollowingBytes = nulIndex.map { $0 != lastPayloadIndex } ?? false
            let possibleTrailer = payload[trailerStart..<payload.endIndex]
            let possibleBinaryBytes = payload.last == 0
                ? possibleTrailer.dropLast()
                : possibleTrailer[...]
            let hasNonTextByte = possibleBinaryBytes.contains {
                ($0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D) || $0 >= 0x7F
            }
            let isLineTerminatedTrailer = byteBeforeTrailer == 0x0A || byteBeforeTrailer == 0x0D
            if isLineTerminatedTrailer,
               nulIndex == nil || nulHasFollowingBytes || hasNonTextByte {
                payload.removeSubrange(trailerStart..<payload.endIndex)
            }
        }
        if let nulIndex = payload.firstIndex(of: 0) {
            payload.removeSubrange(nulIndex..<payload.endIndex)
        }
        while payload.last == 0 {
            payload.removeLast()
        }

        let text = String(decoding: payload, as: UTF8.self)
        if text.hasPrefix("\r") {
            let info = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return info.isEmpty ? nil : .info(info)
        }

        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        if let split = content.firstIndex(of: ">") {
            let sender = String(content[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(content[content.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return .chat(sender: sender.isEmpty ? "Remote" : sender, body: body)
        }

        if let split = content.firstIndex(of: ":") {
            let sender = String(content[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(content[content.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return .chat(sender: sender.isEmpty ? "Remote" : sender, body: body)
        }

        return .chat(sender: "Remote", body: content)
    }
}

struct EchoLinkReceiveSequencer {
    private static let restartInactivityInterval: TimeInterval = 2
    private static let maximumTrackedStreams = 32

    private struct StreamState {
        var lastAcceptedSequence: UInt16
        var lastAcceptedAt: TimeInterval
    }

    private var streamsBySSRC: [UInt32: StreamState] = [:]

    mutating func shouldAcceptForPlayback(
        _ metadata: EchoLinkVoicePacketMetadata?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard let metadata else { return true }

        guard let stream = streamsBySSRC[metadata.ssrc] else {
            accept(metadata, now: now)
            return true
        }

        if now - stream.lastAcceptedAt >= Self.restartInactivityInterval {
            accept(metadata, now: now)
            return true
        }

        let forwardDistance = Int(metadata.sequenceNumber &- stream.lastAcceptedSequence)
        if forwardDistance == 0 {
            return false
        }

        // RTP sequence arithmetic treats distances below half the UInt16 range as
        // forward progress (including wraparound) and the other half as late data.
        if forwardDistance < 0x8000 {
            accept(metadata, now: now)
            return true
        }
        return false
    }

    mutating func reset() {
        streamsBySSRC.removeAll(keepingCapacity: true)
    }

    private mutating func accept(_ metadata: EchoLinkVoicePacketMetadata, now: TimeInterval) {
        if streamsBySSRC[metadata.ssrc] == nil,
           streamsBySSRC.count >= Self.maximumTrackedStreams,
           let leastRecentlyAccepted = streamsBySSRC.min(by: {
               $0.value.lastAcceptedAt < $1.value.lastAcceptedAt
           })?.key {
            streamsBySSRC.removeValue(forKey: leastRecentlyAccepted)
        }
        streamsBySSRC[metadata.ssrc] = StreamState(
            lastAcceptedSequence: metadata.sequenceNumber,
            lastAcceptedAt: now
        )
    }
}

/// Service that manages a single active QSO session with a remote EchoLink station.
///
/// Protocol:
/// - UDP port 5198: voice stream and commonly NDATA chat/info packets
/// - UDP port 5199: RTCP SDES/BYE control exchange
/// - No TCP connection to remote stations (TCP 5200 is only for the directory server)
@MainActor
final class EchoLinkConnectionService: ObservableObject {
    private struct OutgoingAudioPacket {
        let data: Data
        let sessionID: UUID
        let remoteHost: String
    }

    // MARK: - Published State

    /// Manual clip state; automatic QSO recording runs independently.
    @Published private(set) var isRecording = false
    @Published private(set) var isAutomaticallyRecording = false
    private var recordingCoordinator: QSORecordingCoordinator?
    private var recordingSessionID: UUID?
    private let recordingDefaults: UserDefaults
    private let recordingFolder: URL?
    var callAccessPolicyProvider: (() -> CallAccessPolicy)?

    func toggleRecording() {
        guard session?.state == .connected else { return }
        prepareSessionRecording()
        recordingCoordinator?.toggleClip()
        publishRecordingState()
    }

    private func prepareSessionRecording() {
        guard let session, session.state == .connected,
              recordingSessionID != session.id else { return }
        stopSessionRecording()
        let coordinator = QSORecordingCoordinator(
            folder: recordingFolder, demo: isLocalDemoMode, defaults: recordingDefaults
        )
        recordingCoordinator = coordinator
        recordingSessionID = session.id
        coordinator.startSession(callsign: session.station.callsign)
        audioEngine.onRecordingPCM = { [weak self] samples in
            self?.appendRecordingPCM(samples)
        }
        publishRecordingState()
    }

    private func appendRecordingPCM(_ samples: [Int16]) {
        guard isRecording || isAutomaticallyRecording else { return }
        recordingCoordinator?.append(samples)
        publishRecordingState()
    }

    private func publishRecordingState() {
        let clip = recordingCoordinator?.isRecordingClip ?? false
        let automatic = recordingCoordinator?.isAutomaticallyRecording ?? false
        if isRecording != clip { isRecording = clip }
        if isAutomaticallyRecording != automatic { isAutomaticallyRecording = automatic }
        if let message = recordingCoordinator?.errorMessage { audioStatusMessage = message }
    }

    private func stopSessionRecording() {
        recordingCoordinator?.stopSession()
        publishRecordingState()
        recordingCoordinator = nil
        recordingSessionID = nil
        audioEngine.onRecordingPCM = nil
        isRecording = false
        isAutomaticallyRecording = false
    }

    @Published var session: QSOSession? {
        didSet {
            if let waiter = handshakeWaiter {
                if session?.id != waiter.sessionID || session?.state == .disconnecting || session?.state == .disconnected {
                    completeHandshakeWaiter(id: waiter.id, result: .failure(CancellationError()))
                } else if session?.state == .connected {
                    completeHandshakeWaiter(id: waiter.id, result: .success(true))
                }
            }
            if session?.state == .connected { prepareSessionRecording() }
            else if session == nil || session?.state == .disconnected { stopSessionRecording() }
        }
    }
    @Published var incomingChatMessages: [ChatMessage] = []
    @Published var activeNodeParticipants: [ActiveNodeParticipant] = []
    @Published var error: Error?
    @Published private(set) var reconnectCandidate: Station?
    @Published private(set) var isReconnecting = false
    @Published var audioStatusMessage: String?
    @Published private(set) var inputLevel: Double = 0.0
    @Published private(set) var outputLevel: Double = 0.0
    @Published private(set) var isRemoteTransmitting = false
    @Published private(set) var remotePadAllowed = false
    @Published private(set) var isSendingDTMF = false
    @Published private(set) var audioOutputRouteName = "System Audio"
    @Published private(set) var audioOutputPreference: AudioOutputPreference = .speaker
    @Published private(set) var audioInputDevices: [AudioInputDevice] = []
    @Published private(set) var selectedAudioInputDeviceID: String?
    @Published private(set) var watchAudioOutputAvailable = false
    @Published private(set) var usesWatchAudioOutput = false
    var onReceivedVoicePacket: (@MainActor (Data) -> Void)?
    @Published private(set) var isCaptureReady = false
    @Published private(set) var isLocalDemoMode = false

    /// Closure called when a session ends, providing the station and duration for recording.
    var onSessionEnded: ((Station, TimeInterval) -> Void)?
    var prepareRelayDirectory: (@MainActor (String, String) async throws -> Void)?
    var finishRelayDirectory: (@MainActor (String, String) async -> Void)?
    private var relayDirectoryAddress: String?
    var resolveStation: ((Station) -> Station)?
    var resolveReconnectStation: (@MainActor (Station) async throws -> Station?)?
    var resolveProxySession: (@MainActor (String) async throws -> EchoLinkProxySession?)?
    var consumeReservedDirectSockets: (@MainActor () -> DirectCQSocketPair?)?
    var isConferenceHostActive: (() -> Bool)?
    var authenticatedCallsign: String?
    var pttPermission: (@MainActor () -> Bool)?
    private var isBackgroundMuted = false
    private var localDemoCallsign = "DEMO"
    private var localDemoAudio = LocalDemoAudioBuffer()
    private var localDemoPlaybackTask: Task<Void, Never>?
    private var localDemoGeneration: UInt64 = 0
    private let localDemoPlayback: (@MainActor (Data) -> Void)?
    private let localDemoAnnouncement: @MainActor () -> [Data]

    // MARK: - Private State

    private var audioSocket: BoundUDPSocket?
    private var controlSocket: BoundUDPSocket?
    private var proxySession: EchoLinkProxySession?
    private var relayClient: EchoLinkRelayClient?
    private var outboundConnectionAttemptID: UUID?
    private let audioEngine: AudioEngine
    @Published private(set) var transmitCodec: EchoLinkVoiceCodec = .gsm
    private var activeTransmitCodec: EchoLinkVoiceCodec = .gsm
    private let mutedActivityCodec = GSMCodec()
    private var cancellables = Set<AnyCancellable>()
    private var keepAliveTask: Task<Void, Never>?
    private var peerTimeoutTask: Task<Void, Never>?
    private var captureStartTask: Task<Void, Never>?
    private var capturePreparationTask: Task<Void, Never>?
    private var captureStopTask: Task<Void, Never>?
    private var dtmfTask: Task<Void, Never>?
    private var dtmfGeneration: UInt64 = 0
    private var captureStopGeneration: UInt64 = 0
    private var desiredPTTActive = false
    private var audioSendDrainTask: Task<Void, Never>?
    private var audioSendDrainGeneration: UInt64 = 0
    private var audioReceiveTask: Task<Void, Never>?
    private var controlReceiveTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "org.reverbqso.app", category: "EchoLinkConnection")
    private var pendingOutgoingGSMPayload = Data()
    private var voicePacketsQueued = 0
    private var voicePacketsSent = 0
    private var audioDiagnosticsTotals = QSOAudioDiagnosticsSnapshot()
    private var audioDiagnosticsTXDropBaseline = 0

    /// Read only when the diagnostics view is visible; no per-packet UI updates.
    func audioDiagnosticsSnapshot() async -> QSOAudioDiagnosticsSnapshot {
        var snapshot = audioDiagnosticsTotals
        snapshot.sampledAt = ProcessInfo.processInfo.systemUptime
        snapshot.sessionID = session?.id
        snapshot.transport = isLocalDemoMode ? "Local demo"
            : proxySession != nil ? "Proxy" : relayClient != nil ? "Relay"
            : audioSocket != nil ? "Direct" : "—"
        snapshot.txCodec = (session?.isPTTActive == true ? activeTransmitCodec : transmitCodec) == .speex
            ? "Speex" : "GSM"
        snapshot.sequencedRXPackets = receiveReorderBuffer.deliveredSequencedPacketCount
        snapshot.missingRXPackets = receiveReorderBuffer.missingPacketCount
        snapshot.duplicateOrLateRXPackets = receiveReorderBuffer.duplicateOrLatePacketCount
        snapshot.txQueueDrops = max(0, queuedOutgoingAudioPackets.discardedCount - audioDiagnosticsTXDropBaseline)
        snapshot.txQueuedPackets = queuedOutgoingAudioPackets.count
        snapshot.rxQueuedPackets = receiveReorderBuffer.pendingPacketCount
        let playback = audioEngine.livePlaybackDiagnostics
        snapshot.playbackBufferedMilliseconds = playback.bufferedMilliseconds
        snapshot.startupBufferMilliseconds = playback.startupMilliseconds
        snapshot.playbackRXDrops = playback.droppedPackets
        snapshot.playbackRefills = playback.refills
        let transportMetrics: [LiveTransportMessageBufferMetrics]
        if let proxySession {
            let metrics = await proxySession.inboundAudioMetrics
            transportMetrics = Array(metrics.values)
        } else if let relayClient { transportMetrics = [await relayClient.inboundAudioMetrics] }
        else { transportMetrics = [] }
        snapshot.transportRXDrops = transportMetrics.reduce(0) {
            $0 + $1.capacityDroppedVoiceMessages + $1.ageDroppedVoiceMessages
        }
        return snapshot
    }

    private func resetAudioDiagnostics() {
        audioDiagnosticsTotals = QSOAudioDiagnosticsSnapshot()
        audioDiagnosticsTXDropBaseline = queuedOutgoingAudioPackets.discardedCount
        receiveReorderBuffer.reset()
    }

    private func recordReceivedAudio(codec: String, payloadBytes: Int) {
        audioDiagnosticsTotals.rxCodec = codec
        audioDiagnosticsTotals.rxPackets += 1
        audioDiagnosticsTotals.rxPayloadBytes += payloadBytes
    }
#if DEBUG
    var onAuditIncomingDatagram: (@MainActor (Data) -> Void)?
    var onAuditAcceptedPacket: (@MainActor (EchoLinkVoicePacketMetadata?) -> Void)?
    var onAuditOutgoingDatagramSent: (@MainActor () async -> Void)?
    var auditAudioSendDrainTask: Task<Void, Never>? { audioSendDrainTask }

    var auditTransportSnapshot: [String: Int] {
        ["queued": voicePacketsQueued, "sent": voicePacketsSent,
         "txDiscarded": queuedOutgoingAudioPackets.discardedCount,
         "rxDatagrams": incomingAudioDatagrams, "rxAccepted": incomingVoicePackets]
    }

    func auditInboundBufferSnapshot() async -> [String: [String: Double]] {
        let metrics: [String: LiveTransportMessageBufferMetrics]
        if let proxySession { metrics = await proxySession.inboundAudioMetrics }
        else if let relayClient { metrics = ["relay": await relayClient.inboundAudioMetrics] }
        else { metrics = [:] }
        return metrics.mapValues {
            ["acceptedVoice": Double($0.acceptedVoiceMessages),
             "capacityDrops": Double($0.capacityDroppedVoiceMessages),
             "ageDrops": Double($0.ageDroppedVoiceMessages),
             "maximumWaitSeconds": $0.maximumObservedVoiceWaitAgeSeconds,
             "queuedVoice": Double($0.queuedVoiceMessages),
             "maximumQueuedVoice": Double($0.maximumQueuedVoiceMessages)]
        }
    }

    /// Explicit live-test seam: known PCM replaces the physical microphone,
    /// while the production packet builder, queue, transport and RX stay active.
    func beginEchoTestAuditTransmission(codec: EchoLinkVoiceCodec) -> Bool {
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1",
              var current = session, current.state == .connected,
              current.station.callsign.uppercased() == "*ECHOTEST*",
              !isRemoteTransmitting, !current.isPTTActive,
              codec == .gsm || transmitCodec == .speex else { return false }
        activeTransmitCodec = codec
        pendingOutgoingGSMPayload.removeAll()
        voicePacketsQueued = 0
        voicePacketsSent = 0
        current.isPTTActive = true
        session = current
        return true
    }

    func endEchoTestAuditTransmission() async {
        guard ProcessInfo.processInfo.environment["ECHOLINK_RUN_AUDIO_AUDIT"] == "1" else { return }
        for _ in 0..<100 {
            if audioSendDrainTask == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if var current = session {
            current.isPTTActive = false
            session = current
        }
    }
#endif
    private var incomingAudioDatagrams = 0
    private var incomingVoicePackets = 0
    private var logNextVoiceAfterPTT = false
    private var queuedOutgoingAudioPackets = VoiceTransmitQueue<OutgoingAudioPacket>()
    private var hasLoggedUnsupportedSpeex = false
    private var loggedUnsupportedPayloadTypes: Set<UInt8> = []
    private var participantsByCallsign: [String: ActiveNodeParticipant] = [:]
    private var txDecayTasks: [String: Task<Void, Never>] = [:]
    private var receiveSequencer = EchoLinkReceiveSequencer()
    private var receiveReorderBuffer = EchoLinkAudioReorderBuffer()
    // Validate wire framing before committing sequence state. This decoder is
    // independent of the playback decoder, which consumes reordered packets.
    private let receiveSpeexValidator = SpeexCodec()
    private var receiveReorderTask: Task<Void, Never>?
    private let remoteVoiceActivityHold: Duration
    var effectiveTransportProvider: (@MainActor () -> EchoLinkEffectiveTransport?)?
    private let relayClientFactory: @MainActor () -> EchoLinkRelayClient
    private let selectedRelayClientFactory: @MainActor (String) -> EchoLinkRelayClient
    private let networkConfigurationProvider: @MainActor () -> EchoLinkProxyConfiguration
    private var remoteVoiceActivityTask: Task<Void, Never>?
    private var reconnectGeneration: UInt64 = 0
    private var lastRemoteChatBody: String?
    private var lastRemoteChatAt: Date?

    private var rtpSequence: UInt16 = UInt16.random(in: 0...UInt16.max)
    /// Running RTP timestamp in 8 kHz sample ticks. Starts at a random offset
    /// per RFC 3550 §5.1 so that jitter buffers on receiving nodes can correctly
    /// schedule playout. Incremented by the number of PCM samples in each packet.
    private var rtpTimestamp: UInt32 = UInt32.random(in: 0...UInt32.max)

    private static let audioPort: UInt16 = 5198
    private static let controlPort: UInt16 = 5199
    // Retry early packet loss at 1 and 3 seconds, retaining the original
    // 10-second retries and total 50-second (20-second relay) wait budget.
    private static let handshakeRetryIntervals: [Duration] = [.seconds(1), .seconds(2), .seconds(7), .seconds(10), .seconds(10), .seconds(10), .seconds(10)]
    private static let relayHandshakeRetryIntervals: [Duration] = [.seconds(1), .seconds(2), .seconds(7), .seconds(10)]
    private var handshakeWaiter: (sessionID: UUID, id: UUID, continuation: CheckedContinuation<Bool, Error>)?
    private static let keepAliveInterval = Duration.seconds(10)
    private static let peerTimeoutInterval = Duration.seconds(50)

    var localCallsign: String {
        if isLocalDemoMode { return localDemoCallsign }
        return authenticatedCallsign ?? KeychainService.loadCallsign() ?? "UNKNOWN"
    }

    // MARK: - Initialization

    private var hasTransmitPermission: Bool {
        !isBackgroundMuted && (pttPermission?() ?? true)
    }

    var canTransmit: Bool {
        let baseReady = session?.state == .connected && !isRemoteTransmitting && !isSendingDTMF
            && hasTransmitPermission
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        return baseReady && isCaptureReady && !audioEngine.isPreparingCapture
#else
        return baseReady
#endif
    }

    var hasAudioFocus: Bool { !isBackgroundMuted }

    var canSendRemoteDTMF: Bool {
        guard let session else { return false }
        return session.state == .connected
            && hasTransmitPermission
            && (session.station.type == .link || session.station.type == .repeater)
            && remotePadAllowed
            && !isRemoteTransmitting
            && !session.isPTTActive
            && captureStartTask == nil
            && captureStopTask == nil
            && !isSendingDTMF
    }

    init(
        remoteVoiceActivityHold: Duration = .milliseconds(600),
        relayClientFactory: @escaping @MainActor () -> EchoLinkRelayClient = { EchoLinkRelayClient() },
        selectedRelayClientFactory: @escaping @MainActor (String) -> EchoLinkRelayClient = {
            EchoLinkRelayClient(host: $0, resolvedIPv4Candidates: [$0])
        },
        networkConfigurationProvider: @escaping @MainActor () -> EchoLinkProxyConfiguration = { EchoLinkProxyConfiguration.load() },
        localDemoPlayback: (@MainActor (Data) -> Void)? = nil,
        localDemoAnnouncement: @escaping @MainActor () -> [Data] = { LocalDemoAnnouncement.echoTestPackets() },
        audioEngine injectedAudioEngine: AudioEngine? = nil,
        recordingDefaults: UserDefaults = .standard,
        recordingFolder: URL? = nil
    ) {
        self.audioEngine = injectedAudioEngine ?? AudioEngine()
        self.recordingDefaults = recordingDefaults
        self.recordingFolder = recordingFolder
        self.remoteVoiceActivityHold = remoteVoiceActivityHold
        self.relayClientFactory = relayClientFactory
        self.selectedRelayClientFactory = selectedRelayClientFactory
        self.networkConfigurationProvider = networkConfigurationProvider
        self.localDemoPlayback = localDemoPlayback
        self.localDemoAnnouncement = localDemoAnnouncement
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recordingCoordinator?.refreshAutomaticRecording()
                self?.publishRecordingState()
            }
            .store(in: &cancellables)
        audioEngine.$inputLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$inputLevel)
        audioEngine.$outputLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$outputLevel)
        audioEngine.$outputRouteName
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioOutputRouteName)
        audioEngine.onCaptureStreamReset = { [weak self] in
            self?.pendingOutgoingGSMPayload.removeAll(keepingCapacity: true)
        }
        audioEngine.onCaptureSuspended = { [weak self] in
            guard let self, self.session?.isPTTActive == true else { return }
            self.sendPTT(active: false)
        }
        audioEngine.$outputPreference
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioOutputPreference)
        audioEngine.$availableInputDevices.assign(to: &$audioInputDevices)
        audioEngine.$selectedInputDeviceID.assign(to: &$selectedAudioInputDeviceID)
        audioEngine.$isCaptureReady
            .combineLatest(audioEngine.$isPreparingCapture)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let ready = state.0 && !state.1
                self.isCaptureReady = ready
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
                guard self.session?.state == .connected, !self.isBackgroundMuted,
                      self.audioEngine.isRunning else { return }
                if ready {
                    if self.audioStatusMessage?.hasPrefix("Preparing microphone") == true
                        || self.audioStatusMessage?.hasPrefix("Microphone input is unavailable") == true {
                        self.audioStatusMessage = nil
                    }
                } else {
                    self.audioStatusMessage = "Preparing microphone for PTT. Receive audio is available."
                    if self.session?.isPTTActive == true {
                        self.sendPTT(active: false)
                    }
                }
#endif
            }
            .store(in: &cancellables)
        audioEngine.$capturePreparationFailed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failed in
                guard let self, failed, self.session?.state == .connected, !self.isBackgroundMuted,
                      self.audioEngine.isRunning else { return }
                self.audioStatusMessage = "Microphone input is unavailable. Receive audio is available."
            }
            .store(in: &cancellables)
    }

    func setAudioOutputPreference(_ preference: AudioOutputPreference) {
        setWatchAudioOutput(false)
        audioEngine.setOutputPreference(preference)
    }

    func setAudioInputDevice(id: String?) { audioEngine.setInputDevice(id: id) }

    func setWatchAudioAvailability(_ available: Bool) {
        watchAudioOutputAvailable = available
        if !available { setWatchAudioOutput(false) }
    }

    func setWatchAudioOutput(_ selected: Bool) {
        usesWatchAudioOutput = selected && watchAudioOutputAvailable && onReceivedVoicePacket != nil
        audioEngine.setReceiveOutputMuted(usesWatchAudioOutput)
    }

    private func forwardReceiveToWatch(_ data: Data, session: QSOSession) -> Bool {
        guard usesWatchAudioOutput, watchAudioOutputAvailable, !session.isMuted,
              !isBackgroundMuted, let onReceivedVoicePacket else { return false }
        onReceivedVoicePacket(data)
        return true
    }

    func prepareMicrophoneAfterPermissionGrant() {
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        guard MicrophoneAccess.status == .granted else { return }
        // Reuse session-bound preparation so disconnect cancels the work and
        // an old permission response cannot update a subsequent QSO.
        beginCapturePreparationIfNeeded()
#endif
    }

    func setBackgroundMuted(_ muted: Bool) {
        if muted && session?.isPTTActive == true { sendPTT(active: false) }
        guard isBackgroundMuted != muted else { return }
        isBackgroundMuted = muted
        if muted {
            dtmfGeneration &+= 1
            dtmfTask?.cancel()
            dtmfTask = nil
            isSendingDTMF = false
            if isLocalDemoMode {
                cancelLocalDemoPlayback()
                localDemoAudio.clear()
                audioEngine.stopAll()
            }
        }
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        capturePreparationTask?.cancel()
        capturePreparationTask = nil
        if muted {
            audioEngine.stopAll()
        } else if session?.state == .connected {
            resumeAudioWhenApplicationActive()
        }
#endif
        objectWillChange.send()
    }

    // MARK: - Public API

    @discardableResult
    func enableLocalDemo(callsign: String) -> Bool {
        guard session == nil else { return false }
        let normalized = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized == "DEMO" || normalized == "DEMO2" else { return false }
        cancelLocalDemoPlayback()
        localDemoAudio.clear()
        reconnectCandidate = nil
        localDemoCallsign = normalized
        isLocalDemoMode = true
        error = nil
        return true
    }

    @discardableResult
    func disableLocalDemo() -> Bool {
        guard session == nil else { return false }
        cancelLocalDemoPlayback()
        localDemoAudio.clear()
        isLocalDemoMode = false
        localDemoCallsign = "DEMO"
        return true
    }

    /// Connect to a remote EchoLink station.
    func connect(to station: Station, preservingEndpoint: Bool = false) async {
#if os(iOS) && !targetEnvironment(macCatalyst)
        // Service entry points include manual reconnect, which bypasses AppState.
        // Capture the previous session so an expired rejected attempt cannot end it.
        let previousSessionID = session?.id
        let operation = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await performConnect(to: station, preservingEndpoint: preservingEndpoint)
        }
        let lifetime = ConnectionAttemptLifetime {
            operation.cancel()
            guard self.session?.id != previousSessionID else { return }
            self.cancelPendingConnection()
            self.error = ConnectionError.connectionFailed(
                "iOS ended background execution. Open ReverbQSO and try again."
            )
        }
        lifetime.beginApplicationTask(name: "EchoLink peer handshake")
        defer { lifetime.end() }
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
#else
        await performConnect(to: station, preservingEndpoint: preservingEndpoint)
#endif
    }

    private func performConnect(to station: Station, preservingEndpoint: Bool) async {
        guard !Task.isCancelled else { return }
        let resolvedStation = (isLocalDemoMode || preservingEndpoint) ? station : (resolveStation?(station) ?? station)
        let accessPolicy = callAccessPolicyProvider?() ?? CallAccessPolicyStore.load(demo: isLocalDemoMode)
        if let reason = accessPolicy.rejection(for: resolvedStation, direction: .outgoing, countryCode: resolvedStation.callSignCountryCode) {
            error = ConnectionError.connectionFailed(reason)
            return
        }
        if isLocalDemoMode {
            connectLocalDemo(to: resolvedStation)
            return
        }
        guard isConferenceHostActive?() != true else {
            error = ConnectionError.connectionFailed("Stop conference hosting before joining another station.")
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            guard session == nil else { return }
            installSimulatorDemoSession(station: resolvedStation)
            return
        }
#endif
        guard session == nil else {
            error = ConnectionError.alreadyConnected
            return
        }

        let station = resolvedStation
        logger.info("Connecting station=\(station.callsign, privacy: .public) host=\(station.ipAddress, privacy: .public) as=\(self.localCallsign, privacy: .public)")
        let newSession = QSOSession(station: station)
        resetAudioDiagnostics()
        let sessionID = newSession.id
        session = newSession
        outboundConnectionAttemptID = sessionID
        defer {
            if outboundConnectionAttemptID == sessionID { outboundConnectionAttemptID = nil }
        }
        error = nil
        audioStatusMessage = nil
        remotePadAllowed = false
        transmitCodec = .gsm
        activeTransmitCodec = .gsm
        isSendingDTMF = false
        lastRemoteChatBody = nil
        lastRemoteChatAt = nil
        resetActiveParticipants(for: station)
        receiveSequencer.reset()

        do {
            // Reset codec state for a fresh session.
            audioEngine.resetCodecState()
            pendingOutgoingGSMPayload.removeAll(keepingCapacity: true)
            rtpSequence = UInt16.random(in: 0...UInt16.max)
            rtpTimestamp = UInt32.random(in: 0...UInt32.max)

            let selection = effectiveTransportProvider?()
            let storedProxyConfiguration = selection?.configuration ?? networkConfigurationProvider()
            guard storedProxyConfiguration.mode != .automatic else {
                throw ConnectionError.connectionFailed("Sign in again to select an Automatic connection method.")
            }
            try Task.checkCancellation()
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            // Prepare real receive audio before the first network suspension, while
            // a foreground-initiated call can still activate its audio session.
            if !isBackgroundMuted {
                audioEngine.startPlayback()
            }
#endif
            if storedProxyConfiguration.mode == .relay {
                let client: EchoLinkRelayClient
                if let address = selection?.relayAddress {
                    client = selectedRelayClientFactory(address)
                } else {
                    client = relayClientFactory()
                }
                let stream = try await client.connect(callsign: localCallsign)
                do {
                    try requireCurrentSession(sessionID)
                } catch {
                    await client.close()
                    throw error
                }
                relayClient = client
                startRelayReceiveLoop(stream: stream, client: client, sessionID: sessionID)
                if let prepareRelayDirectory {
                    guard let relayAddress = await client.selectedRelayAddress() else {
                        throw ConnectionError.connectionFailed("EchoLink Relay did not select an address.")
                    }
                    relayDirectoryAddress = relayAddress
                    try await prepareRelayDirectory(localCallsign, relayAddress)
                    try requireCurrentSession(sessionID)
                }
                logger.info("EchoLink Relay registered")
            } else if storedProxyConfiguration.isEnabled {
                guard let resolveProxySession else {
                    throw ConnectionError.connectionFailed("EchoLink Proxy directory session is unavailable.")
                }
                guard let sharedSession = try await resolveProxySession(localCallsign) else {
                    throw ConnectionError.connectionFailed("EchoLink Proxy directory session is unavailable.")
                }
                try requireCurrentSession(sessionID)
                proxySession = sharedSession
                startProxyReceiveLoop(proxySession: sharedSession, sessionID: sessionID)
                let selectedConfiguration = sharedSession.configuration
                logger.info("EchoLink Proxy tunnel connected host=\(selectedConfiguration.host, privacy: .public) port=\(selectedConfiguration.port)")
            } else {
                // EchoLink peers require these exact source ports. NWConnection may
                // silently choose ephemeral ports, so use two bound datagram sockets.
                if let reserved = consumeReservedDirectSockets?(),
                   let sockets = reserved.takeSockets() {
                    audioSocket = sockets.audio
                    controlSocket = sockets.control
                } else {
                    audioSocket = try BoundUDPSocket(localPort: Self.audioPort)
                    try requireCurrentSession(sessionID)
                    controlSocket = try BoundUDPSocket(localPort: Self.controlPort)
                }
                try requireCurrentSession(sessionID)
                logger.debug("UDP sockets bound localAudio=5198 localControl=5199")

                // Arm receive loops before sending SDES so a fast peer response cannot be missed.
                startControlReceiveLoop(sessionID: sessionID)
                startAudioReceiveLoop(sessionID: sessionID)
            }

            // A local UDP send is not a successful EchoLink connection. Retry the
            // handshake and remain in .connecting until the peer returns SDES.
            do {
                try await awaitRemoteHandshakeAcknowledgement(
                    sessionID: sessionID,
                    retryIntervals: storedProxyConfiguration.mode == .relay ? Self.relayHandshakeRetryIntervals : Self.handshakeRetryIntervals
                )
            } catch ConnectionError.handshakeTimedOut where storedProxyConfiguration.mode == .relay {
                throw ConnectionError.connectionFailed(
                    "Relay could not complete the call. Try Public Proxy in Settings."
                )
            }
            try requireCurrentSession(sessionID)

            audioEngine.onCapturedAudio = { [weak self] encodedData in
                self?.enqueueCapturedAudio(encodedData)
            }
            if !isBackgroundMuted {
                audioEngine.startPlayback()
            }
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            if !isBackgroundMuted {
                if audioEngine.isRunning {
                    beginCapturePreparationIfNeeded(sessionID: sessionID)
                } else {
                    audioStatusMessage = "Open ReverbQSO to enable audio."
                }
            }
#endif
            startKeepAlive(sessionID: sessionID)
            reconnectCandidate = nil

            logger.info("EchoLink connection established station=\(station.callsign, privacy: .public)")
        } catch is CancellationError {
            guard session?.id == sessionID else { return }
            tearDown(expectedSessionID: sessionID)
            session = nil
        } catch {
            guard session?.id == sessionID else { return }
            guard session?.state != .disconnecting,
                  session?.state != .disconnected else { return }
            logger.error(
                "EchoLink connection failed station=\(station.callsign, privacy: .public) error='\(error.localizedDescription, privacy: .public)'"
            )
            if self.error == nil {
                self.error = error
            }
            registerReconnectCandidate(station)
            if var failedSession = session {
                failedSession.state = .disconnected
                session = failedSession
            }
            tearDown(expectedSessionID: sessionID)
            if session?.id == sessionID {
                session = nil
            }
        }
    }

#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
    private func beginCapturePreparationIfNeeded(sessionID: UUID? = nil) {
        guard !isBackgroundMuted,
              let currentSessionID = sessionID ?? session?.id,
              session?.state == .connected,
              capturePreparationTask == nil else { return }
        audioStatusMessage = "Preparing microphone for PTT. Receive audio is available."
        capturePreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await self.audioEngine.prepareCaptureInput(requestPermission: false)
            guard !Task.isCancelled,
                  !self.isBackgroundMuted,
                  self.session?.id == currentSessionID else { return }
            self.audioStatusMessage = ready ? nil : "Microphone input is unavailable. Receive audio is available."
            self.capturePreparationTask = nil
        }
    }
#endif

    /// Retry an audio activation denied while the app was executing in background.
    func resumeAudioWhenApplicationActive() {
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        guard session?.state == .connected, !isBackgroundMuted, !audioEngine.isRunning else { return }
        audioEngine.startPlayback()
        guard audioEngine.isRunning else {
            audioStatusMessage = "Open ReverbQSO to enable audio."
            return
        }
        audioStatusMessage = nil
        beginCapturePreparationIfNeeded()
#endif
    }

    /// Synchronous cleanup is required in UIKit's background expiration handler.
    func cancelPendingConnection() {
        guard let pending = session,
              pending.state == .connecting || outboundConnectionAttemptID == pending.id else { return }
        tearDown(expectedSessionID: pending.id)
        session = nil
    }

    /// Disconnect from the current station.
    func disconnect() async {
        if isLocalDemoMode {
            let ended = session
            reconnectGeneration &+= 1
            reconnectCandidate = nil
            tearDown()
            session = nil
            if let ended, ended.state == .connected {
                onSessionEnded?(ended.station, Date().timeIntervalSince(ended.startTime))
            }
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            session = nil
            incomingChatMessages = []
            activeNodeParticipants = []
            isRemoteTransmitting = false
            return
        }
#endif
        reconnectGeneration &+= 1
        reconnectCandidate = nil
        guard var currentSession = session else {
            tearDown()
            session = nil
            return
        }

        let wasConnected = currentSession.state == .connected
        let sessionID = currentSession.id
        let startTime = currentSession.startTime
        let station = currentSession.station

        currentSession.isPTTActive = false
        currentSession.state = .disconnecting
        session = currentSession

        // Send RTCP BYE on control port
        let byePacket = buildBYEPacket()
        try? await sendControl(data: byePacket)
        guard session?.id == sessionID else { return }

        tearDown(expectedSessionID: sessionID)

        currentSession.isPTTActive = false
        currentSession.state = .disconnected
        session = currentSession

        // Compute duration and notify
        if wasConnected {
            let duration = Date().timeIntervalSince(startTime)
            onSessionEnded?(station, duration)
        }

        // Clear session after a brief moment
        try? await Task.sleep(for: .milliseconds(500))
        if session?.id == sessionID {
            session = nil
        }
    }

    /// Retries a failed QSO once after the app refreshes the directory and
    /// resolves the same station identity to its current endpoint.
    func reconnect() async {
        if isLocalDemoMode {
            if session?.state == .disconnected { tearDown(); session = nil }
            guard let candidate = reconnectCandidate else { error = ConnectionError.notConnected; return }
            await connect(to: candidate)
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            if let reconnectCandidate { installSimulatorDemoSession(station: reconnectCandidate) }
            return
        }
#endif
        guard !isReconnecting else { return }
        if let currentSession = session {
            guard currentSession.state == .disconnected else {
                error = ConnectionError.alreadyConnected
                return
            }
            // Unexpected termination has already torn down transport state.
            // Retire its brief presentation-only session before the fresh lookup.
            session = nil
        }
        guard let candidate = reconnectCandidate else {
            error = ConnectionError.notConnected
            return
        }

        isReconnecting = true
        error = nil
        let generation = reconnectGeneration
        defer { isReconnecting = false }
        do {
            guard let currentStation = try await resolveReconnectStation?(candidate) else {
                error = ConnectionError.connectionFailed(
                    "\(candidate.callsign) is not available in the current EchoLink directory."
                )
                return
            }
            guard generation == reconnectGeneration,
                  reconnectCandidate != nil else { return }
            await connect(to: currentStation)
        } catch is CancellationError {
            return
        } catch {
            self.error = error
        }
    }

    /// Records a station only for failures that may be retried manually.
    /// User initiated disconnect always clears this state.
    func registerReconnectCandidate(_ station: Station) {
        reconnectCandidate = station
    }

    /// Set PTT (Push-To-Talk) active state.
    func sendPTT(active: Bool) {
        if active && (isBackgroundMuted || pttPermission?() == false) { return }
#if targetEnvironment(simulator)
        if isLocalDemoMode {
            sendLocalDemoSimulatorPTT(active: active)
            return
        }
#endif
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if !isLocalDemoMode && SimulatorDemoData.isEnabled {
            guard var demoSession = session else { return }
            demoSession.isPTTActive = active
            session = demoSession
            inputLevel = active ? 0.45 : 0
            return
        }
#endif
        if active {
            VoiceDiagnosticLog.reset()
        }
        VoiceDiagnosticLog.record(
            "PTT requested active=\(active) connected=\(session?.state == .connected) remoteTransmitting=\(isRemoteTransmitting)"
        )
        guard var currentSession = session, currentSession.state == .connected else {
            logger.warning("PTT ignored active=\(active) because no station is connected")
            return
        }
        logger.info("PTT requested active=\(active) station=\(currentSession.station.callsign, privacy: .public)")
        desiredPTTActive = active

        if active {
            if EchoLinkPTTTransition.shouldQueuePress(
                isPTTActive: currentSession.isPTTActive,
                releaseInProgress: captureStopTask != nil
            ) {
                // Keep the release drain alive. It will restart capture after it
                // finishes because desiredPTTActive is already true.
                return
            }
            guard canTransmit else {
                desiredPTTActive = false
                logger.info("PTT ignored because remote voice is active")
                return
            }
            // A release already in progress must finish draining its captured tail.
            // desiredPTTActive queues this press for an immediate clean restart.
            guard !currentSession.isPTTActive else { return }
            captureStopGeneration &+= 1
            captureStopTask?.cancel()
            captureStopTask = nil
            let selectedCodec: EchoLinkVoiceCodec = !isLocalDemoMode && transmitCodec == .speex
                && audioEngine.isSpeexTransmitAvailable ? .speex : .gsm
            guard audioEngine.setTransmitCodec(selectedCodec) else {
                desiredPTTActive = false
                return
            }
            activeTransmitCodec = selectedCodec
            // A fresh PTT turn cannot sit behind the previous turn's tail.
            queuedOutgoingAudioPackets.removeAll(keepingCapacity: true)
            currentSession.isPTTActive = true
            session = currentSession
            if isLocalDemoMode { localDemoAudio.clear() }
            pendingOutgoingGSMPayload.removeAll(keepingCapacity: true)
            voicePacketsQueued = 0
            voicePacketsSent = 0
            let sessionID = currentSession.id
            let startGeneration = captureStopGeneration
            captureStartTask?.cancel()
            captureStartTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.captureStopGeneration == startGeneration,
                       self.session?.id == sessionID {
                        self.captureStartTask = nil
                    }
                }
                guard !Task.isCancelled,
                      self.session?.id == sessionID,
                      self.session?.state == .connected,
                      self.session?.isPTTActive == true else { return }
                let started = await self.audioEngine.startCapture()
                VoiceDiagnosticLog.record("capture start completed success=\(started)")
                guard !Task.isCancelled,
                      self.session?.id == sessionID,
                      self.session?.state == .connected,
                      self.session?.isPTTActive == true else { return }
                guard started else {
                    self.audioEngine.stopCapture()
                    self.desiredPTTActive = false
                    if var failedSession = self.session, failedSession.id == sessionID {
                        failedSession.isPTTActive = false
                        self.session = failedSession
                    }
                    self.audioStatusMessage = "Microphone input is unavailable."
                    return
                }
                self.audioStatusMessage = nil
            }
        } else {
            guard currentSession.isPTTActive, captureStopTask == nil else { return }
            logNextVoiceAfterPTT = true
            audioEngine.beginRXWindowAfterPTT()
            let datagramsAtRelease = incomingAudioDatagrams
            let voiceAtRelease = incomingVoicePackets
            let releasedSessionID = currentSession.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.session?.id == releasedSessionID else { return }
                self.audioEngine.finishRXWindowAfterPTT()
                self.logger.info("RX after PTT datagrams=\(self.incomingAudioDatagrams - datagramsAtRelease) voice=\(self.incomingVoicePackets - voiceAtRelease) playbackRunning=\(self.audioEngine.isRunning) outputLevel=\(self.audioEngine.outputLevel)")
            }
            captureStartTask?.cancel()
            captureStartTask = nil
            captureStopGeneration &+= 1
            let stopGeneration = captureStopGeneration
            let sessionID = currentSession.id
            captureStopTask?.cancel()
            captureStopTask = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.audioEngine.stopCaptureAndFlushPendingBuffers()
                VoiceDiagnosticLog.record(
                    "PTT capture stopped queued=\(self.voicePacketsQueued) sent=\(self.voicePacketsSent) pending=\(self.queuedOutgoingAudioPackets.count) remainder=\(self.pendingOutgoingGSMPayload.count)"
                )
                self.logger.info("PTT transport queued=\(self.voicePacketsQueued) sent=\(self.voicePacketsSent) pending=\(self.queuedOutgoingAudioPackets.count)")
                guard !Task.isCancelled,
                      self.captureStopGeneration == stopGeneration,
                      var stoppedSession = self.session,
                      stoppedSession.id == sessionID else { return }

                stoppedSession.isPTTActive = false
                self.session = stoppedSession
                if !self.pendingOutgoingGSMPayload.isEmpty {
                    self.logger.error(
                        "PTT flush left an incomplete GSM packet bytes=\(self.pendingOutgoingGSMPayload.count)"
                    )
                    self.pendingOutgoingGSMPayload.removeAll(keepingCapacity: true)
                }
                self.captureStopTask = nil
                if self.desiredPTTActive {
                    self.sendPTT(active: true)
                } else if self.isLocalDemoMode {
                    self.startLocalDemoPlayback(self.localDemoAudio.takePackets(), sessionID: sessionID)
                }
            }
        }
    }

    /// Sends remote-pad digits as in-band GSM voice only when the peer
    /// advertises D1 permission in RTCP SDES. One 80 ms packet is sent at a
    /// time through the same RTP sequence and send queue used by microphone TX.
    func sendRemoteDTMF(_ digits: String) {
        if isLocalDemoMode {
            guard canSendRemoteDTMF, let sessionID = session?.id else { return }
            do {
                let samples = try EchoLinkDTMFToneGenerator.generate(digits)
                guard !samples.isEmpty else { return }
                var payload = GSMCodec.stripHeader(GSMCodec().encode(samples)) ?? Data()
                let packets = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &payload)
                startLocalDemoPlayback(packets, sessionID: sessionID, isDTMF: true)
            } catch {
                audioStatusMessage = "Enter up to 32 DTMF digits (0–9, A–D, * or #)."
            }
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            guard canSendRemoteDTMF else { return }
            isSendingDTMF = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.isSendingDTMF = false
            }
            return
        }
#endif
        guard canSendRemoteDTMF, let currentSession = session else {
            audioStatusMessage = "The remote pad is unavailable while this station is receiving or transmitting."
            return
        }
        let samples: [Int16]
        do {
            samples = try EchoLinkDTMFToneGenerator.generate(digits)
        } catch {
            audioStatusMessage = "Enter up to 32 DTMF digits (0–9, A–D, * or #)."
            return
        }
        guard !samples.isEmpty else { return }
        let sessionID = currentSession.id
        let remoteHost = currentSession.station.ipAddress
        dtmfGeneration &+= 1
        let generation = dtmfGeneration
        isSendingDTMF = true
        audioStatusMessage = nil
        dtmfTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.dtmfGeneration == generation {
                    self.isSendingDTMF = false
                    self.dtmfTask = nil
                }
            }
            // Finish the microphone's queued tail before starting the tone
            // sequence. Both paths then use the same ordered RTP send queue.
            for _ in 0..<100 {
                guard self.audioSendDrainTask != nil else { break }
                guard !Task.isCancelled, self.session?.id == sessionID,
                      !self.isRemoteTransmitting, self.hasTransmitPermission else { return }
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return }
            }
            guard self.audioSendDrainTask == nil else {
                self.audioStatusMessage = "Wait for the previous transmission to finish."
                return
            }
            let codec = GSMCodec()
            let packetSamples = EchoLinkDTMFToneGenerator.toneSampleCount
            for start in stride(from: 0, to: samples.count, by: packetSamples) {
                guard !Task.isCancelled,
                      self.session?.id == sessionID,
                      self.session?.state == .connected,
                      !self.isRemoteTransmitting, self.hasTransmitPermission else { break }
                let block = Array(samples[start..<(start + packetSamples)])
                guard let payload = GSMCodec.stripHeader(codec.encode(block)),
                      payload.count == 4 * GSMCodec.encodedFrameSize else {
                    self.audioStatusMessage = "Could not encode DTMF audio."
                    break
                }
                self.enqueueVoicePayload(payload, sessionID: sessionID, remoteHost: remoteHost)
                do {
                    try await Task.sleep(for: .milliseconds(80))
                } catch {
                    break
                }
            }
        }
    }

    private func connectLocalDemo(to station: Station) {
        guard session == nil else { error = ConnectionError.alreadyConnected; return }
        guard let fixture = LocalDemoAccount.stations.first(where: { $0.callsign == station.callsign }) else {
            error = ConnectionError.connectionFailed("Choose a station from this account's station list.")
            return
        }
        cancelLocalDemoPlayback()
        resetAudioDiagnostics()
        localDemoAudio.clear()
        audioEngine.resetCodecState()
        let messages = LocalDemoAccount.messages(for: fixture, account: localCallsign)
        session = QSOSession(station: fixture, state: .connected,
            sysopInfo: messages.first(where: \.isInformational)?.body ?? fixture.description)
        incomingChatMessages = messages
        activeNodeParticipants = LocalDemoAccount.participants
        remotePadAllowed = fixture.type == .link || fixture.type == .repeater
        reconnectCandidate = nil
        error = nil
        audioStatusMessage = nil
        audioEngine.onCapturedAudio = { [weak self] in self?.enqueueCapturedAudio($0) }
        if !isBackgroundMuted {
            if localDemoPlayback == nil { audioEngine.startPlayback() }
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            beginCapturePreparationIfNeeded()
#endif
        }
        if fixture.callsign == "*ECHOTEST*", let sessionID = session?.id {
            let announcement = localDemoAnnouncement()
            if !announcement.isEmpty {
                startLocalDemoPlayback(announcement, sessionID: sessionID, initialDelay: .milliseconds(500))
            }
        }
    }

    private func cancelLocalDemoPlayback() {
        localDemoGeneration &+= 1
        localDemoPlaybackTask?.cancel()
        localDemoPlaybackTask = nil
        if isLocalDemoMode {
            isRemoteTransmitting = false
            isSendingDTMF = false
            activeNodeParticipants = activeNodeParticipants.map { participant in
                var idle = participant
                idle.isTransmitting = false
                return idle
            }
        }
    }

    private func startLocalDemoPlayback(_ packets: [Data], sessionID: UUID, isDTMF: Bool = false, initialDelay: Duration = .zero) {
        cancelLocalDemoPlayback()
        guard !packets.isEmpty, session?.id == sessionID, hasTransmitPermission else {
            if packets.isEmpty { audioStatusMessage = "No microphone audio was recorded. Check microphone access and try PTT again." }
            return
        }
        let generation = localDemoGeneration
        isRemoteTransmitting = true
        isSendingDTMF = isDTMF
        audioStatusMessage = nil
        localDemoPlaybackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.localDemoGeneration == generation, self.session?.id == sessionID {
                    self.isRemoteTransmitting = false
                    self.isSendingDTMF = false
                    self.localDemoPlaybackTask = nil
                }
            }
            do { try await Task.sleep(for: initialDelay) } catch { return }
#if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            // Initial microphone preparation can rebuild the audio graph.
            // Finish it before scheduling the greeting, so it cannot erase RX.
            if initialDelay > .zero, let preparation = self.capturePreparationTask {
                await preparation.value
            }
#endif
            let clock = ContinuousClock()
            let started = clock.now
            for (index, packet) in packets.enumerated() {
                guard !Task.isCancelled, self.localDemoGeneration == generation,
                      self.session?.id == sessionID, self.session?.state == .connected,
                      self.hasTransmitPermission else { return }
                if let current = self.session, !current.isMuted {
                    if self.forwardReceiveToWatch(packet, session: current) {
                        let samples = self.mutedActivityCodec.decodePacket(packet)
                        self.appendRecordingPCM(samples)
                        self.audioEngine.recordOutputLevel(from: samples)
                    } else if let playback = self.localDemoPlayback { playback(packet) }
                    else { self.audioEngine.playReceivedAudio(packet) }
                }
                do { try await clock.sleep(until: started.advanced(by: .milliseconds((index + 1) * 80))) }
                catch { return }
            }
        }
    }

#if targetEnvironment(simulator)
    private func sendLocalDemoSimulatorPTT(active: Bool) {
        guard var current = session, current.state == .connected else { return }
        if active {
            guard canTransmit, !current.isPTTActive else { return }
            localDemoAudio.clear()
            current.isPTTActive = true
            session = current
            // Simulator has no capture graph. A deterministic 400 ms tone
            // exercises the same GSM recording/playback path without a mic.
            let samples = (0..<(640 * 5)).map { index in
                Int16(8_000 * sin(2 * Double.pi * 440 * Double(index) / 8_000))
            }
            var payload = GSMCodec.stripHeader(GSMCodec().encode(samples)) ?? Data()
            for packet in EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(buffer: &payload) {
                localDemoAudio.append(packet)
            }
        } else {
            guard current.isPTTActive else { return }
            current.isPTTActive = false
            session = current
            startLocalDemoPlayback(localDemoAudio.takePackets(), sessionID: current.id)
        }
    }
#endif

#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
    func installSimulatorDemoSession(station: Station) {
        resetAudioDiagnostics()
        session = QSOSession(
            station: station,
            startTime: Date().addingTimeInterval(-384),
            state: .connected,
            sysopInfo: "\(station.callsign) demonstration node. This is a longer station description used to check wrapping on narrow displays.\nWeekly net at 19:00 local time. Visitors welcome."
        )
        incomingChatMessages = station.type == .conference
            ? SimulatorDemoData.messages
            : Array(SimulatorDemoData.messages.prefix(12))
        activeNodeParticipants = station.type == .conference
            ? SimulatorDemoData.participants
            : Array(SimulatorDemoData.participants.prefix(6))
        remotePadAllowed = station.type == .link || station.type == .repeater
        isRemoteTransmitting = SimulatorDemoData.isRemoteTalking
        audioStatusMessage = nil
        error = nil
    }
#endif

    /// Send a text chat message using NDATA format.
    /// EchoLink carries NDATA over the audio UDP path (5198).
    func sendChat(message: String) async {
        if isLocalDemoMode {
            guard let session, session.state == .connected else { return }
            incomingChatMessages.append(ChatMessage(sender: localCallsign, body: message, isOutgoing: true))
            incomingChatMessages.append(ChatMessage(sender: session.station.callsign, body: "Echo: \(message)"))
            return
        }
#if DEBUG && (os(iOS) || targetEnvironment(macCatalyst))
        if SimulatorDemoData.isEnabled {
            guard session?.state == .connected else { return }
            incomingChatMessages.append(ChatMessage(sender: SimulatorDemoData.callsign, body: message, isOutgoing: true))
            return
        }
#endif
        guard session?.state == .connected else { return }

        let ndataPacket = buildNDATAChatPacket(sender: localCallsign, message: message)
        do {
            try await sendNDATA(data: ndataPacket)

            let outgoing = ChatMessage(
                sender: localCallsign,
                body: message,
                isOutgoing: true
            )
            incomingChatMessages.append(outgoing)
        } catch {
            self.error = error
        }
    }

    /// Toggle mute state for the current session.
    func toggleMute() {
        guard var currentSession = session else { return }
        currentSession.isMuted.toggle()
        session = currentSession
    }

    func clearError() {
        error = nil
    }

    private func requireCurrentSession(_ sessionID: UUID) throws {
        try Task.checkCancellation()
        guard session?.id == sessionID else { throw CancellationError() }
    }

    private func awaitRemoteHandshakeAcknowledgement(
        sessionID: UUID,
        retryIntervals: [Duration] = handshakeRetryIntervals
    ) async throws {
        for (index, timeout) in retryIntervals.enumerated() {
            try Task.checkCancellation()
            try requireCurrentSession(sessionID)
            if session?.state == .connected { return }
            let sdes = buildSDESPacket(callsign: localCallsign)
            let info = EchoLinkControlPacketCodec.buildNDATAInfoPacket(
                message: "Station \(localCallsign)\r\n"
            )
            logger.debug("Sending EchoLink handshake attempt=\(index + 1)")
            try await sendControl(data: sdes)
            try await sendAudioPortControl(data: sdes)
            try await sendNDATA(data: info)

            if try await waitForHandshakeAcknowledgement(sessionID: sessionID, timeout: timeout) { return }
        }

        throw ConnectionError.handshakeTimedOut
    }

    private func waitForHandshakeAcknowledgement(sessionID: UUID, timeout: Duration) async throws -> Bool {
        try requireCurrentSession(sessionID)
        if session?.state == .connected { return true }
        guard session?.state == .connecting else { throw CancellationError() }
        let id = UUID()
        var deadlineTask: Task<Void, Never>?
        defer { deadlineTask?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                handshakeWaiter = (sessionID, id, continuation)
                deadlineTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.completeHandshakeWaiter(id: id, result: .success(false))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.completeHandshakeWaiter(id: id, result: .failure(CancellationError()))
            }
        }
    }

    private func completeHandshakeWaiter(id: UUID, result: Result<Bool, Error>) {
        guard let waiter = handshakeWaiter, waiter.id == id else { return }
        handshakeWaiter = nil
        waiter.continuation.resume(with: result)
    }

    // MARK: - Packet Builders

    /// Build an RTCP SDES packet for EchoLink handshake.
    private func buildSDESPacket(callsign: String) -> Data {
        EchoLinkControlPacketCodec.buildSDESPacket(
            callsign: callsign,
            includePadding: true,
            advertiseSpeex: audioEngine.isSpeexTransmitAvailable
        )
    }

    /// Build an RTCP BYE packet.
    private func buildBYEPacket() -> Data {
        EchoLinkControlPacketCodec.buildBYEPacket()
    }

    private func buildNDATAChatPacket(sender: String, message: String) -> Data {
        EchoLinkControlPacketCodec.buildNDATAChatPacket(sender: sender, message: message)
    }

    // MARK: - Send Helpers

    private func sendControl(data: Data) async throws {
        guard let host = session?.station.ipAddress else {
            throw ConnectionError.notConnected
        }
        if let proxySession {
            try await proxySession.sendControl(data, to: host)
        } else if let relayClient {
            try await relayClient.sendData(data, to: host, port: Self.controlPort)
        } else if let controlSocket {
            try await controlSocket.send(data, to: host, port: Self.controlPort)
        } else {
            throw ConnectionError.notConnected
        }
    }

    private func sendAudioPortControl(data: Data) async throws {
        guard let host = session?.station.ipAddress else {
            throw ConnectionError.notConnected
        }
        if let proxySession {
            try await proxySession.sendControl(data, to: host)
        } else if let relayClient {
            try await relayClient.sendData(data, to: host, port: Self.controlPort)
        } else if let audioSocket {
            try await audioSocket.send(data, to: host, port: Self.controlPort)
        } else {
            throw ConnectionError.notConnected
        }
    }

    private func sendNDATA(data: Data) async throws {
        guard let host = session?.station.ipAddress else {
            throw ConnectionError.notConnected
        }
        if let proxySession {
            try await proxySession.sendAudio(data, to: host)
        } else if let relayClient {
            try await relayClient.sendData(data, to: host, port: Self.audioPort)
        } else if let audioSocket {
            try await audioSocket.send(data, to: host, port: Self.audioPort)
        } else {
            throw ConnectionError.notConnected
        }
    }

    private func enqueueCapturedAudio(_ data: Data) {
        guard let currentSession = session,
              currentSession.state == .connected,
              currentSession.isPTTActive,
              (isLocalDemoMode || audioSocket != nil || proxySession != nil || relayClient != nil),
              (!isLocalDemoMode || hasTransmitPermission) else { return }

        if activeTransmitCodec == .speex {
            guard !data.isEmpty, data.count <= 512 else { return }
            enqueueVoicePayload(data, sessionID: currentSession.id,
                                remoteHost: currentSession.station.ipAddress, codec: .speex)
            return
        }
        guard let gsmPayload = GSMCodec.stripHeader(data), !gsmPayload.isEmpty else { return }

        pendingOutgoingGSMPayload.append(gsmPayload)
        let packetPayloads = EchoLinkAudioPacketCodec.consumeOutgoingGSMPayloadPackets(
            buffer: &pendingOutgoingGSMPayload
        )
        for payload in packetPayloads {
            if voicePacketsQueued == 0 {
                VoiceDiagnosticLog.record(
                    "first voice payload ready bytes=\(payload.count) bufferedRemainder=\(pendingOutgoingGSMPayload.count)"
                )
            }
            enqueueVoicePayload(payload, sessionID: currentSession.id, remoteHost: currentSession.station.ipAddress)
        }
    }

    private func enqueueVoicePayload(_ payload: Data, sessionID: UUID, remoteHost: String,
                                     codec: EchoLinkVoiceCodec = .gsm) {
        if isLocalDemoMode {
            guard session?.id == sessionID, hasTransmitPermission else { return }
            if !localDemoAudio.append(payload) {
                audioStatusMessage = "Recording reached 30 seconds. Release PTT to hear it."
            }
            return
        }
        let packet = EchoLinkAudioPacketCodec.buildLegacyVoicePacket(
            gsmPayload: payload,
            sequence: rtpSequence,
            timestamp: rtpTimestamp,
            codec: codec
        )
        rtpSequence &+= 1
        let samplesInPacket = codec == .speex ? SpeexCodec.samplesPerPacket
            : payload.count / GSMCodec.encodedFrameSize * GSMCodec.samplesPerFrame
        rtpTimestamp &+= UInt32(samplesInPacket)
        queuedOutgoingAudioPackets.enqueue(
            OutgoingAudioPacket(data: packet, sessionID: sessionID, remoteHost: remoteHost)
        )
        voicePacketsQueued += 1
        startAudioSendDrainIfNeeded()
    }

    private func startAudioSendDrainIfNeeded() {
        guard audioSendDrainTask == nil, !queuedOutgoingAudioPackets.isEmpty else { return }
        audioSendDrainGeneration &+= 1
        let generation = audioSendDrainGeneration
        audioSendDrainTask = Task { [weak self] in
            await self?.drainOutgoingAudioPackets(generation: generation)
        }
    }

    private func drainOutgoingAudioPackets(generation: UInt64) async {
        while !Task.isCancelled,
              audioSendDrainGeneration == generation,
              !queuedOutgoingAudioPackets.isEmpty {
            guard let queuedPacket = queuedOutgoingAudioPackets.dequeue() else { break }
            guard session?.id == queuedPacket.sessionID, hasTransmitPermission else { continue }
            do {
                if let proxySession {
                    try await proxySession.sendAudio(queuedPacket.data, to: queuedPacket.remoteHost)
                } else if let relayClient {
                    try await relayClient.sendData(queuedPacket.data, to: queuedPacket.remoteHost, port: Self.audioPort)
                } else if let audioSocket {
                    try await audioSocket.send(
                        queuedPacket.data,
                        to: queuedPacket.remoteHost,
                        port: Self.audioPort
                    )
                } else {
                    throw ConnectionError.notConnected
                }
#if DEBUG
                if let observer = onAuditOutgoingDatagramSent { await observer() }
#endif
                guard !Task.isCancelled,
                      audioSendDrainGeneration == generation,
                      session?.id == queuedPacket.sessionID else { return }
                voicePacketsSent += 1
                audioDiagnosticsTotals.txPackets += 1
                audioDiagnosticsTotals.txPayloadBytes += max(0, queuedPacket.data.count - EchoLinkAudioPacketCodec.legacyVoiceHeaderLength)
                if voicePacketsSent == 1 {
                    VoiceDiagnosticLog.record("first voice packet sent bytes=\(queuedPacket.data.count)")
                }
            } catch {
                VoiceDiagnosticLog.record("voice packet send failed error=\(error.localizedDescription)")
                guard audioSendDrainGeneration == generation, !Task.isCancelled else { return }
                await handleTransportFailure(
                    sessionID: queuedPacket.sessionID,
                    reason: "Voice transmission failed: \(error.localizedDescription)"
                )
                break
            }
        }

        guard audioSendDrainGeneration == generation else { return }
        audioSendDrainTask = nil
        if !queuedOutgoingAudioPackets.isEmpty {
            startAudioSendDrainIfNeeded()
        }
    }

    // MARK: - Receive Loops

    private func startRelayReceiveLoop(
        stream: AsyncThrowingStream<EchoLinkRelayResponse, Error>,
        client: EchoLinkRelayClient,
        sessionID: UUID
    ) {
        controlReceiveTask?.cancel()
        controlReceiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await response in stream {
                    guard self.session?.id == sessionID, self.relayClient === client else { break }
                    switch response.type {
                    case .data:
                        guard response.sourceHost == self.session?.station.ipAddress else {
                            self.logger.warning("Dropped relayed datagram from unexpected host=\(response.sourceHost, privacy: .public)")
                            continue
                        }
                        if response.destinationPort == Self.controlPort {
                            await self.handleControlData(response.payload)
                        } else if response.destinationPort == Self.audioPort {
                            self.incomingAudioDatagrams += 1
                            await self.handleAudioData(response.payload)
                        }
                    case .error:
                        if self.session?.state == .connected {
                            do {
                                try await client.refreshRegistration()
                                self.logger.warning("Relay allocation error during QSO; refreshed registration")
                                continue
                            } catch {
                                self.logger.error("Relay registration refresh failed: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                        await self.handleTransportFailure(
                            sessionID: sessionID,
                            reason: "EchoLink Relay could not allocate a connection to this station."
                        )
                        return
                    case .ack, .ping:
                        break
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      self.session?.id == sessionID,
                      self.relayClient === client else { return }
                await self.handleTransportFailure(
                    sessionID: sessionID,
                    reason: "The EchoLink Relay connection failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func startProxyReceiveLoop(proxySession: EchoLinkProxySession, sessionID: UUID) {
        controlReceiveTask?.cancel()
        controlReceiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in await proxySession.udpMessages() {
                    guard self.session?.id == sessionID, self.proxySession === proxySession else { break }
                    guard message.remoteHost == self.session?.station.ipAddress else {
                        self.logger.warning("Dropped proxied datagram from unexpected host=\(message.remoteHost, privacy: .public)")
                        continue
                    }
                    switch message.type {
                    case .udpControl:
                        await self.handleControlData(message.payload)
                    case .udpData:
                        self.incomingAudioDatagrams += 1
                        await self.handleAudioData(message.payload)
                    default:
                        self.logger.debug("Ignoring unused EchoLink Proxy message type=\(message.type.rawValue)")
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      self.session?.id == sessionID,
                      self.proxySession === proxySession else { return }
                await self.handleTransportFailure(
                    sessionID: sessionID,
                    reason: "The EchoLink Proxy tunnel failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func startControlReceiveLoop(sessionID: UUID) {
        controlReceiveTask?.cancel()
        controlReceiveTask = Task { [weak self] in
            guard let self = self else { return }
            guard let expectedSocket = self.controlSocket else { return }
            var transientFailureCount = 0
            while !Task.isCancelled {
                guard self.session?.id == sessionID,
                      self.controlSocket === expectedSocket else { break }

                do {
                    let datagram = try await expectedSocket.receive()
                    transientFailureCount = 0
                    guard self.session?.id == sessionID,
                          self.controlSocket === expectedSocket else { break }
                    guard datagram.sourceHost == self.session?.station.ipAddress else {
                        self.logger.warning(
                            "Dropped control datagram from unexpected host=\(datagram.sourceHost, privacy: .public)"
                        )
                        continue
                    }
                    await self.handleControlData(datagram.data)
                } catch {
                    guard !Task.isCancelled,
                          self.session?.id == sessionID,
                          self.controlSocket === expectedSocket,
                          let sessionState = self.session?.state,
                          sessionState == .connecting || sessionState == .connected else { break }
                    if let socketError = error as? BoundUDPSocket.SocketError,
                       socketError.isTransientReceiveFailure,
                       transientFailureCount < 3 {
                        transientFailureCount += 1
                        self.logger.debug(
                            "Retrying transient control receive failure attempt=\(transientFailureCount)"
                        )
                        try? await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    await self.handleTransportFailure(
                        sessionID: sessionID,
                        reason: "The control connection failed: \(error.localizedDescription)"
                    )
                    break
                }
            }
        }
    }

    private func startAudioReceiveLoop(sessionID: UUID) {
        audioReceiveTask?.cancel()
        audioReceiveTask = Task { [weak self] in
            guard let self = self else { return }
            guard let expectedSocket = self.audioSocket else { return }
            var transientFailureCount = 0
            while !Task.isCancelled {
                guard self.session?.id == sessionID,
                      self.audioSocket === expectedSocket else { break }

                do {
                    let datagram = try await expectedSocket.receive()
                    transientFailureCount = 0
                    guard self.session?.id == sessionID,
                          self.audioSocket === expectedSocket else { break }
                    guard datagram.sourceHost == self.session?.station.ipAddress else {
                        self.logger.warning(
                            "Dropped audio datagram from unexpected host=\(datagram.sourceHost, privacy: .public)"
                        )
                        continue
                    }
                    self.incomingAudioDatagrams += 1
                    await self.handleAudioData(datagram.data)
                } catch {
                    guard !Task.isCancelled,
                          self.session?.id == sessionID,
                          self.audioSocket === expectedSocket,
                          let sessionState = self.session?.state,
                          sessionState == .connecting || sessionState == .connected else { break }
                    if let socketError = error as? BoundUDPSocket.SocketError,
                       socketError.isTransientReceiveFailure,
                       transientFailureCount < 3 {
                        transientFailureCount += 1
                        self.logger.debug(
                            "Retrying transient audio receive failure attempt=\(transientFailureCount)"
                        )
                        try? await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    await self.handleTransportFailure(
                        sessionID: sessionID,
                        reason: "The audio connection failed: \(error.localizedDescription)"
                    )
                    break
                }
            }
        }
    }

    // MARK: - Message Handling

    private func handleControlData(_ data: Data) async {
        guard !data.isEmpty else { return }
        _ = await handleControlEvents(EchoLinkControlPacketCodec.parseEvents(from: data))
    }

    @discardableResult
    private func handleControlEvents(_ events: [EchoLinkControlEvent]) async -> Bool {
        guard !events.isEmpty else { return false }

        for event in events {
            switch event {
            case .sdes(let sdes):
                if sdes.supportsSpeex, audioEngine.isSpeexTransmitAvailable {
                    transmitCodec = .speex
                }
                if sdes.privateItems.contains("D1") {
                    remotePadAllowed = true
                } else if sdes.privateItems.contains("D0") {
                    remotePadAllowed = false
                }
                if var currentSession = session {
                    if currentSession.state == .connecting {
                        logger.debug("Received EchoLink SDES acknowledgement")
                        currentSession.state = .connected
                        currentSession.startTime = Date()
                    }
                    if let displayName = sdes.preferredDisplayName {
                        currentSession.sysopInfo = displayName
                    }
                    session = currentSession
                    if currentSession.state == .connected {
                        resetPeerTimeout(sessionID: currentSession.id)
                    }
                }
                if let displayName = sdes.preferredDisplayName,
                   let callsign = EchoLinkParticipantParser.firstCallsign(in: displayName) {
                    upsertParticipant(
                        callsign: callsign,
                        displayName: displayName,
                        isTransmitting: nil
                    )
                }

            case .bye(let reason):
                if let sessionID = session?.id {
                    await handleRemoteDisconnect(sessionID: sessionID, byeReason: reason)
                }
                return true

            case .info(let text):
                if let currentSession = session, currentSession.state == .connected {
                    resetPeerTimeout(sessionID: currentSession.id)
                }
                applyInfoMessageToParticipants(text)
                appendIncomingChat(sender: "Remote", body: text, isInformational: true)

            case .chat(let sender, let body):
                if let currentSession = session, currentSession.state == .connected {
                    resetPeerTimeout(sessionID: currentSession.id)
                }
                lastRemoteChatBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                lastRemoteChatAt = Date()
                if let senderCallsign = EchoLinkParticipantParser.firstCallsign(in: sender) {
                    upsertParticipant(callsign: senderCallsign, displayName: sender, isTransmitting: nil)
                }
                appendIncomingChat(sender: sender, body: body)
            }
        }

        return true
    }

    private func appendIncomingChat(sender: String, body: String, isInformational: Bool = false) {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return }

        let message = ChatMessage(
            sender: sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Remote" : sender,
            body: trimmedBody,
            isOutgoing: false,
            isInformational: isInformational
        )
        incomingChatMessages.append(message)
    }

    private func resetActiveParticipants(for station: Station) {
        cancelAllTxDecayTasks()
        participantsByCallsign.removeAll(keepingCapacity: false)

        if let stationCallsign = normalizeCallsign(station.callsign) {
            participantsByCallsign[stationCallsign] = ActiveNodeParticipant(
                callsign: stationCallsign,
                displayName: station.callsign,
                isTransmitting: false,
                lastActivity: Date()
            )
        }

        publishActiveParticipants()
    }

    private func applyInfoMessageToParticipants(_ infoText: String) {
        let updates = EchoLinkParticipantParser.parseInfoMessage(infoText)
        guard !updates.isEmpty else { return }

        for update in updates {
            switch update.kind {
            case .remove:
                removeParticipant(callsign: update.callsign)
            case .upsert:
                upsertParticipant(
                    callsign: update.callsign,
                    displayName: nil,
                    isTransmitting: update.isTransmitting
                )
            }
        }
    }

    private func upsertParticipant(callsign: String, displayName: String?, isTransmitting: Bool?) {
        guard let normalized = normalizeCallsign(callsign) else { return }

        var participant = participantsByCallsign[normalized] ?? ActiveNodeParticipant(
            callsign: normalized,
            displayName: nil,
            isTransmitting: false,
            lastActivity: Date()
        )

        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                participant.displayName = trimmed
            }
        }
        participant.lastActivity = Date()
        participantsByCallsign[normalized] = participant

        if let isTransmitting {
            updateParticipantTransmittingState(callsign: normalized, isTransmitting: isTransmitting, autoDecay: isTransmitting)
        } else {
            publishActiveParticipants()
        }
    }

    private func removeParticipant(callsign: String) {
        guard let normalized = normalizeCallsign(callsign) else { return }
        participantsByCallsign.removeValue(forKey: normalized)
        txDecayTasks[normalized]?.cancel()
        txDecayTasks[normalized] = nil
        publishActiveParticipants()
    }

    func noteIncomingAudioActivity() {
        guard session?.isPTTActive != true else { return }

        if !isRemoteTransmitting {
            isRemoteTransmitting = true
        }
        remoteVoiceActivityTask?.cancel()
        remoteVoiceActivityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.remoteVoiceActivityHold)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.isRemoteTransmitting = false
            self.remoteVoiceActivityTask = nil
        }

        if let activeTransmitter = participantsByCallsign.values.first(where: { $0.isTransmitting })?.callsign {
            updateParticipantTransmittingState(callsign: activeTransmitter, isTransmitting: true, autoDecay: true)
            return
        }

        guard let fallbackCallsign = primaryNodeCallsign() else { return }
        upsertParticipant(callsign: fallbackCallsign, displayName: nil, isTransmitting: true)
    }

    private func updateParticipantTransmittingState(callsign: String, isTransmitting: Bool, autoDecay: Bool) {
        guard var participant = participantsByCallsign[callsign] else { return }

        if isTransmitting {
            for key in participantsByCallsign.keys where key != callsign {
                if var other = participantsByCallsign[key], other.isTransmitting {
                    other.isTransmitting = false
                    participantsByCallsign[key] = other
                }
            }
            participant.isTransmitting = true
            participant.lastActivity = Date()
            participantsByCallsign[callsign] = participant
            if autoDecay {
                scheduleTxDecay(for: callsign)
            }
        } else {
            participant.isTransmitting = false
            participant.lastActivity = Date()
            participantsByCallsign[callsign] = participant
            txDecayTasks[callsign]?.cancel()
            txDecayTasks[callsign] = nil
        }

        publishActiveParticipants()
    }

    private func scheduleTxDecay(for callsign: String) {
        txDecayTasks[callsign]?.cancel()
        txDecayTasks[callsign] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.expireTransmittingFlag(for: callsign)
        }
    }

    private func expireTransmittingFlag(for callsign: String) {
        txDecayTasks[callsign] = nil
        guard var participant = participantsByCallsign[callsign], participant.isTransmitting else { return }

        let elapsed = Date().timeIntervalSince(participant.lastActivity)
        guard elapsed >= 1.8 else { return }

        participant.isTransmitting = false
        participantsByCallsign[callsign] = participant
        publishActiveParticipants()
    }

    private func publishActiveParticipants() {
        activeNodeParticipants = participantsByCallsign.values.sorted { lhs, rhs in
            if lhs.isTransmitting != rhs.isTransmitting {
                return lhs.isTransmitting && !rhs.isTransmitting
            }
            return lhs.callsign < rhs.callsign
        }
    }

    private func primaryNodeCallsign() -> String? {
        guard let station = session?.station else { return nil }
        return normalizeCallsign(station.callsign)
    }

    private func normalizeCallsign(_ raw: String) -> String? {
        if let parsed = EchoLinkParticipantParser.firstCallsign(in: raw) {
            return parsed
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func cancelAllTxDecayTasks() {
        for task in txDecayTasks.values {
            task.cancel()
        }
        txDecayTasks.removeAll(keepingCapacity: false)
    }

    private func handleRemoteDisconnect(sessionID: UUID, byeReason: String?) async {
        guard let initialSession = session,
              initialSession.id == sessionID,
              initialSession.state == .connecting || initialSession.state == .connected else { return }

        let initialConnectionAge = Date().timeIntervalSince(initialSession.startTime)
        let endedDuringSetup = initialSession.state == .connecting || initialConnectionAge < 5
        if endedDuringSetup, recentRemoteChatBody() == nil {
            // NDATA and RTCP arrive on separate sockets; let an in-flight reason
            // reach the audio loop before finalizing the BYE.
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard !Task.isCancelled,
              let currentSession = session,
              currentSession.id == sessionID,
              currentSession.state == .connecting || currentSession.state == .connected else { return }

        var message = "Remote station sent RTCP BYE"
        if let byeReason, !byeReason.isEmpty {
            message += " (\(byeReason))"
        }
        if let recentRemoteChatBody = recentRemoteChatBody() {
            message += ": \(recentRemoteChatBody)"
        } else {
            message += "."
        }
        await finishSession(
            sessionID: sessionID,
            failureReason: message,
            failureIsRemoteBye: true
        )
    }

    private func recentRemoteChatBody() -> String? {
        guard let lastRemoteChatBody,
              !lastRemoteChatBody.isEmpty,
              let lastRemoteChatAt,
              Date().timeIntervalSince(lastRemoteChatAt) <= 2 else { return nil }
        return lastRemoteChatBody
    }

    private func handleTransportFailure(sessionID: UUID, reason: String) async {
        await finishSession(sessionID: sessionID, failureReason: reason)
    }

    private func finishSession(
        sessionID: UUID,
        failureReason: String?,
        failureIsRemoteBye: Bool = false
    ) async {
        guard var currentSession = session,
              currentSession.id == sessionID,
              currentSession.state != .disconnected,
              currentSession.state != .disconnecting else { return }
        let wasConnected = currentSession.state == .connected
        let startTime = currentSession.startTime
        let station = currentSession.station

        if let failureReason {
            error = failureIsRemoteBye
                ? ConnectionError.remoteBye(failureReason)
                : ConnectionError.connectionFailed(failureReason)
        }

        registerReconnectCandidate(station)

        currentSession.isPTTActive = false
        currentSession.state = .disconnected
        session = currentSession

        if wasConnected {
            let duration = Date().timeIntervalSince(startTime)
            onSessionEnded?(station, duration)
        }

        tearDown(expectedSessionID: sessionID)

        try? await Task.sleep(for: .milliseconds(500))
        if session?.id == sessionID {
            session = nil
        }
    }

    func handleAudioData(_ data: Data) async {
        guard session != nil else { return }

        if await handleControlEvents(EchoLinkControlPacketCodec.parseEvents(from: data)) {
            return
        }

        guard let datagram = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(data) else {
            logger.debug("Dropped non-audio UDP packet on audio port size=\(data.count)")
            return
        }
#if DEBUG
        onAuditIncomingDatagram?(data)
#endif

        guard let currentSession = session,
              currentSession.state == .connected else { return }

        if case .unsupportedPayloadType = datagram.packet {
            audioDiagnosticsTotals.invalidRXPackets += 1
            playIncomingAudioDatagram(data, datagram: datagram)
            return
        }
        // Validate complete voice payloads before they can consume an RTP
        // sequence, refresh peer liveness, or reach recording/forwarding.
        let validPayload: Bool
        switch datagram.packet {
        case .gsm(let payload):
            validPayload = !payload.isEmpty && payload.count <= 4 * GSMCodec.encodedFrameSize
                && payload.count.isMultiple(of: GSMCodec.encodedFrameSize)
                && stride(from: 0, to: payload.count, by: GSMCodec.encodedFrameSize).allSatisfy {
                    payload[payload.startIndex + $0] & 0xF0 == 0xD0
                }
        case .pcm(let samples):
            // G.711 packets contain 10 ms blocks at 8 kHz, up to the
            // client's 80 ms voice packet duration.
            validPayload = !samples.isEmpty && samples.count <= 640 && samples.count.isMultiple(of: 80)
        case .speex(let payload):
            validPayload = receiveSpeexValidator.decodePacket(payload) != nil
        case .unsupportedPayloadType:
            validPayload = false
        }
        guard validPayload else {
            audioDiagnosticsTotals.invalidRXPackets += 1
            logger.debug("Dropped malformed voice payload before receive sequence admission")
            return
        }
        let ready = receiveReorderBuffer.insert(data, metadata: datagram.metadata)
        for packet in ready {
            guard let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet) else { continue }
            playIncomingAudioDatagram(packet, datagram: parsed)
        }
        scheduleReceiveReorderDrain(sessionID: currentSession.id)
    }

    private func scheduleReceiveReorderDrain(sessionID: UUID) {
        receiveReorderTask?.cancel()
        receiveReorderTask = nil
        guard let deadline = receiveReorderBuffer.nextDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        receiveReorderTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.session?.id == sessionID,
                  self.session?.state == .connected else { return }
            self.receiveReorderTask = nil
            for packet in self.receiveReorderBuffer.drain() {
                guard let parsed = EchoLinkAudioPacketCodec.parseIncomingAudioDatagram(packet) else { continue }
                self.playIncomingAudioDatagram(packet, datagram: parsed)
            }
            self.scheduleReceiveReorderDrain(sessionID: sessionID)
        }
    }

    private func playIncomingAudioDatagram(_ data: Data, datagram: ParsedIncomingAudioDatagram) {
        guard let currentSession = session, currentSession.state == .connected else { return }

        switch datagram.packet {
        case .gsm(let payload):
            guard receiveSequencer.shouldAcceptForPlayback(datagram.metadata) else {
                logger.debug("Dropped duplicate or late RTP audio packet")
                return
            }
            resetPeerTimeout(sessionID: currentSession.id)
            audioStatusMessage = nil
            incomingVoicePackets += 1
            recordReceivedAudio(codec: "GSM", payloadBytes: payload.count)
#if DEBUG
            onAuditAcceptedPacket?(datagram.metadata)
#endif
            let forwarded = forwardReceiveToWatch(data, session: currentSession)
            guard !currentSession.isMuted && !isBackgroundMuted && !forwarded else {
                let samples = mutedActivityCodec.decodePacket(payload)
                appendRecordingPCM(samples)
                if forwarded { audioEngine.recordOutputLevel(from: samples) }
                if Self.hasVoiceEnergy(samples) { noteIncomingAudioActivity() }
                return
            }
            let diagnoseFirstRX = logNextVoiceAfterPTT
            if logNextVoiceAfterPTT {
                logger.info("RX voice resumed after PTT codec=GSM bytes=\(payload.count) playbackRunning=\(self.audioEngine.isRunning)")
                logNextVoiceAfterPTT = false
            }
            audioEngine.playReceivedAudio(payload, metadata: datagram.metadata, diagnoseFirstRXAfterPTT: diagnoseFirstRX)
            if audioEngine.outputLevel >= 0.01 { noteIncomingAudioActivity() }
        case .pcm(let samples):
            guard receiveSequencer.shouldAcceptForPlayback(datagram.metadata) else {
                logger.debug("Dropped duplicate or late RTP audio packet")
                return
            }
            resetPeerTimeout(sessionID: currentSession.id)
            audioStatusMessage = nil
            incomingVoicePackets += 1
            let wireCodec = datagram.metadata?.payloadType == 8 ? "G.711 A-law"
                : datagram.metadata?.payloadType == 0 ? "G.711 µ-law" : "G.711 µ-law (inferred)"
            recordReceivedAudio(codec: wireCodec, payloadBytes: samples.count)
#if DEBUG
            onAuditAcceptedPacket?(datagram.metadata)
#endif
            let forwarded = forwardReceiveToWatch(data, session: currentSession)
            guard !currentSession.isMuted && !isBackgroundMuted && !forwarded else {
                appendRecordingPCM(samples)
                if forwarded { audioEngine.recordOutputLevel(from: samples) }
                if Self.hasVoiceEnergy(samples) { noteIncomingAudioActivity() }
                return
            }
            let diagnoseFirstRX = logNextVoiceAfterPTT
            if logNextVoiceAfterPTT {
                logger.info("RX voice resumed after PTT codec=PCM samples=\(samples.count) playbackRunning=\(self.audioEngine.isRunning)")
                logNextVoiceAfterPTT = false
            }
            audioEngine.playReceivedPCM(samples, metadata: datagram.metadata, diagnoseFirstRXAfterPTT: diagnoseFirstRX)
            if audioEngine.outputLevel >= 0.01 { noteIncomingAudioActivity() }
        case .speex(let payload):
            var sequenceCandidate = receiveSequencer
            guard sequenceCandidate.shouldAcceptForPlayback(datagram.metadata) else {
                logger.debug("Dropped duplicate or late Speex audio packet")
                return
            }
            guard let decoded = audioEngine.decodeReceivedSpeex(payload, metadata: datagram.metadata) else {
                audioDiagnosticsTotals.invalidRXPackets += 1
                logger.debug("Dropped malformed EchoLink Speex audio packet")
                return
            }
            receiveSequencer = sequenceCandidate
            let samples = decoded.received
            resetPeerTimeout(sessionID: currentSession.id)
            audioStatusMessage = nil
            incomingVoicePackets += 1
            recordReceivedAudio(codec: "Speex", payloadBytes: payload.count)
#if DEBUG
            onAuditAcceptedPacket?(datagram.metadata)
#endif
            let forwarded = forwardReceiveToWatch(data, session: currentSession)
            guard !currentSession.isMuted && !isBackgroundMuted && !forwarded else {
                appendRecordingPCM(samples)
                if forwarded { audioEngine.recordOutputLevel(from: samples) }
                if Self.hasVoiceEnergy(samples) { noteIncomingAudioActivity() }
                return
            }
            let diagnoseFirstRX = logNextVoiceAfterPTT
            if logNextVoiceAfterPTT {
                logger.info("RX voice resumed after PTT codec=Speex samples=\(samples.count)")
                logNextVoiceAfterPTT = false
            }
            audioEngine.playReceivedPCM(samples, metadata: datagram.metadata, nativeConcealment: decoded.concealed, diagnoseFirstRXAfterPTT: diagnoseFirstRX)
            if audioEngine.outputLevel >= 0.01 { noteIncomingAudioActivity() }
        case .unsupportedPayloadType(let pt):
            audioStatusMessage = "Remote station sent unsupported audio payload type \(pt)."
            if !loggedUnsupportedPayloadTypes.contains(pt) {
                loggedUnsupportedPayloadTypes.insert(pt)
                logger.error("Received unsupported RTP payload type pt=\(pt)")
            }
        }
    }

    private static func hasVoiceEnergy(_ samples: [Int16]) -> Bool {
        guard !samples.isEmpty else { return false }
        let meanSquare = samples.reduce(0.0) { sum, sample in
            let value = Double(sample)
            return sum + value * value
        } / Double(samples.count)
        return meanSquare >= 10_000 // RMS >= 100, matching the audible RX threshold.
    }

    // MARK: - Keep-Alive

    private func startKeepAlive(sessionID: UUID) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepAliveInterval)
                guard !Task.isCancelled else { break }
                // Re-send SDES as keepalive on control port
                guard let self = self, self.session?.id == sessionID else { break }
                let sdes = self.buildSDESPacket(callsign: self.localCallsign)
                do {
                    try await self.sendControl(data: sdes)
                } catch {
                    await self.handleTransportFailure(
                        sessionID: sessionID,
                        reason: "EchoLink keepalive failed: \(error.localizedDescription)"
                    )
                    break
                }
            }
        }
    }

    private func resetPeerTimeout(sessionID: UUID) {
        peerTimeoutTask?.cancel()
        peerTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.peerTimeoutInterval)
            } catch {
                return
            }
            guard let self,
                  self.session?.id == sessionID,
                  self.session?.state == .connected else { return }
            await self.handleTransportFailure(
                sessionID: sessionID,
                reason: "The remote station stopped sending EchoLink keepalives."
            )
        }
    }

    // MARK: - Teardown

    private func tearDown(expectedSessionID: UUID? = nil) {
        if let expectedSessionID, session?.id != expectedSessionID {
            return
        }
        if let waiter = handshakeWaiter {
            completeHandshakeWaiter(id: waiter.id, result: .failure(CancellationError()))
        }
        setWatchAudioOutput(false)
        cancelLocalDemoPlayback()
        localDemoAudio.clear()

        keepAliveTask?.cancel()
        keepAliveTask = nil
        peerTimeoutTask?.cancel()
        peerTimeoutTask = nil
        captureStartTask?.cancel()
        captureStartTask = nil
        dtmfGeneration &+= 1
        dtmfTask?.cancel()
        dtmfTask = nil
        isSendingDTMF = false
        remotePadAllowed = false
        transmitCodec = .gsm
        activeTransmitCodec = .gsm
        desiredPTTActive = false
        captureStopGeneration &+= 1
        captureStopTask?.cancel()
        captureStopTask = nil
        audioSendDrainGeneration &+= 1
        audioSendDrainTask?.cancel()
        audioSendDrainTask = nil
        queuedOutgoingAudioPackets.removeAll(keepingCapacity: false)
        controlReceiveTask?.cancel()
        controlReceiveTask = nil
        audioReceiveTask?.cancel()
        audioReceiveTask = nil
        remoteVoiceActivityTask?.cancel()
        remoteVoiceActivityTask = nil
        isRemoteTransmitting = false

        stopSessionRecording()
        audioEngine.onCapturedAudio = nil
        capturePreparationTask?.cancel()
        capturePreparationTask = nil
        audioEngine.stopAll()

        audioSocket?.close()
        audioSocket = nil
        controlSocket?.close()
        controlSocket = nil
        proxySession = nil
        if let relayClient {
            self.relayClient = nil
            Task { await relayClient.close() }
            if let finishRelayDirectory, let relayDirectoryAddress {
                let callsign = localCallsign
                Task { await finishRelayDirectory(callsign, relayDirectoryAddress) }
            }
        }
        relayDirectoryAddress = nil

        incomingChatMessages = []
        cancelAllTxDecayTasks()
        participantsByCallsign.removeAll(keepingCapacity: false)
        activeNodeParticipants = []
        audioStatusMessage = nil
        pendingOutgoingGSMPayload.removeAll(keepingCapacity: false)
        hasLoggedUnsupportedSpeex = false
        loggedUnsupportedPayloadTypes.removeAll()
        receiveSequencer.reset()
        receiveReorderTask?.cancel()
        receiveReorderTask = nil
        receiveReorderBuffer.reset()
        receiveSpeexValidator.reset()
        lastRemoteChatBody = nil
        lastRemoteChatAt = nil
    }
}
