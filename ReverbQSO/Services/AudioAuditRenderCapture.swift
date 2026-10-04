// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AVFoundation

/// Live audit only. Copies mixer output off the real-time callback before disk I/O.
final class AudioAuditRenderCapture: @unchecked Sendable {
    private struct Copy: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
    private let queue = DispatchQueue(label: "org.reverbqso.audio-audit-writer", qos: .utility)
    private let lock = NSLock()
    private let format: AVAudioFormat
    private var file: AVAudioFile?
    private var pending = 0
    private var dropped = 0
    private var frames = 0
    private var firstHostTime: UInt64?
    private var lastHostTime: UInt64 = 0
    private var writeErrors = 0

    init(url: URL, format: AVAudioFormat) throws {
        self.format = format
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                              commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    nonisolated func makeTap() -> AVAudioNodeTapBlock {
        { [self] buffer, time in append(buffer, time: time) }
    }

    func append(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock()
        guard pending < 16, buffer.format == format else { dropped += 1; lock.unlock(); return }
        pending += 1
        lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            lock.lock(); pending -= 1; dropped += 1; lock.unlock(); return
        }
        copy.frameLength = buffer.frameLength
        let buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        let source = UnsafeRawPointer(buffer.audioBufferList).advanced(by: buffersOffset)
            .assumingMemoryBound(to: AudioBuffer.self)
        let destination = UnsafeMutableRawPointer(copy.mutableAudioBufferList).advanced(by: buffersOffset)
            .assumingMemoryBound(to: AudioBuffer.self)
        for index in 0..<Int(buffer.audioBufferList.pointee.mNumberBuffers) {
            if let src = source[index].mData, let dst = destination[index].mData {
                memcpy(dst, src, Int(source[index].mDataByteSize))
            }
        }
        let wrapped = Copy(buffer: copy)
        let hostTime = time.hostTime
        queue.async { [self] in
            if firstHostTime == nil { firstHostTime = hostTime }
            lastHostTime = hostTime
            do { try file?.write(from: wrapped.buffer); frames += Int(wrapped.buffer.frameLength) }
            catch { writeErrors += 1 }
            lock.lock(); pending -= 1; lock.unlock()
        }
    }

    func finish() async -> [String: Double] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                file = nil
                lock.lock(); let droppedCount = dropped; lock.unlock()
                continuation.resume(returning: ["frames": Double(frames), "sampleRate": format.sampleRate,
                    "channels": Double(format.channelCount), "droppedTapBuffers": Double(droppedCount),
                    "writeErrors": Double(writeErrors),
                    "firstHostSeconds": AVAudioTime.seconds(forHostTime: firstHostTime ?? 0),
                    "lastHostSeconds": AVAudioTime.seconds(forHostTime: lastHostTime)])
            }
        }
    }
}
#endif
