#if !(os(macOS) || os(iOS))

import Foundation
import BatonDSP
import BatonSubsonicModels

/// The engine deck, on a platform that cannot have one.
///
/// watchOS has no `AudioToolbox`, so no `AudioFileStream`, so no decoder and no engine. The
/// watch app plays **downloaded files** and never library streams, which route to AVPlayer
/// on every platform anyway — so nothing is lost there.
///
/// This exists so `StreamingPlaybackController` needs no `#if` at all. Its engine surface is
/// consulted at a dozen call sites; guarding each one would scatter conditional compilation
/// through the policy layer and produce exactly the drift this codebase keeps being bitten
/// by — nine Shuffle call sites, eleven layout keys, twelve now-playing indicators. One
/// stand-in, twelve untouched call sites.
///
/// **It cannot be constructed**, which is the point: `canPlay` is always false, no host
/// installs a provider on the watch, and `engineDeck` stays nil forever. Every
/// `if engineOwnsPlayback` branch is simply dead code there.
///
/// Kept honest by the build, not by discipline: `scripts/test.sh` builds the watch app, so
/// a method added to the real `EngineDeckBridge` and used by the controller fails the gate
/// here until it is mirrored. That is the whole reason the watch build is in the gate — the
/// engine merge broke this target and nobody noticed, because the gate only built one app.
@MainActor
public final class EngineDeckBridge: PlaybackDeck {
    public var onClock: (@MainActor (TimeInterval, TimeInterval, Bool) -> Void)?
    public var onEnded: (@MainActor () -> Void)?
    public var onFailure: (@MainActor (String) -> Void)?

    private init() {}

    /// Never. The watch has no engine, and saying so here is what keeps the routing branch
    /// in `StreamingPlaybackController` dead rather than absent.
    public nonisolated static func canPlay(songID: String, url: URL) -> Bool { false }

    public func load(song: NavidromeSong, url: URL, startingAt offset: TimeInterval,
                     autoplay: Bool, headers: [String: String], supportsTimeOffset: Bool) {}
    public func pause() {}
    public func resume() {}
    public func seek(to seconds: TimeInterval) {}
    public func stop() {}

    public func applyLevel(volumePercent: Int, isMuted: Bool, envelope: Float) {}
    public func applyLoudness(mode: StreamingPlaybackController.LoudnessMode, preampDB: Double) {}
    public func setPlaybackRate(_ rate: Float) {}
    public func applyEQ(bands: [EQBand], enabled: Bool) {}
    public func startMetering(into snapshot: LevelSnapshot) {}
    public func stopMetering() {}
    public func suspendMetering() {}
    public func resumeMetering() {}
    public func setStallTimeout(_ seconds: Double) {}
}

#endif
