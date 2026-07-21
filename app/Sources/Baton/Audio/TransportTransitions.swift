import Foundation

/// The pure math + timing behind a **crossfade** transition, factored out of
/// `StreamingPlaybackController` as a narrow collaborator. The controller still owns the
/// two `AVQueuePlayer`s and the async ramp loop; this owns *when* a fade should start and *what
/// gains* to apply at each step — the parts that are pure and can be unit-tested without
/// AVFoundation or on-device playback. (The gap-free audio itself still needs device validation.)
enum Crossfade {
    /// Whether the playhead has entered the crossfade window for a track of `duration`. Pure
    /// timing only — the caller adds the transport-state guards (playing, not already fading, not
    /// a podcast). A track must be longer than the window + 1 s to fade at all, so a very short
    /// track hard-cuts rather than fading across most of its length.
    static func inWindow(currentTime: Double, duration: Double, window: Double) -> Bool {
        window > 0 && duration > window + 1 && currentTime >= duration - window
    }

    /// The `(outgoing, incoming)` volumes at step `i` of `steps` across the ramp: the outgoing
    /// track fades `startOut → 0` while the incoming rises `0 → targetIn`, linearly in `t = i/steps`.
    static func gains(step i: Int, of steps: Int, startOut: Float, targetIn: Float) -> (out: Float, in: Float) {
        let t = Float(i) / Float(steps)
        return (startOut * (1 - t), targetIn * t)
    }
}

/// The pure decisions behind the **gapless** next-track preload, factored out of the controller
///. The controller owns the `AVQueuePlayer` insert + the prefetch task; this owns the two
/// choices that are pure: whether a metered connection permits pre-caching, and which URL to
/// preload for a gap-free handoff.
enum GaplessPreload {
    /// Whether to prefetch the next stream to disk, given the user's "Wi-Fi only" preference and
    /// whether the connection is metered. Streaming still works when this is false — the next
    /// track just isn't pre-cached, leaving a small buffer at the seam instead of zero-gap.
    static func shouldPrefetch(wifiOnly: Bool, metered: Bool) -> Bool {
        !(wifiOnly && metered)
    }

    /// The URL to preload for the next track. An already-local file (an offline download, which
    /// the stream resolver returns as a `file:` URL) or a previously-prefetched cache file is
    /// preferred over the live stream, so the boundary is a gap-free local handoff.
    static func preloadURL(stream: URL, cached: URL?) -> URL {
        stream.isFileURL ? stream : (cached ?? stream)
    }
}

/// The pure **fade envelope** ramp used by the sleep-timer fade-out (and any timed volume fade),
/// factored out of the controller. The controller owns the `Task` loop + the sleep between
/// steps; this owns the interpolation, so the curve is unit-testable.
enum Fade {
    /// The fade multiplier at step `i` of `steps`, linearly interpolated `start → target`.
    /// At `i == steps` it lands exactly on `target`.
    static func multiplier(step i: Int, of steps: Int, start: Float, target: Float) -> Float {
        start + (target - start) * Float(i) / Float(steps)
    }
}

/// The pure composition of the **effective player volume**, factored out of `applyVolume`:
/// the user's level, the current track's loudness-normalization multiplier, and the fade envelope,
/// multiplied together. Mute is handled separately (`player.isMuted`), so it isn't a factor here.
enum PlaybackVolume {
    /// The 0…N volume to push to AVPlayer. `percent` is the user's 0–100 level; `loudness` is the
    /// ReplayGain-derived multiplier (can exceed 1 within the clamp); `fade` is the 0…1 envelope.
    static func effective(percent: Int, loudness: Float, fade: Float) -> Float {
        Float(percent) / 100 * loudness * fade
    }
}

/// The pure decision behind **resume-from-saved-position** (podcasts), factored out of the
/// controller. Only resume when the saved offset is meaningfully into the track and not
/// essentially finished — otherwise start from the top, so a stale near-start or near-end offset
/// doesn't drop you into silence or replay the last few seconds.
enum PlaybackResume {
    /// Resume at `offset` only if it's past the first 2 s and before the last 5 s of `duration`.
    static func shouldResume(offset: Double, duration: Double) -> Bool {
        duration > 1 && offset > 2 && offset < duration - 5
    }
}

/// The pure **end-of-track boundary** test, centralised from the three controller sites that each
/// hand-rolled it. A wrong boundary is a correctness bug — too early clips the track, too
/// late leaves the transport parked showing "playing" — so it's worth one tested definition:
/// within `tolerance` (0.35 s) of a known-duration track's end.
enum TrackBoundary {
    /// Whether the playhead (or a seek target) has effectively reached the track's end. Requires a
    /// known duration (> 1 s); a live stream / unknown-length item has no "end" here.
    static func isAtEnd(currentTime: Double, duration: Double, tolerance: Double = 0.35) -> Bool {
        duration > 1 && currentTime >= duration - tolerance
    }
}
