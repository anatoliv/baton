import BatonPlaybackKit
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
        "baton.documents.enabled",
        // Voice the dialogue's starting point: the models that write a cast include
        // the account's Baton server, so a new session starts with it off, and a UI test's
        // choice does not carry into the next test.
        "baton.documents.voiceTheDialogue",
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
        // This phone's book storage: its rules, the books marked Keep and the suggestions
        // already answered (M6.3 to M6.5). Gone with the books they were about.
        BookStorage.settingsKey,
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
        // A document waiting for its import screen from the last session.
        PendingImportStore.shared.clear()
        // The friend's memory and corrections too, the same way `purge` does it below
        //: tombstoned into the shared ledger first, so a reset on one device
        // cannot be undone by the next sync. This path had the same hole the card was filed
        // for, and a UI fixture that "reset" the session still met last run's memories.
        RemoteMemoryStore().forgetEverything()
        FriendLearningStore().forgetAll()
        #if DEBUG
        // The review-prompt gate is versioned state (which days counted, which version was
        // already asked), not account data, so it isn't in `defaultsKeys` above. But a UI
        // test that resets the session between runs needs it cleared too: `claimAsk()`
        // permanently spends the prompt for the running app version, `ui-tests.sh` reuses a
        // simulator, and without this a second run against the same container reads as a
        // failure that looks like a regression rather than a leftover from the first
        //. `resetForTesting()` is the seam `ReviewPromptTests` already uses.
        ReviewPrompt.resetForTesting()
        wipeTestLeftovers()
        #endif
    }

    #if DEBUG
    /// `UserDefaults` keys a UI test changes and the next one must not inherit. Not account data,
    /// so the user-facing `purge` keeps them; a test reset clears them.
    static let testLeftoverDefaultsKeys = [
        // The speed for speech. One suite chose 1.5× and the next found it there instead of 1×.
        StreamingPlaybackController.spokenRateKey,
        // Clipping names by audio digest, and whether the ledger was seeded from disk. The
        // clippings themselves are removed above; their names would outlive them here.
        ClippingLedger.storageKey,
        ClippingStore.ledgerSeededKey,
        // "Use this model for my books": a recap test that allows the cloud would allow it for
        // every later test.
        ModelConsentLedger.grantedKey,
        ModelConsentLedger.declinedKey,
        // The narrator last chosen per language: a suite that chose Emma would
        // start the next suite's import on Emma.
        VoiceChoiceMemory.storageKey,
    ]

    /// What the reset used to leave behind: the `Books` folder with every book
    /// record sent to a home server, the books hidden from this device, deletes still owed, the
    /// shaped books, read-along timing and voice changes; the clippings dismissed from this
    /// device; and the defaults above. A record left from an earlier suite was asked about on
    /// every watch round, against a home server that had never heard of it: several times the
    /// status reads, and its error replaced the reason the next screen was meant to show.
    private static func wipeTestLeftovers() {
        let defaults = BatonStorage.defaults
        for key in testLeftoverDefaultsKeys { defaults.removeObject(forKey: key) }
        let files = FileManager.default
        try? files.removeItem(at: BatonStorage.supportSubdirectory("Books"))
        // Dismissed by digest, and a chapter made again from the same words has the same digest.
        let dismissed = BatonStorage.supportSubdirectory("Clippings").appendingPathComponent(ClippingStore.dismissedFileName)
        try? files.removeItem(at: dismissed)
        try? files.removeItem(at: dismissed.appendingPathExtension("bak"))
    }
    #endif

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
        // Deleted books wait a week in Recently removed with their audio held (M6.3); that
        // audio is clipping audio too, and a purge that left it would leave a book behind.
        let books = BatonStorage.supportSubdirectory("Books")
        try? FileManager.default.removeItem(at: books.appendingPathComponent("recently-removed", isDirectory: true))
        try? FileManager.default.removeItem(at: books.appendingPathComponent("recently-removed.json"))
    }

    /// Books on "Disconnect and delete my data" (TBX-1000000505 B-16, owner decision 2026-10-21).
    ///
    /// The books hidden from this device and the deletes still owed to the old server always go:
    /// they are the account's, and the next server has never heard of them. The downloaded books
    /// themselves follow Keep downloads, as music downloads and clippings do: kept with it (their
    /// audio is clippings, kept by the caller; their records and covers here), gone without it,
    /// with everything else of them in `directory` (shaped books, read-along timing, voice changes).
    static func purgeBooks(_ books: HomeServerBooks, covers: BookCoverStore, directory: URL, keepDownloads: Bool) {
        for documentID in books.hiddenDocumentIDs { books.unhide(documentID: documentID) }
        let owed = directory.appendingPathComponent("home-server-books-pending-deletes.json")
        try? FileManager.default.removeItem(at: owed)
        try? FileManager.default.removeItem(at: owed.appendingPathExtension("bak"))
        guard !keepDownloads else { return }
        for record in books.records { books.forget(jobID: record.jobID) }
        for documentID in Array(covers.entries.keys) { covers.forget(documentID: documentID) }
        // Everything else of them in the folder, apart from the covers folder itself: the cover
        // store made it when it started and does not make it again, so without it the next
        // cover set before a relaunch would fail. Its entries are forgotten above.
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: directory.path)) ?? [] where name != "covers" {
            try? files.removeItem(at: directory.appendingPathComponent(name))
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
        // And the books watch: a listing still out with the old token could adopt the old
        // server's books again after the hidden marks below are cleared (TBX-1000000505 B-16).
        model.books.stopWatching()

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
        // What the friend was asked and what it did, plus what it remembers and what it has
        // learned from being corrected. TBX-5230 (owner decision, 2026-09-09): "Disconnect
        // and delete my data" means all of it, including the friend — a person who asks
        // Baton to forget them should not find the friend still repeating what they told it
        // on a server they no longer use. `forgetEverything` / `forgetAll` tombstone every
        // entry into the shared `baton.friend.ledger` before clearing the local copy, so a
        // later sync adopts the tombstones (this device said "forgotten") instead of a peer
        // that still holds the old rows pushing them straight back.
        model.friendLog.clear()
        model.friendMemory.forgetEverything()
        model.friendLearning.forgetAll()

        // A document shared just before signing out, still waiting for its import screen
        //. It is kept on disk to survive a relaunch, so without this it came back
        // after the sign-out. Unlike clippings it is not the user's recording but
        // an import that never happened, so it goes whether or not downloads are kept.
        model.pendingDocumentImport = nil
        PendingImportStore.shared.clear()

        // Clippings are audio the user recorded themselves, so they go with the downloads
        // rather than with the account: "switch servers" and "erase my recordings" are
        // different intentions, and only one of them is irreversible.
        if !keepDownloads {
            removeAllClippings(model.clippings)
        }
        // Books: their records and covers follow Keep downloads; hidden marks and the deletes
        // owed to the old server always go (TBX-1000000505 B-16).
        purgeBooks(model.books, covers: model.covers.store, directory: BatonStorage.supportSubdirectory("Books"),
                   keepDownloads: keepDownloads)

        // Server config + its per-server secret.
        NavidromeConfig.clear()
        model.musicLibrary.resetForServerChange()

        for account in secretAccounts { NavidromeKeychain.deleteSecret(account: account) }
        for key in defaultsKeys { BatonStorage.defaults.removeObject(forKey: key) }
        // Those removals wipe this device; they are not edits to the shared settings. Without
        // this each one was a stamped change of a key held at the last sync, and the next sync
        // announced them all as deleted and the Mac removed its own copies (TBX-1000000480 B-1).
        model.preferenceSync.forgetLocalHistory()

        // After the keys are gone, not before. `SearchRecents.clear()` removes only this
        // server's entries and keeps the rest in memory, so the next thing recorded would
        // write the whole list straight back over the key we just deleted.
        model.searchRecents.reload()

        // The agent's settings, its verification included, were read into memory at launch;
        // re-read them so the gateway address and token cannot outlive their storage and the
        // Friend tab cannot outlive the configuration that earned it. And stop the heartbeat,
        // which would otherwise go on syncing with them.
        model.agentConfig.reload()
        model.stopSyncHeartbeat()

        // Widgets read a shared snapshot — leave it showing a stranger's track and it will.
        // Publishing nil is the existing "nothing is playing" path; it also ends any
        // Live Activity, which would otherwise outlive the session on the Lock Screen.
        WidgetBridge.publish(song: nil, isPlaying: false, artworkURL: nil)
    }
}
