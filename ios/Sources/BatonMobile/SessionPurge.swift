import Foundation

/// Removes every trace of a signed-in account from this device.
///
/// `disconnect()` used to clear the server config and the in-memory collections, which
/// looks complete and isn't: the downloaded audio, the play history, the pending scrobble
/// outbox, radio bans, the model-provider key and the Last.fm session all lived on disk and
/// survived. Two of those are genuinely wrong rather than merely untidy — a previous
/// account's music stays playable, and the outbox will deliver *their* listens to whichever
/// scrobble account is configured next.
///
/// Modelled on KeepFloat's `AppState.purgeLocalData()`. The shape matters: **one function
/// that names every store**, so a store added later shows up as a missing line here rather
/// than as a silent leak nobody notices for a year.
@MainActor
enum SessionPurge {
    /// Keychain accounts holding this session's secrets. Enumerated rather than
    /// pattern-matched: deleting Keychain items by prefix is how you delete something you
    /// didn't mean to.
    private static let secretAccounts = [
        "baton.agent.apiKey",
        "baton.agent.gatewayToken",
        "tonebox.music.lastfm.apiKey",
        "tonebox.music.lastfm.apiSecret",
        "tonebox.music.lastfm.sessionKey",
        "tonebox.music.listenBrainzToken",
    ]

    /// `UserDefaults` keys that are this account's data or configuration.
    ///
    /// Deliberately kept: `baton.whatsNew.lastShownVersion` (a UI marker — re-showing the
    /// changelog to the same person on the same phone is just wrong), and the playback
    /// preferences a person sets for *their ears* rather than their account (EQ, crossfade),
    /// which survive precisely because they aren't account data.
    private static let defaultsKeys = [
        "baton.agent.route",
        "baton.agent.provider",
        "baton.agent.model",
        "baton.agent.baseURL",
        "baton.agent.gatewayURL",
        "baton.agent.verifiedFingerprint",
        "baton.agent.speakReplies",
        "tonebox.music.playHistory",
        "tonebox.music.radioBans",
        "tonebox.music.scrobbleQueue",
        "tonebox.music.scrobbleExternalSource",
        "tonebox.music.listenBrainzToken",
        "tonebox.music.lastfm.apiKey",
        "baton.personalization.applied",
        "baton.personalization.rationale",
        "baton.speech.history",
        "baton.demoMode",
        // Which History scope is showing is a fact about the *account* — "All devices"
        // means that server's record. Carrying it into the next sign-in shows the new
        // account a scope chosen for the old one, and silently defeats the default.
        "baton.history.scope",
    ]

    /// Clears the account's stores without needing a live `MobileModel`.
    ///
    /// Used at launch by the test-only reset argument, before anything has been
    /// constructed. `purge(_:keepDownloads:)` is the user-facing path and stops the player
    /// first; this one runs when there is no player yet.
    static func wipeStores() {
        let defaults = UserDefaults.standard
        for key in defaultsKeys { defaults.removeObject(forKey: key) }
        for account in secretAccounts { NavidromeKeychain.setSecret("", account: account) }
        NavidromeConfig.clear()
    }

    /// What a purge is about to remove, so the confirmation can say it out loud.
    struct Preview {
        var downloadCount: Int
        var downloadBytes: Int64
        var historyCount: Int

        var hasDownloads: Bool { downloadCount > 0 }

        /// "12 downloads (86 MB)" — nil when there are none.
        var downloadSummary: String? {
            guard downloadCount > 0 else { return nil }
            let size = ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
            return "\(downloadCount) \(downloadCount == 1 ? "download" : "downloads") (\(size))"
        }
    }

    static func preview(_ model: MobileModel) -> Preview {
        let items = MusicDownloadStore.shared.downloadedItems()
        return Preview(
            downloadCount: items.count,
            downloadBytes: items.reduce(0) { $0 + $1.byteSize },
            historyCount: model.history.entries.count
        )
    }

    /// Wipes the session.
    ///
    /// `keepDownloads` exists because deleting someone's offline music is the one
    /// irreversible part of this, and "I want to switch servers" and "erase my music" are
    /// different intentions. The caller asks; this doesn't assume.
    static func purge(_ model: MobileModel, keepDownloads: Bool) {
        // Stop first: tearing state out from under a playing engine is how you get a
        // half-dead player holding a file that no longer exists.
        model.music.stop()
        model.music.clearQueue()

        if !keepDownloads {
            MusicDownloadStore.shared.deleteAll()
        }
        // The prefetch cache is derived data for tracks we may no longer be able to reach.
        MusicGaplessCache().clear()

        model.history.clear()
        model.radioBans.clear()
        model.pins.clear()
        model.podcastProgress.clear()
        model.handoff.clear()
        model.scrobbles.purgeQueue()
        model.lastfm.disconnect()
        model.listenBrainz.token = ""

        // Server config + its per-server secret.
        NavidromeConfig.clear()
        model.musicLibrary.resetForServerChange()

        for account in secretAccounts { NavidromeKeychain.deleteSecret(account: account) }
        for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }

        // The agent's readiness is derived from those keys; drop the cached verification so
        // the Friend tab can't outlive the configuration that earned it.
        model.agentConfig.invalidateVerification()

        // Widgets read a shared snapshot — leave it showing a stranger's track and it will.
        // Publishing nil is the existing "nothing is playing" path; it also ends any
        // Live Activity, which would otherwise outlive the session on the Lock Screen.
        WidgetBridge.publish(song: nil, isPlaying: false, artworkURL: nil)
    }
}
