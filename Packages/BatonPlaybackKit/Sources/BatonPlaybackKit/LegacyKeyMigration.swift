import Foundation

/// Moving settings from the `tonebox.*` namespace to `baton.*`, once, without losing any.
///
/// The app was lifted out of Tonebox and kept its defaults keys. Renaming them is pure
/// hygiene — no user gains anything — while *getting it wrong* costs somebody their server
/// or their listening history. So this migrates only what is safe to migrate, and the list
/// of what it deliberately does not touch is the important part of this file.
///
/// **Not migrated, and why:**
///
/// - **`PreferenceSync.syncedKeys`** — these are an interop contract with the gateway *and*
///   with the user's other device. Rename them on the Mac and an updated Mac stops syncing
///   with a phone that has not updated yet: silently, until both are on the new build. A
///   cross-device rename needs both ends to read old and new for a release before either
///   stops writing the old, which is a migration of its own.
/// - **`tonebox.navidromeSecret`** — a *Keychain* service name, not a defaults key. Renaming
///   it strands the stored password: the app would show a configured server it can no longer
///   sign in to.
/// - **Server config, credentials, history and the scrobble queue** —
///   `tonebox.navidrome.servers`, `.url`, `.username`, the Last.fm and ListenBrainz tokens,
///   `tonebox.music.playHistory`, `tonebox.music.scrobbleQueue`. A missed key here is not a
///   reset preference, it is data the user cannot get back. They are worth migrating one
///   day, with a release of their own and time to soak — not in the same change as twenty
///   cosmetic renames, and not immediately before a release.
/// - **`.tonebox-downloads*.json` and the cache directories** — on-disk names. Renaming them
///   orphans every file a user has already downloaded unless the files move too, which is a
///   filesystem migration with its own failure modes.
/// - **`io.tonebox.baton*`** — the bundle identifier, App Group, and MCP service names.
///   These cannot change at all without breaking code signing, the widget's shared
///   container, and every MCP client config already pointing at this app.
///
/// What is left is inert UI state: which layout a screen is on, whether a rail is collapsed.
/// A missed key there costs somebody one re-tap of a toggle.
public enum LegacyKeyMigration {
    /// Marks the migration done, so a user who deliberately resets a migrated setting does
    /// not have the old value copied back over it on next launch.
    static let completedKey = "baton.migration.legacyKeys.v1"

    /// Old → new, for keys where a failure is cosmetic.
    ///
    /// Written out rather than derived by string substitution: a rule like "replace the
    /// prefix" silently drags in every key added later, including the dangerous ones, and
    /// the whole point here is that the set is chosen rather than matched.
    public static let inertKeys: [String: String] = [
        "tonebox.music.railCollapsed": "baton.music.railCollapsed",
        "tonebox.music.barCollapsed": "baton.music.barCollapsed",
        "tonebox.miniPlayer.expanded": "baton.miniPlayer.expanded",
        "tonebox.music.hideAutoImports": "baton.music.hideAutoImports",
        "tonebox.music.reactiveNowPlayingBars": "baton.music.reactiveNowPlayingBars",
        "tonebox.music.localLogEnabled": "baton.music.localLogEnabled",
        // `tonebox.filterHistorySize` was in this list until the guard test rejected it: it
        // reaches `PreferenceSync.syncedKeys` as `FilterHistory.sizeKey` rather than as a
        // string literal, so grepping the sync list for quoted keys does not find it. That
        // is precisely the shape of mistake a hand-audited rename makes, and why the test
        // asserts against the real set instead of against a list someone eyeballed.
    ]

    /// Copies each old value to its new key, once. Old values are left in place: a rollback
    /// to a previous build should find its settings where it left them.
    public static func run(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completedKey) else { return }
        for (old, new) in inertKeys {
            guard defaults.object(forKey: new) == nil,
                  let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: new)
        }
        defaults.set(true, forKey: completedKey)
    }
}
