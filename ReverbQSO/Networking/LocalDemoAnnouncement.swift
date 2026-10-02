// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Original welcome spoken by the macOS Samantha voice, resampled to 8 kHz
/// mono and encoded with our libgsm. Playback uses the normal RX decoder.
enum LocalDemoAnnouncement {
    static func echoTestPackets(bundle: Bundle = .main) -> [Data] {
        guard let url = bundle.url(forResource: "EchoTestWelcome", withExtension: "gsm"),
              let data = try? Data(contentsOf: url) else { return [] }
        return packets(from: data)
    }

    static func packets(from data: Data) -> [Data] {
        let packetSize = 4 * GSMCodec.encodedFrameSize
        guard !data.isEmpty, data.count <= 375 * packetSize,
              data.count.isMultiple(of: packetSize),
              stride(from: 0, to: data.count, by: GSMCodec.encodedFrameSize)
                .allSatisfy({ data[$0] & 0xF0 == 0xD0 }) else { return [] }
        return stride(from: 0, to: data.count, by: packetSize).map {
            data.subdata(in: $0..<($0 + packetSize))
        }
    }
}
