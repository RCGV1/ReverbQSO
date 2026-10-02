// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// In-memory GSM recording: 375 complete 80 ms packets, or 30 seconds.
struct LocalDemoAudioBuffer {
    private(set) var packets: [Data] = []

    @discardableResult
    mutating func append(_ packet: Data) -> Bool {
        guard packet.count == GSMCodec.encodedFrameSize * 4, packets.count < 375 else { return false }
        packets.append(packet)
        return true
    }

    mutating func takePackets() -> [Data] {
        let recorded = packets
        clear()
        return recorded
    }

    mutating func clear() { packets.removeAll(keepingCapacity: false) }
}
