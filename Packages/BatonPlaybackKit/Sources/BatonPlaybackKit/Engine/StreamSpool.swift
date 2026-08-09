#if os(macOS) || os(iOS)
// The engine is macOS/iOS only. watchOS has no AudioToolbox — no `AudioFileStream`, so no
// decoder, so no engine — and it plays downloaded files through AVPlayer. See
// `EngineDeckUnavailable.swift` for the stand-in that keeps the policy layer compiling.

import Foundation

/// An append-only on-disk spool holding one track's **compressed** bytes as they arrive
/// from the network, with random read access for the decoder.
///
/// The spool is what decouples the download from the decode: the network writes at wire
/// speed (or the transcoder's speed), the decoder pulls at its own pace, and backpressure
/// costs nothing — a decoder that stops reading simply stops reading. It is also the seek
/// index's backing store (`AudioFileStreamSeek` maps a packet to a byte offset; the spool
/// answers whether that byte has arrived yet) and the stall signal (a playhead that has
/// consumed everything spooled while `isComplete` is false is, by definition, buffering).
///
/// On disk rather than in memory deliberately: a transcoded hour-long set is tens of MB,
/// and two decks can each hold one — the same order of magnitude as the gapless prefetch
/// cache, and just as ephemeral. The file is unlinked in `close()`/`deinit`.
///
/// Not `Sendable` — owned by exactly one `TrackStreamSource` actor, which serializes every
/// append and read.
final class StreamSpool {
    let url: URL
    private var handle: FileHandle?
    /// Bytes written so far. Grows monotonically; never shrinks.
    private(set) var byteCount: Int64 = 0
    /// The server's `Content-Length`, when it sent one. A cold transcode is chunked and
    /// has none — which is itself a signal (see `StreamSeek`: such a stream is not
    /// byte-range seekable either).
    var expectedByteCount: Int64?
    /// True once the network side has delivered the final byte (success only — a failed
    /// download reports through the source's error path, never as a complete spool).
    private(set) var isComplete = false

    enum SpoolError: Error { case createFailed(String) }

    init(directory: URL? = nil) throws {
        let dir = directory ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent("baton-stream-spool-\(UUID().uuidString).audio")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forUpdating: url) else {
            throw SpoolError.createFailed(url.path)
        }
        handle = h
    }

    deinit { closeAndDelete() }

    func append(_ data: Data) {
        guard let handle, !data.isEmpty else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            byteCount += Int64(data.count)
        } catch {
            // A full disk mid-spool surfaces as the decoder running out of bytes, which
            // routes into the same stall → recovery ladder as a dead network.
        }
    }

    func markComplete() { isComplete = true }

    /// Up to `length` bytes starting at `offset`, or nil when nothing is available there
    /// yet. A short read at the growing end is normal and expected.
    func read(at offset: Int64, length: Int) -> Data? {
        guard let handle, offset < byteCount, length > 0 else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: min(length, Int(byteCount - offset)))
            return (data?.isEmpty == false) ? data : nil
        } catch {
            return nil
        }
    }

    /// Close the handle and remove the file. Idempotent.
    func closeAndDelete() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}

#endif
