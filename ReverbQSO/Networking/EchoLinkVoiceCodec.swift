// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum EchoLinkVoiceCodec: Equatable {
    case gsm
    case speex

    var payloadType: UInt8 { self == .speex ? 0x96 : 0x03 }
}
