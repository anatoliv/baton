import BatonSubsonicKit
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
        // Podcast subscriptions, both halves: the ledger that can say "unsubscribed" and
        // the plain feed list an older build still reads. Removed rather than unsubscribed
        // one by one, because an unsubscribe writes a tombstone that syncs — this device is
        // being wiped, which is not a statement about the Mac's shows.
        PodcastSubscriptionStore.ledgerKey,
        PodcastSubscriptionStore.syncedFeedsKey,
        // Which albums and artists the previous account opened from Search, and the ids
        // they resolve to. Removed for the same reason as the play history.
        SearchRecents.storageKey,
    ]

    /// Clears the account's stores without needing a live `MobileModel`.
    ///
    /// Used at launch by the test-only reset argument, before anything has been
    /// constructed. `purge(_:keepDownloads:)` is the user-facing path and stops the player
    /// first; this one runs when there is no player yet.
    static func wipeStores() {
        let defaults = BatonStorage.defaults
        for key in defaultsKeys { defaults.removeObject(forKey: key) }
        // `deleteSecret`, not `setSecret("")`. Blanking left an empty Keychain item behind,
        // so this path and the user-facing one below did not leave the device in the same
        // state — which is exactly the difference that lets a test pass where the product
        // would not.
        for account in secretAccounts { NavidromeKeychain.deleteSecret(account: account) }
        NavidromeConfig.clear()
        // The file-backed stores, for the same parity reason: a reset that leaves last
        // session's podcasts and clippings on disk is not a reset.
        PodcastSubscriptionStore().purgeLocalSubscriptions()
        removeAllClippings(ClippingStore())
        FriendFeedbackLog().clear()
    }

    /// Deletes every clipping from *this device*.
    ///
    /// `everywhere: false` and `dismissing: false` on purpose. "Delete everywhere" would
    /// reach through the shared ledger and remove the same recordings from the Mac, and a
    /// dismissal tombstone is a statement about a device that is about to have no session
    /// at all. Both would outlive the account being erased.
    private static func removeAllClippings(_ store: ClippingStore) {
        store.loadIfNeeded()
        for item in store.items {
            store.remove(id: item.id, dismissing: false, everywhere: false)
        }
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

        // And stop the gateway link before the token it is holding is deleted. The link was
        // the one live connection this function did not name: it read the gateway token once
        // into a local and then held an authenticated long-poll open, so after "Disconnect
        // and delete my data" a foregrounded app went on presenting the revoked credential
        // and running whatever commands came back against the local player. It only stopped
        // when the app was backgrounded.
        model.deviceLink.stop()

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

        // Search history carries the previous account's queries and the album and artist ids
        // they opened, and it is the first thing the next sign-in would show.
        model.searchRecents.clear()
        // Subscriptions, locally. See `PodcastSubscriptionStore.purgeLocalSubscriptions`.
        model.podcastSubscriptions.purgeLocalSubscriptions()
        // What the friend was asked and what it did. The friend's *memory* and its learned
        // corrections deliberately stay: both live in the shared `baton.friend.ledger`, so
        // clearing them here would publish tombstones that delete the same memories on the
        // user's other devices. Whether a disconnect should forget them at all is TBX-5230,
        // which is a product decision and not this function's to make.
        model.friendLog.clear()

        // Clippings are audio the user recorded themselves, so they go with the downloads
        // rather than with the account: "switch servers" and "erase my recordings" are
        // different intentions, and only one of them is irreversible.
        if !keepDownloads {
            removeAllClippings(model.clippings)
        }

        // Server config + its per-server secret.
        NavidromeConfig.clear()
        model.musicLibrary.resetForServerChange()

        for account in secretAccounts { NavidromeKeychain.deleteSecret(account: account) }
        for key in defaultsKeys { BatonStorage.defaults.removeObject(forKey: key) }

        // After the keys are gone, not before. `SearchRecents.clear()` removes only this
        // server's entries and keeps the rest in memory, so the next thing recorded would
        // write the whole list straight back over the key we just deleted.
        model.searchRecents.reload()

        // The agent's readiness is derived from those keys; drop the cached verification so
        // the Friend tab can't outlive the configuration that earned it.
        model.agentConfig.invalidateVerification()

        // Widgets read a shared snapshot — leave it showing a stranger's track and it will.
        // Publishing nil is the existing "nothing is playing" path; it also ends any
        // Live Activity, which would otherwise outlive the session on the Lock Screen.
        WidgetBridge.publish(song: nil, isPlaying: false, artworkURL: nil)
    }
}
