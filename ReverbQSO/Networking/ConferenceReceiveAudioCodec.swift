// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One admitted peer owns one decoder and transcoder; codec history never crosses peers.
final class ConferenceReceiveAudioCodec {
    struct Audio {
        let samples: [Int16]
        let gsmPayload: Data
        let nativeConcealment: [Int16]?
    }

    private var gsm = GSMCodec()
    private var speex = SpeexReceiveStreamDecoder()
    private var sequencer = EchoLinkReceiveSequencer()
    private var lastPayloadType: UInt8?
    private var lastSSRC: UInt32?

    func decode(_ datagram: ParsedIncomingAudioDatagram) -> Audio? {
        // Commit sequence state only after validating the complete payload.
        var candidate = sequencer
        guard candidate.shouldAcceptForPlayback(datagram.metadata) else { return nil }
        let changesStream = datagram.metadata?.payloadType != lastPayloadType
            || datagram.metadata?.ssrc != lastSSRC
        // A candidate talker must decode successfully before replacing live
        // predictor history. Corrupt packets cannot reset the admitted talker.
        let candidateGSM = changesStream ? GSMCodec() : gsm
        let candidateSpeex = changesStream ? SpeexReceiveStreamDecoder() : speex
        let samples: [Int16]
        let forwardingPayload: Data
        var nativeConcealment: [Int16]? = nil
        switch datagram.packet {
        case .gsm(let payload):
            guard !payload.isEmpty, payload.count <= 132, payload.count.isMultiple(of: 33),
                  stride(from: 0, to: payload.count, by: 33).allSatisfy({
                      payload[payload.startIndex + $0] & 0xF0 == 0xD0
                  }) else { return nil }
            samples = candidateGSM.decodePacket(payload)
            guard samples.count == payload.count / 33 * 160 else { candidateGSM.resetAll(); return nil }
            forwardingPayload = payload
        case .speex(let payload):
            guard let decoded = candidateSpeex.decode(payload, metadata: datagram.metadata) else { return nil }
            samples = decoded.received
            nativeConcealment = decoded.concealed
            guard let encoded = GSMCodec.stripHeader(candidateGSM.encode(decoded.received)) else { return nil }
            forwardingPayload = encoded
        case .pcm(let decoded):
            guard !decoded.isEmpty, decoded.count <= 640, decoded.count.isMultiple(of: 160) else { return nil }
            samples = decoded
            guard let encoded = GSMCodec.stripHeader(candidateGSM.encode(decoded)) else { return nil }
            forwardingPayload = encoded
        case .unsupportedPayloadType:
            return nil
        }
        gsm = candidateGSM
        speex = candidateSpeex
        sequencer = candidate
        lastPayloadType = datagram.metadata?.payloadType
        lastSSRC = datagram.metadata?.ssrc
        return Audio(
            samples: samples,
            gsmPayload: forwardingPayload,
            nativeConcealment: nativeConcealment
        )
    }
}
