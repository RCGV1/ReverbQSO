// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Owns the direct-mode EchoLink ports while CQ matching is in progress.
/// `takeSockets` transfers that ownership without rebinding, preserving queued datagrams.
final class DirectCQSocketPair: @unchecked Sendable {
    struct Sockets: Sendable {
        let audio: BoundUDPSocket
        let control: BoundUDPSocket
    }

    private let lock = NSLock()
    private var sockets: Sockets?

    init(audioPort: UInt16 = 5198, controlPort: UInt16 = 5199) throws {
        let audio = try BoundUDPSocket(localPort: audioPort)
        do {
            sockets = Sockets(audio: audio, control: try BoundUDPSocket(localPort: controlPort))
        } catch {
            audio.close()
            throw error
        }
    }

    var audioPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return sockets?.audio.actualLocalPort
    }

    func takeSockets() -> Sockets? {
        lock.lock()
        defer { lock.unlock() }
        defer { sockets = nil }
        return sockets
    }

    func close() {
        let owned: Sockets?
        lock.lock()
        owned = sockets
        sockets = nil
        lock.unlock()
        owned?.audio.close()
        owned?.control.close()
    }

    deinit { close() }
}
