// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A short-lived directory and source-address match for one incoming SDES.
/// Only `verify` can create this value. Directory matching is not cryptographic
/// authentication, and a host must still apply its own access policy.
struct VerifiedInboundHostPeer {
    let station: Station
    let sourceIPv4Address: String
    let verifiedAt: Date

    private init(station: Station, sourceIPv4Address: String, verifiedAt: Date) {
        self.station = station
        self.sourceIPv4Address = sourceIPv4Address
        self.verifiedAt = verifiedAt
    }

    static func verify(
        claim: InboundCallClaim,
        stations: [Station],
        directoryUpdatedAt: Date?,
        now: Date,
        maxDirectoryAge: TimeInterval
    ) -> Result<VerifiedInboundHostPeer, InboundStationRejection> {
        InboundStationVerifier.verify(
            claim: claim,
            stations: stations,
            directoryUpdatedAt: directoryUpdatedAt,
            now: now,
            maxAge: maxDirectoryAge
        ).map {
            VerifiedInboundHostPeer(
                station: $0,
                sourceIPv4Address: claim.sourceIPv4Address,
                verifiedAt: now
            )
        }
    }
}

struct InboundHostPolicy {
    /// The caller chooses this limit based on bandwidth and operator policy.
    /// EchoLink's documented software setting permits 1...99 remote stations.
    let maximumPeers: Int
    let allowsConferenceServers: Bool
    let allowsMultiConferencing: Bool
    let deniedCallsigns: Set<String>
    let allowedCallsigns: Set<String>?
    let maximumVerificationAge: TimeInterval

    var isValid: Bool {
        (1...99).contains(maximumPeers)
            && maximumVerificationAge.isFinite
            && maximumVerificationAge > 0
    }

    init(
        maximumPeers: Int = 1,
        allowsConferenceServers: Bool = true,
        allowsMultiConferencing: Bool = false,
        deniedCallsigns: Set<String> = [],
        allowedCallsigns: Set<String>? = nil,
        maximumVerificationAge: TimeInterval = 5
    ) {
        self.maximumPeers = maximumPeers
        self.allowsConferenceServers = allowsConferenceServers
        self.allowsMultiConferencing = allowsMultiConferencing
        self.deniedCallsigns = Set(deniedCallsigns.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        })
        self.allowedCallsigns = allowedCallsigns.map { entries in
            Set(entries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() })
        }
        self.maximumVerificationAge = maximumVerificationAge
    }
}

enum InboundHostRejection: Error, Equatable {
    case disabled
    case invalidPolicy
    case staleVerification
    case invalidControlPort
    case invalidAudioPort
    case deniedCallsign
    case conferenceServerDisabled
    case multiConferenceDisabled
    case atCapacity
    case duplicateCallsign
    case endpointInUse
    case audioEndpointInUse
}

enum InboundHostAvailability: Equatable {
    case offline
    case on
    case busy
}

struct InboundHostSession: Equatable {
    enum State: Equatable {
        case pending
        case active
    }

    let id: UUID
    let callsign: String
    let sourceIPv4Address: String
    let controlPort: UInt16
    let audioPort: UInt16
    let stationType: Station.StationType
    let admittedAt: Date
    var lastActivityAt: Date
    fileprivate(set) var state: State
}

/// Pure admission and lifecycle state. A transport must send SDES or BYE,
/// route packets, and publish directory status based on the returned state.
struct InboundHostSessionMachine {
    let policy: InboundHostPolicy
    private(set) var isEnabled: Bool
    private(set) var sessions: [InboundHostSession] = []

    init(policy: InboundHostPolicy, isEnabled: Bool = false) {
        self.policy = policy
        self.isEnabled = isEnabled
    }

    var availability: InboundHostAvailability {
        guard isEnabled, policy.isValid else { return .offline }
        return sessions.count >= policy.maximumPeers ? .busy : .on
    }

    /// Disabling clears reservations and sessions. The transport must send BYE
    /// and close its peer resources before or while applying this transition.
    @discardableResult
    mutating func setEnabled(_ enabled: Bool) -> [InboundHostSession] {
        isEnabled = enabled
        guard !enabled else { return [] }
        let removed = sessions
        sessions.removeAll()
        return removed
    }

    /// Reserve one slot after an incoming SDES has passed directory verification.
    /// A duplicate attempt cannot create a second session or consume another slot.
    mutating func admit(
        _ peer: VerifiedInboundHostPeer,
        controlPort: Int,
        audioPort: Int = 5198,
        now: Date
    ) -> Result<InboundHostSession, InboundHostRejection> {
        guard isEnabled else { return .failure(.disabled) }
        guard policy.isValid else { return .failure(.invalidPolicy) }
        guard (0...policy.maximumVerificationAge).contains(now.timeIntervalSince(peer.verifiedAt)) else {
            return .failure(.staleVerification)
        }
        guard (1...65535).contains(controlPort) else { return .failure(.invalidControlPort) }
        guard (1...65535).contains(audioPort) else { return .failure(.invalidAudioPort) }

        let callsign = peer.station.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if policy.deniedCallsigns.contains(callsign) ||
            (policy.allowedCallsigns.map { !$0.contains(callsign) } ?? false) {
            return .failure(.deniedCallsign)
        }
        if peer.station.type == .conference && !policy.allowsConferenceServers {
            return .failure(.conferenceServerDisabled)
        }

        // A network endpoint cannot be attributed to two peers, even when their
        // advertised callsigns differ. Keep the call identity unique as well.
        if sessions.contains(where: { $0.callsign == callsign }) {
            return .failure(.duplicateCallsign)
        }
        if sessions.contains(where: {
            $0.sourceIPv4Address == peer.sourceIPv4Address && $0.controlPort == controlPort
        }) {
            return .failure(.endpointInUse)
        }
        if sessions.contains(where: {
            $0.sourceIPv4Address == peer.sourceIPv4Address && $0.audioPort == audioPort
        }) {
            return .failure(.audioEndpointInUse)
        }
        if !policy.allowsMultiConferencing && !sessions.isEmpty &&
            (peer.station.type == .conference || sessions.contains(where: { $0.stationType == .conference })) {
            return .failure(.multiConferenceDisabled)
        }
        guard sessions.count < policy.maximumPeers else { return .failure(.atCapacity) }

        let session = InboundHostSession(
            id: UUID(), callsign: callsign,
            sourceIPv4Address: peer.sourceIPv4Address,
            controlPort: UInt16(controlPort), audioPort: UInt16(audioPort), stationType: peer.station.type,
            admittedAt: now, lastActivityAt: now, state: .pending
        )
        sessions.append(session)
        return .success(session)
    }

    /// Activate only after the transport has successfully replied with SDES.
    @discardableResult
    mutating func activate(id: UUID, now: Date) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id && $0.state == .pending }),
              now >= sessions[index].lastActivityAt else { return false }
        sessions[index].state = .active
        sessions[index].lastActivityAt = now
        return true
    }

    @discardableResult
    mutating func recordActivity(id: UUID, now: Date) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id && $0.state == .active }),
              now >= sessions[index].lastActivityAt else { return false }
        sessions[index].lastActivityAt = now
        return true
    }

    @discardableResult
    mutating func remove(id: UUID) -> InboundHostSession? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        return sessions.remove(at: index)
    }

    /// Releases reservations for handshakes that did not complete. The caller
    /// supplies its transport timeout and handles any necessary BYE.
    @discardableResult
    mutating func expirePending(now: Date, timeout: TimeInterval) -> [InboundHostSession] {
        guard timeout.isFinite, timeout > 0 else { return [] }
        let expired = sessions.filter {
            $0.state == .pending && now.timeIntervalSince($0.admittedAt) >= timeout
        }
        let expiredIDs = Set(expired.map(\.id))
        sessions.removeAll { expiredIDs.contains($0.id) }
        return expired
    }
}
