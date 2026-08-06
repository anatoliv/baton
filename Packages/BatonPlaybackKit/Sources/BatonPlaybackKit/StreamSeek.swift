import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// Seeking inside a Navidrome stream that may not support it.
///
/// Navidrome serves a transcode **as it encodes it**. Measured against this library:
///
/// | | `Content-Length` | `Accept-Ranges` |
/// |---|---|---|
/// | cold — server still encoding | absent (`chunked`) | **`none`** |
/// | warm — encode finished, cached | real | `bytes` |
///
/// A `Range` request against the cold stream is answered **`200` from byte zero, not `206`**, so
/// an AVPlayer seek past the buffered region cannot land and the item reports end-of-stream
/// instead. `handleEnded()` then advances the queue — which is the reported bug: *"clicking the
/// playbar on a long track skips to the next track."*
///
/// It presents as flaky because it is time-dependent, not position-dependent. Encoding a long set
/// took **29–108 s** server-side in measurement; until it finishes, that track cannot be seeked.
/// Short tracks encode in a blink and so always appear fine, and any track seeks fine once warm.
///
/// Subsonic's remedy for an unseekable transcode is `timeOffset` — re-request the stream starting
/// N seconds in (verified: returns correctly-offset audio, and a complete `Content-Length`). This
/// type holds the pure decisions so they are testable without AVFoundation or a server.
public enum StreamSeek {

    // MARK: - Skipping the transcode entirely

    /// Suffixes AVFoundation decodes natively, so they can stream as stored — which also makes
    /// them byte-range seekable from the first play, with no encode window to wait out.
    ///
    /// Deliberately an **allowlist**, and a short one. The failure mode for a format AVFoundation
    /// can't decode isn't an error, it's *silence with no error* — much worse than a transcode.
    /// FLAC is excluded despite usually working: it has known edge cases here, and nothing in this
    /// library is FLAC.
    public static let nativelyPlayable: Set<String> = ["mp3", "m4a", "mp4", "aac", "alac", "wav", "aif", "aiff"]

    /// Whether a track has to be transcoded to play. Unknown or absent suffix ⇒ `true`:
    /// transcoding something that didn't need it costs CPU, while failing to transcode something
    /// that did costs silence, so the ambiguous case takes the safe side.
    public static func needsTranscode(suffix: String?) -> Bool {
        guard let suffix, !suffix.isEmpty else { return true }
        return !nativelyPlayable.contains(suffix.lowercased())
    }

    // MARK: - Satisfying a seek

    public enum Strategy: Equatable {
        /// The target is reachable in the current item — let AVPlayer do it. Instant, no re-buffer.
        case direct
        /// Not reachable in this stream — re-request it starting at `offset` seconds.
        case reload(offset: TimeInterval)
    }

    /// Slack when testing a target against a seekable range. Small, because erring optimistically
    /// reproduces the original bug.
    public static let reachableTolerance: TimeInterval = 0.5

    /// How to satisfy a seek to `target` (in track-logical seconds).
    ///
    /// `seekableRanges` is `AVPlayerItem.seekableTimeRanges` in **stream-local** seconds. That is
    /// the API built for precisely this question, and it answers it correctly in every case here
    /// without guessing: a byte-range-capable stream reports the whole asset, while a cold chunked
    /// transcode reports only what has arrived. So a scrub backwards or a nudge a few seconds
    /// ahead stays `.direct` and costs nothing, and only a genuinely unreachable target reloads.
    ///
    /// Empty ranges mean "not known to be reachable" and reload — the safe direction, since a
    /// wrong `.direct` is the bug and a wrong `.reload` merely re-buffers.
    ///
    /// - Parameter streamStartOffset: how many track-seconds this stream's zero represents,
    ///   for a stream already fetched with `timeOffset`.
    public static func strategy(
        target: TimeInterval,
        seekableRanges: [ClosedRange<TimeInterval>],
        streamStartOffset: TimeInterval = 0
    ) -> Strategy {
        let local = target - streamStartOffset
        // Behind this stream's start is unreachable no matter how much is buffered.
        guard local >= -reachableTolerance else { return .reload(offset: max(0, target)) }
        let reachable = seekableRanges.contains {
            local >= $0.lowerBound - reachableTolerance && local <= $0.upperBound + reachableTolerance
        }
        return reachable ? .direct : .reload(offset: max(0, target))
    }

    // MARK: - Telling a real end from a failed seek

    /// How close to the end still counts as a genuine end.
    ///
    /// Much looser than `TrackBoundary`'s 0.35 s: a transcode's clock drifts a little from the
    /// metadata duration, and the costs are asymmetric — mistaking a real end for a spurious one
    /// stalls playback, while the case being caught here is an end reported *minutes* early. Several
    /// seconds of slack separates those comfortably.
    public static let spuriousEndTolerance: TimeInterval = 5.0

    /// Whether an end-of-item notification is believable given where the playhead actually is.
    ///
    /// A cold transcode reports EOF when a seek runs off the end of what it has encoded so far,
    /// and at the notification that is indistinguishable from the track finishing. The playhead
    /// tells them apart: a real end happens *at* the end. Anything else is a failed seek, and
    /// advancing the queue for it is the bug.
    ///
    /// Unknown duration ⇒ `true`. With no end to compare against there is no evidence the end is
    /// spurious, and refusing to advance would strand the queue — a worse failure than the one
    /// being guarded against.
    public static func isGenuineEnd(currentTime: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration > 1 else { return true }
        return TrackBoundary.isAtEnd(currentTime: currentTime, duration: duration,
                                     tolerance: spuriousEndTolerance)
    }

    // MARK: - Which duration to trust

    /// The track-logical duration, given what the asset reports and what the server said.
    ///
    /// **An offset stream's duration must be ignored.** A `timeOffset` stream reports the *whole*
    /// track's length rather than the remainder, so treating it as the remainder and adding the
    /// offset back inflates the track a little more with every seek. Measured live: a 4798 s set
    /// read 5502 s after one seek and 6325 s after two — exactly `4798 + offset` each time. A
    /// scrubber that rescales under the listener sends the next click somewhere they didn't aim,
    /// and eventually past the real end, where it reads as a skip.
    ///
    /// The server's metadata length is authoritative for the logical track. Nothing an offset
    /// stream reports can improve on it, so at any offset the metadata simply stands.
    public static func logicalDuration(assetSeconds: Double?, metadata: Double, streamStartOffset: Double) -> Double {
        guard streamStartOffset <= 0 else { return metadata }
        guard let assetSeconds, assetSeconds.isFinite, assetSeconds > 1 else { return metadata }
        return assetSeconds
    }

    // MARK: - Building the stream URL

    /// Below this an offset isn't worth a reload, and `timeOffset` is whole seconds anyway.
    public static let minimumOffset: TimeInterval = 1

    /// Rewrite a stream URL to start at `offset` seconds and/or to skip the transcode.
    ///
    /// A URL transform rather than a change to `streamURL(songID:)`, for the same reason
    /// `annotate(_:with:)` is one: the *controller* is what knows the track's format and the
    /// playhead, while the client only ever sees an id. Keeping it here also keeps it pure.
    ///
    /// Any existing `timeOffset` is replaced, never appended — Subsonic takes the first occurrence,
    /// so appending would silently pin every later seek to the first one.
    public static func streamURL(_ url: URL, offset: TimeInterval = 0, transcode: Bool = true) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (parts.queryItems ?? []).filter { $0.name != "timeOffset" }
        // `format=mp3` is what forces the transcode; without it Navidrome serves the stored file.
        if !transcode { items.removeAll { $0.name == "format" } }
        if offset >= minimumOffset { items.append(URLQueryItem(name: "timeOffset", value: String(Int(offset)))) }
        parts.queryItems = items.isEmpty ? nil : items
        return parts.url ?? url
    }
}
