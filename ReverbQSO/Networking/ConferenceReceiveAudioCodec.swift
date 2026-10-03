// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One admitted peer owns one decoder and transcoder; codec history never crosses peers.
final class ConferenceReceiveAudioCodec {
    struct Audio {
        let samples: [Int16]
        let gsmPayload: Data
        let nativeConcealment: [Int16]?
    }

    private let gsm = GSMCodec()
    private let speex = SpeexReceiveStreamDecoder()
    private var sequencer = EchoLinkReceiveSequencer()
    private var lastPayloadType: UInt8?
    private var lastSSRC: UInt32?

    func decode(_ datagram: ParsedIncomingAudioDatagram) -> Audio? {
        // Commit sequence state only after validating the complete payload.
        var candidate = sequencer
        guard candidate.shouldAcceptForPlayback(datagram.metadata) else { return nil }
        if datagram.metadata?.payloadType != lastPayloadType || datagram.metadata?.ssrc != lastSSRC {
            gsm.resetAll()
            speex.reset()
        }
        let samples: [Int16]
        let forwardingPayload: Data
        var nativeConcealment: [Int16]? = nil
        switch datagram.packet {
        case .gsm(let payload):
            guard !payload.isEmpty, payload.count <= 132, payload.count.isMultiple(of: 33),
                  stride(from: 0, to: payload.count, by: 33).allSatisfy({
                      payload[payload.startIndex + $0] & 0xF0 == 0xD0
                  }) else { return nil }
            samples = gsm.decodePacket(payload)
            guard samples.count == payload.count / 33 * 160 else { gsm.resetAll(); return nil }
            forwardingPayload = payload
        case .speex(let payload):
            guard let decoded = speex.decode(payload, metadata: datagram.metadata) else { return nil }
            samples = decoded.received
            nativeConcealment = decoded.concealed
            guard let encoded = GSMCodec.stripHeader(gsm.encode(decoded.received)) else { return nil }
            forwardingPayload = encoded
        case .pcm(let decoded):
            guard !decoded.isEmpty, decoded.count <= 640, decoded.count.isMultiple(of: 160) else { return nil }
            samples = decoded
            guard let encoded = GSMCodec.stripHeader(gsm.encode(decoded)) else { return nil }
            forwardingPayload = encoded
        case .unsupportedPayloadType:
            return nil
        }
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
