import BatonSubsonicModels
import Foundation

/// Turning "songs like this one" into a queue.
///
/// Ten call sites across the two apps built this by hand and disagreed three ways:
///
/// - **The seed.** The phone put it first and then removed it from the similar list;
///   the Mac wrote `[song] + radio` and removed nothing, so whenever the server returned
///   the seed among its own similar songs — which Navidrome does — the track you started
///   from played twice, a few minutes apart.
/// - **The label.** "Absolutely Radio" on the Mac, "Radio · Absolutely" on the phone, and
///   plain "Radio" in a third place. Same feature, three names in the now-playing source.
/// - **The empty case.** Some sites played nothing when the server had no similars; others
///   fell back to the collection. Doing nothing on a tap is indistinguishable from a bug.
///
/// Note the direction of that drift: the *phone* had the careful version. It is worth
/// saying because the obvious assumption — the older platform is the more correct one —
/// was wrong here, and the sweep would have made things worse if it had been followed.
public enum RadioQueue {
    /// The queue a "start radio from this" action should play.
    ///
    /// - Parameters:
    ///   - seed: the track the radio was started from. Plays first, so the tap has an
    ///     immediate audible result rather than a pause while similars resolve.
    ///   - similar: what the server suggested. Pass this already filtered for bans; this
    ///     type has no opinion about what you have blocked.
    ///   - fallback: what to play when there are no similars at all — usually the
    ///     collection the action was invoked from. Empty means "do nothing".
    public static func build(seed: NavidromeSong?,
                             similar: [NavidromeSong],
                             fallback: [NavidromeSong] = []) -> [NavidromeSong] {
        guard let seed else {
            return similar.isEmpty ? fallback : dedupe(similar)
        }
        let rest = dedupe(similar).filter { $0.id != seed.id }
        if rest.isEmpty { return fallback.isEmpty ? [seed] : fallback }
        return [seed] + rest
    }

    /// The now-playing source label. One spelling, so the queue header reads the same
    /// wherever the radio was started from.
    public static func label(_ name: String) -> String { "\(name) Radio" }

    /// A server can return the same track twice across paged similarity results; keeping
    /// both would put it in the queue twice for a reason no listener could guess.
    private static func dedupe(_ songs: [NavidromeSong]) -> [NavidromeSong] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }
}
