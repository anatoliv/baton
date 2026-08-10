import Foundation

/// The browse screens that remember how you like to look at them, and the defaults keys
/// they remember it in.
///
/// There were twelve of these spelled out by hand on the Mac — `"tonebox.music.albumLayout"`,
/// `"tonebox.music.folderLayout"`, and so on — while the phone had already grown a helper.
/// A hand-spelled key is not caught by anything: a typo compiles, runs, and silently gives
/// that screen its own orphan key, so the setting appears to work and then forgets itself on
/// the next launch. Nothing fails, nobody files it, and the screen just feels slightly broken.
///
/// (These are **not** synced between devices — no layout key appears in
/// `PreferenceSync.syncedKeys`, and that is deliberate: a 13-inch Mac and a 6-inch phone want
/// different densities, so syncing would guarantee one of them is wrong. Worth stating,
/// because a plausible-sounding "a typo resets your other device" is the kind of reasoning
/// that gets written down and then believed.)
public enum BrowseScreen: String, CaseIterable, Sendable {
    case album, artist, playlist, liked, genre, folder, history
    case download, radio, podcast, clientPodcast, later, mix

    /// Grid ⇄ list. Named to match what the twelve literals already said, so no stored
    /// preference is orphaned by the move — a rename here is a silent reset for every user.
    public var layoutKey: String { "tonebox.music.\(rawValue)Layout" }
    /// Which field a screen sorts by.
    public var sortKey: String { "tonebox.music.\(rawValue)Sort" }
    /// Sort direction.
    public var sortAscendingKey: String { "tonebox.music.\(rawValue)SortAscending" }
}
