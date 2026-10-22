import StoreKit
import BatonShareKit
import SwiftUI
import UIKit

/// The iPhone shell: tabs over the shared library store, with the Now Playing bar
/// floating above the tab bar (the phone-shaped answer to the Mac's bottom bar).
struct RootTabView: View {
    let model: MobileModel
    @State private var showsFullPlayer = false
    @State private var showsWhatsNew = false
    /// When a pending document may take the launch sheet, and the watch that asks again until
    /// it has.
    @State private var importPresentation = ImportPresentation()
    @State private var importWatch: Task<Void, Never>?
    @State private var incomingShareSceneID = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    #if DEBUG
    /// Mirrors the ask for `ReviewPromptUITests`; never present in a shipped build.
    @State private var reviewAskFired = false
    #endif
    /// Paints every screen with the now-playing cover's colors, the way the
    /// Mac's window does (`MusicView` — "whole-window color-from-artwork
    /// wash"). The phone previously did this only inside the full player, so
    /// every tab was flat black while the Mac's whole window took its color
    /// from the track.
    @State private var paletteLoader = ArtworkPaletteLoader()
    @AppStorage(AppearanceSetting.key) private var appearanceRaw = AppearanceSetting.defaultValue.rawValue
    private var appearance: AppearanceSetting {
        AppearanceSetting(rawValue: appearanceRaw) ?? AppearanceSetting.defaultValue
    }

    /// Cover URL at the canonical extraction size, so the phone derives the
    /// *same* accent as the Mac for a given track. Prefers a direct artwork
    /// URL (podcasts) over the Subsonic cover id, and keys on the song id
    /// rather than the cover id — podcast episodes share a nil cover id,
    /// which would leave the wash stuck between episodes.
    private var nowPlayingCoverURL: URL? {
        model.music.nowPlaying?.displayArtworkURL(size: ArtworkColorExtractor.coverSize) { id, size in
            model.musicLibrary.coverArtURL(id: id, size: size)
        }
    }

    var body: some View {
        tabs
            // Alarm and Timer: the editor from any song's menu, and the Clock-style
            // ringing card when one goes off.
            .alarmSheetPresenter(model.alarms)
            .alarmRingingOverlay(model.alarms)
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { Task { await route(url) } }
            }
            .onOpenURL { url in Task { await route(url) } }
            #if DEBUG
            // Which deck is actually rendering, readable from a UI test.
            //
            // "Is it even on the new path?" is the first question of every diagnosis here,
            // and inferring it from side effects is exactly how the now-playing bars looked
            // reactive for a day while reading zeros. A UI test can see that audio plays; it
            // cannot see *which engine* played it, and that is the only thing worth proving
            // about a routing change. DEBUG only — never in a shipped build.
            .overlay(alignment: .topLeading) {
                Text(model.music.engineOwnsPlaybackForTesting ? "engine" : "avplayer")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .accessibilityIdentifier("debug.activeDeck")
                    .allowsHitTesting(false)
            }
            // Whether the rating ask actually fired, for the same reason.
            //
            // The prompt itself is drawn by StoreKit out of process and is reachable from
            // neither the app's element tree nor springboard's, so a UI test cannot see it
            // — an attempt to match on its wording reported "no prompt" while attaching a
            // screenshot with the prompt plainly on screen. What is worth proving is ours
            // anyway: that the gate opened, the deferred re-check accepted the moment, and
            // the ask was spent. Whether Apple then draws pixels is Apple's business.
            .overlay(alignment: .topTrailing) {
                Text(reviewAskFired ? "asked" : "not-asked")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .accessibilityIdentifier("debug.reviewAsk")
                    .allowsHitTesting(false)
            }
            // Which storage domains this process actually resolved, for the same reason as
            // the two above: it is a question about the app's own plumbing that a UI test
            // has no other way to ask.
            //
            // It exists because a caution went on the board saying that under XCUITest the
            // app links XCTest, so `PreferenceSync` and the friend stores would land in
            // *different* `UserDefaults` domains and a UI test could never see friend sync
            // work — while reporting nothing wrong. That was read from the code and never
            // run, and a claim like that gets believed until somebody contradicts it
            // This is how it gets contradicted or confirmed, by measurement.
            //
            // The handshake is a write through one side read back through the other, not a
            // comparison of two objects: two `UserDefaults` instances over the same suite
            // are separate objects, so identity would answer a different question.
            .overlay(alignment: .bottomLeading) {
                Text(StorageReport.line)
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .accessibilityIdentifier("debug.storageDomains")
                    .allowsHitTesting(false)
            }
            // Whether a value passed through `app.launchEnvironment` actually
            // reached this process. `LaunchEnvironmentReliabilityTests` sets a fresh value
            // every launch and reads it back here, N times in a row, to measure the
            // delivery rate directly rather than infer it from a feature's side effects —
            // `-baton.launchProbe` is not read by anything else in the app.
            .overlay(alignment: .bottomTrailing) {
                Text(ProcessInfo.processInfo.environment["baton.launchProbe"] ?? "(absent)")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .accessibilityIdentifier("debug.launchEnvironmentProbe")
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                // An actual PID observation for isolated UI callers, never a
                // model hook or persistent state and absent from release builds.
                if BatonStorage.isProbe, ProcessInfo.processInfo.environment["baton.launchProbe"] != nil {
                    Text(String(ProcessInfo.processInfo.processIdentifier))
                        .font(.system(size: 1)).foregroundStyle(.clear)
                        .accessibilityIdentifier("debug.launchProcessID").allowsHitTesting(false)
                }
            }
            #endif
            .environment(\.nowPlayingPalette, paletteLoader.palette)
            // The user's choice, defaulting to System — the same control the Mac now has,
            // reading the same key. The player sheet stays dark on its own.
            .batonAppearance(appearance)
            .onAppear { paletteLoader.update(url: nowPlayingCoverURL) }
            .onChange(of: model.music.nowPlaying?.id) { _, _ in
                paletteLoader.update(url: nowPlayingCoverURL)
                // A change this soon after the friend put something on is someone reaching
                // for the button, not a track ending — no track is ten seconds long. Logged
                // only; the learning store never sees it.
                model.friendLog.noteQuickSkip()
                // Every track change, however it happened.
                //
                // The Lock Screen card was published from two places — inside
                // `onTrackStarted`, which is deliberately skipped for a continuation, and
                // on `isPlaying` changes. A track advancing on its own is neither, so the
                // card kept the previous song while the system's own Now Playing moved on:
                // two panels on the same screen naming different tracks. `pushNowPlaying`
                // feeds the system one on every change; this is the equivalent for ours.
                WidgetBridge.publish(
                    song: model.music.nowPlaying,
                    isPlaying: model.music.isPlaying,
                    artworkURL: nowPlayingCoverURL,
                    elapsed: model.music.currentTime,
                    duration: model.music.duration
                )
            }
    }

    /// What the launch sheet shows: a document to import first, then What's New.
    private enum LaunchSheet: Identifiable {
        case importDocument(URL)
        case whatsNew

        var id: String {
            switch self {
            case .importDocument(let url): "import:" + url.absoluteString
            case .whatsNew: "whats-new"
            }
        }
    }

    private var launchSheet: LaunchSheet? {
        // The import only once `ImportPresentation` has handed it over: asked for while another
        // sheet is up, UIKit drops it. Until then What's New waits too.
        switch importPresentation.launchContent(pending: model.pendingDocumentImport, whatsNewWanted: showsWhatsNew) {
        case .importDocument(let url): .importDocument(url)
        case .whatsNew: .whatsNew
        case nil: nil
        }
    }

    /// The sheet was closed by the person (Cancel, Done or a swipe down), not swapped.
    /// Marking What's New here rather than only in its Done button: a swipe down is how most
    /// people close a sheet, and it used to leave the marker untouched, so the same notes
    /// came back on every launch for as long as the version lasted.
    private func launchSheetClosed() {
        // Only the person closing the import screen ends the import. A sheet the app took back
        // before it was seen leaves the document pending, to show again.
        switch importPresentation.closed(pending: model.pendingDocumentImport, whatsNewWanted: showsWhatsNew) {
        case .endImport:
            model.pendingDocumentImport = nil
        case .markWhatsNewShown:
            showsWhatsNew = false
            WhatsNewView.markShown()
        case .keepImport, .nothing:
            break
        }
    }

    /// Moves a pending document toward the import screen: shows it when nothing is in
    /// the way, closes what is (waiting for the setup gate and root alerts), and keeps asking
    /// until the screen has appeared. The rules are `ImportPresentation`'s; this is the UIKit
    /// half, which reads what is actually presented rather than what SwiftUI state says.
    ///
    /// Live UIKit state, not this view's `scenePhase`: the watch runs in a Task, which would hold
    /// the value from when it started (see `askForAReviewIfEarned`).
    private func reconcileImport(launchSheetUp: Bool = false) {
        let root = Self.rootController()
        let presented = root?.presentedViewController
        let situation = ImportPresentation.Situation(
            pending: model.pendingDocumentImport,
            isActive: UIApplication.shared.applicationState == .active,
            waitsForGate: model.showsSetup || model.handoff.offer != nil || model.linkFailure != nil,
            otherPresentationUp: presented != nil && !launchSheetUp && importPresentation.shown == nil,
            now: .now)
        switch importPresentation.step(situation) {
        case .idle:
            importWatch?.cancel()
            importWatch = nil
            return
        case .wait, .show:
            break
        case .closeOthers:
            if showsFullPlayer || model.revealedAlbum != nil || model.revealedArtist != nil {
                // Ours: closed through their own state, so they open again with a tap.
                showsFullPlayer = false
                model.revealedAlbum = nil
                model.revealedArtist = nil
            } else if let presented, !presented.isBeingDismissed {
                // Anything else (Settings, a menu's sheet, a picker): the whole stack over the
                // root, which SwiftUI reads as those sheets closing.
                presented.presentingViewController?.dismiss(animated: true)
            }
        }
        guard importWatch == nil else { return }
        importWatch = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { break }
                reconcileImport()
            }
        }
    }

    /// The app window's root, which every sheet in the app is presented over.
    private static func rootController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
            .flatMap(\.windows)
            .filter { !($0 is AlarmRingWindow) }   // the alarm's ringing window is not the app's root
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
    }

    /// Acts on a link or a file handed to the app. What a `baton://` link *means* is decided by
    /// `BatonDeepLink`, a pure function tested as one; `MobileModel.open` carries it out and
    /// reports what happened, so a link that cannot be honoured says so instead of leaving the app
    /// sitting there looking as though nothing was tapped. SwiftUI delivers the link to this
    /// scene; its identity travels with a received song so it is presented here.
    @MainActor private func route(_ url: URL) async {
        // A document from Files, Mail or the share sheet ("Open in Baton"): the import screen,
        // when the feature is on. Copied first, because the handed-over file is ours to read
        // only for a moment (M5.2).
        if url.isFileURL, MobileDocuments.isEnabled(), MobileDocuments.canImport(url) {
            do { model.offerImport(try MobileDocuments.stage(url)) } catch {
                model.linkFailure = "The file could not be opened: \(error.localizedDescription)"
            }
            return
        }
        // A link this app does not claim is not a failure worth a message: it was never
        // ours, and something else on the phone may still handle it.
        // A whole-book link plays in the browser player only.
        if BatonDeepLink.isBrowserOnlyShare(url) { await UIApplication.shared.open(url); return }
        guard let link = BatonDeepLink(url: url) else { return }
        model.linkFailure = await model.open(link, incomingShareSceneID: incomingShareSceneID).message
    }

    private var tabs: some View {
        TabView {
            // Only once a connection test has passed. A Friend tab that opens on
            // "configure me first" is a promise the app can't keep — and "configured"
            // isn't enough to promise it either, since a typo'd key is configured.
            if model.agentConfig.isReady {
                Tab("Friend", systemImage: "sparkles") {
                    // The Friend view stacks the alarm pill on its own composer.
                    MusicFriendView(model: model)
                }
            }
            // Home leads: on a phone the question is almost always "what do I put on",
            // not "what do I own", and the album grid answers the second one.
            Tab("Home", systemImage: "house") {
                HomeView(model: model)
                    .alarmPillInset(model.alarms)
            }
            Tab("Albums", systemImage: "square.stack") {
                AlbumsGridView(model: model)
                    .alarmPillInset(model.alarms)
            }
            Tab("Library", systemImage: "books.vertical") {
                LibraryView(model: model)
                    .alarmPillInset(model.alarms)
            }
            Tab("Search", systemImage: "magnifyingglass") {
                SearchView(model: model)
                    .alarmPillInset(model.alarms)
            }
            // Settings is deliberately not a tab.
            //
            // Six tabs don't fit: iOS keeps four and folds the rest into "More", so with
            // the Friend tab enabled both Search *and* Settings ended up behind it. Search
            // is something people do constantly and Settings is something they do rarely,
            // so paying for Settings with a tab slot cost the wrong one. It lives in
            // Home's header instead — one tap, the corner Apple Music and KeepFloat both
            // put the account button in — and every content destination stays reachable
            // without a menu.
        }
        // iPad: the tab bar becomes an adaptable sidebar — the cheap-but-real first
        // step of the two-column iPad layout.
        .tabViewStyle(.sidebarAdaptable)
        // Scrolling down shrinks the tab bar to the active tab's icon and docks
        // the mini player beside it — one compact row while the user is reading
        // content, the full bar back on scroll-up or a tap. The tab *set* never
        // changes: tabs minimize by scroll state, they are never removed by
        // context, so nothing moves out from under muscle memory.
        .modifier(TabBarMinimizesOnScroll())
        // iOS 26 gives the tab bar a real accessory slot — the same one Apple
        // Music's mini player sits in. `safeAreaInset` predates it and draws
        // *over* the floating tab bar instead of above it, which clipped the
        // tab labels behind the bar (visible in any screenshot with a track
        // loaded). The inset stays as the fallback on iOS 18-25.
        .modifier(NowPlayingAccessory(model: model) { showsFullPlayer = true })
        .incomingSharePresenter(model: model, sceneID: incomingShareSceneID,
            pauseLibrary: { model.radio.engine.pauseForPlaybackHandoff(); model.music.pauseForPlaybackHandoff() },
            playLibrary: { song in
                model.music.play([song], source: .init(label: song.title, kind: .song, id: song.id))
            })
        .sheet(isPresented: Binding(get: { showsFullPlayer }, set: { showsFullPlayer = $0 })) {
            FullPlayerView(model: model)
        }
        // "Go to Album" / "Go to Artist", from anywhere. The asker may be inside the
        // player sheet or the queue sheet, so the target is presented here at the root —
        // and any open player is dismissed first, because iOS will not stack a second
        // sheet on top of one it is already showing.
        // The widget's `baton://player` link, presented here for the same reason the
        // reveals are: the asker is outside any NavigationStack this view owns.
        .onChange(of: model.playerPresentationRequests) { _, _ in
            showsFullPlayer = true
        }
        .onChange(of: showsFullPlayer, initial: true) { _, up in model.fullPlayerIsUp = up }
        .onChange(of: model.revealedAlbum) { _, album in
            if album != nil, showsFullPlayer { showsFullPlayer = false }
        }
        .onChange(of: model.revealedArtist) { _, artist in
            if artist != nil, showsFullPlayer { showsFullPlayer = false }
        }
        .sheet(isPresented: Binding(
            get: { model.revealedAlbum != nil && !showsFullPlayer },
            set: { if !$0 { model.revealedAlbum = nil } }
        )) {
            if let album = model.revealedAlbum {
                NavigationStack {
                    AlbumDetailView(album: album, model: model)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { model.revealedAlbum = nil }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.revealedArtist != nil && !showsFullPlayer },
            set: { if !$0 { model.revealedArtist = nil } }
        )) {
            if let artist = model.revealedArtist {
                NavigationStack {
                    ArtistDetailView(artist: artist, model: model)
                        .navigationDestination(for: NavidromeAlbum.self) { album in
                            AlbumDetailView(album: album, model: model)
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { model.revealedArtist = nil }
                            }
                        }
                }
            }
        }
        .task {
            await model.handoff.checkForHandoff()
            // Once per version, and never on a fresh install — a new user needs
            // onboarding, not a changelog. Not over a document someone is importing either:
            // the notes wait for the next launch (the marker is left as it is).
            if WhatsNewView.shouldShow, model.pendingDocumentImport == nil { showsWhatsNew = true }
        }
        // A document to import (handed over at launch, opened from Files, shared from another
        // app) takes the launch sheet from What's New, here or arriving later, and whatever else
        // is on screen makes way for it.
        .onChange(of: model.pendingDocumentImport, initial: true) { _, url in
            let whatsNewUp = showsWhatsNew
            if url != nil { showsWhatsNew = false }
            reconcileImport(launchSheetUp: whatsNewUp)
        }
        // What's New and the import screen share one sheet. They were two: the
        // import sheet on the App's root and What's New here, both wanting to present at
        // launch. On a phone updated from an earlier version What's New asked after the
        // handoff check, and whichever UIKit took first, the other was dropped without a
        // word, so a shared document or one handed over at launch could land on Home. One
        // item cannot race itself: the import wins, and a change of item swaps the sheets.
        .sheet(item: Binding(get: { launchSheet }, set: { if $0 == nil { launchSheetClosed() } })) { sheet in
            switch sheet {
            case .importDocument(let url):
                // Closes this screen's own document only: a submit that finishes after Cancel, or
                // after another document took the screen, must not close the next one.
                DocumentImportScreen(url: url, model: model) { [generation = model.importGeneration] in
                    model.endImport(generation: generation)
                }
                    .onAppear { importPresentation.appeared(url) }
            case .whatsNew:
                WhatsNewView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // A document that arrived while away, or whose sheet the trip away took back.
                reconcileImport()
                // Become the gateway's player while we're on screen.
                model.deviceLink.start()
                // Reconcile shared settings on the way in — this is the moment someone
                // would otherwise notice their EQ is the one they set on the other device.
                // Throttled, so a glance at Control Center doesn't cost a round trip.
                Task { await model.syncPreferences() }
                // And keep reconciling while we stay on screen. Foregrounding is the moment
                // someone notices a stale setting; it is not the only moment one goes stale,
                // and an app left open never saw another.
                model.startSyncHeartbeat()
            case .background:
                reconcileImport()
                model.handoff.saveNow()
                // A book's place, so the other device's Play lands here.
                model.pushBookLedgerLeavingForeground()
                model.deviceLink.stop()
                model.stopSyncHeartbeat()
            default:
                break
            }
        }
        .onChange(of: model.music.isPlaying) { was, is_ in
            if was, !is_ { model.handoff.saveNow() }
            if !was, is_ { askForAReviewIfEarned() }
            WidgetBridge.publish(
                song: model.music.nowPlaying, isPlaying: is_,
                // The track's own picture first (a book's cover, an episode's art), as the
                // other publish of this card does through `nowPlayingCoverURL`.
                artworkURL: model.music.nowPlaying.flatMap {
                    $0.artworkURL ?? model.musicLibrary.coverArtURL(id: $0.coverArtID ?? $0.id, size: 300)
                },
                elapsed: model.music.currentTime,
                duration: model.music.duration
            )
        }
        .alert(
            "Continue where you left off?",
            isPresented: Binding(
                get: { model.handoff.offer != nil },
                set: { if !$0 { model.handoff.declineOffer() } }
            )
        ) {
            Button("Continue") { model.handoff.acceptOffer() }
            Button("Not now", role: .cancel) { model.handoff.declineOffer() }
        } message: {
            if let title = model.handoff.offer?.currentTitle {
                Text("Another Baton saved a queue at “\(title)”.")
            }
        }
        // A Baton link that cannot be honoured used to do nothing at all, which is
        // indistinguishable from a link that never fired.
        .alert(
            "Couldn't open that link",
            isPresented: Binding(
                get: { model.linkFailure != nil },
                set: { if !$0 { model.linkFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.linkFailure = nil }
        } message: {
            if let reason = model.linkFailure { Text(reason) }
        }
    }

    /// Records that today counted as listening, and — on the day the gate finally opens —
    /// asks for a rating a little after the music has settled.
    ///
    /// The delay is the point. Firing on the same runloop as the tap puts a modal over the
    /// gesture that started the song, which reads as a punishment for pressing play. Twenty
    /// seconds later the track is going, the user is listening, and the app is visibly doing
    /// the thing they bought it for. If they moved on or stopped it in the meantime, the
    /// moment wasn't good after all and the prompt stays unspent.
    private func askForAReviewIfEarned() {
        // Demo sessions are not endorsements — see `ReviewPrompt.counts(isDemoMode:)`.
        guard ReviewPrompt.counts(isDemoMode: model.isDemoMode) else { return }
        ReviewPrompt.recordListening()
        guard ReviewPrompt.isEarned else { return }
        Task { @MainActor in
            try? await Task.sleep(for: ReviewPrompt.settleDelay)
            // Live UIKit state, deliberately, and NOT this view's `scenePhase`.
            //
            // `@Environment` is stored in the `RootTabView` struct, so a Task closure
            // captures it as it stood when the closure was made — which here is always
            // `.active`, because that is the instant playback started. Backgrounding
            // builds a *new* struct; this Task keeps the old one and the guard passes
            // anyway. That fails on the most ordinary path a music app has: press play,
            // pocket the phone. The prompt would be spent by `claimAsk()` and then fired
            // into a backgrounded app that shows nothing, and because claiming precedes
            // showing, the version's only prompt is gone for good.
            //
            // `requestReview` below is fine to hold: an environment *action* is a closure
            // that stays valid, where `scenePhase` is *state* that has to be read fresh.
            guard model.music.isPlaying,
                  UIApplication.shared.applicationState == .active else { return }
            guard ReviewPrompt.claimAsk() else { return }
            requestReview()
            #if DEBUG
            reviewAskFired = true
            #endif
        }
    }
}


// MARK: - Now-playing bar placement

/// Puts the mini player in the tab bar's accessory slot where the OS has one,
/// and falls back to a bottom safe-area inset where it doesn't.
/// The alarm pill sits in each tab's own bottom inset, so it lands just above the mini player and
/// the tab bar whichever way the OS draws them.
private extension View {
    func alarmPillInset(_ alarms: MobileAlarms) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MobileAlarmPill(alarms: alarms)
        }
    }
}

private struct NowPlayingAccessory: ViewModifier {
    let model: MobileModel
    let onTap: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Whether anything is playing is decided *inside* each branch, never between them.
    ///
    /// This modifier used to return `content` bare when nothing was playing and
    /// `content.tabViewBottomAccessory { … }` when something was. Swapping one branch of a
    /// `ViewModifier` body for another changes the structural identity of everything it
    /// wraps, so the first play of every session rebuilt the whole `TabView`: the selected
    /// tab reset to Home and every `NavigationStack` path was discarded. Two levels deep in
    /// Library, tap a song, and you were back on Home with the stack gone. Tapping the mini
    /// player's ✕ did it again in reverse.
    ///
    /// Every remaining branch is on something fixed for the life of the process — the
    /// device idiom and the OS version — so no branch can be taken at one moment and
    /// abandoned at the next. The empty capsule the old comment was written against is
    /// handled where it belongs, in the accessory's own content.
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Keyed to the *device*, not the size class: an iPhone Pro Max in landscape
            // also reports regular width, and the system accessory is right there — this
            // is about the iPad's canvas, not about how much width happens to be going.
            //
            // iPad draws its own capsule rather than the system accessory. The accessory
            // spans whatever width it is given and its shape is not ours to narrow, so on
            // a 13-inch canvas it became a full-width band with the title at one edge and
            // the controls at the other. The standalone chrome is already a self-contained
            // capsule — capped and centred, it reads as a player rather than a shelf.
            content.safeAreaInset(edge: .bottom) {
                // An inset with nothing in it takes no height, so the conditional is safe
                // here in a way it is not for the system accessory below.
                if model.music.nowPlaying != nil {
                    NowPlayingBar(model: model, chrome: .standalone, onOpen: onTap)
                        .readableWidth(620)
                        .padding(.bottom, 6)
                }
            }
        } else if #available(iOS 26.1, *) {
            // `isEnabled:`, not an `if` around the modifier. This is the whole fix: the
            // accessory is always attached, so the chain never changes shape, and the OS
            // simply does not draw the capsule while it is disabled. Attaching it
            // unconditionally and leaving the content empty is *not* the same thing — the
            // system still reserves and paints the capsule, which is the smeared empty pill
            // the comment above was written against. That was tried here first and
            // photographed before this line replaced it.
            content.tabViewBottomAccessory(isEnabled: model.music.nowPlaying != nil) {
                AccessoryNowPlayingBar(model: model, onTap: onTap)
            }
        } else if #available(iOS 26.0, *) {
            // 26.0 only, where `isEnabled:` does not exist yet. The accessory stays
            // attached — being thrown back to Home on the first play of every session is a
            // worse trade than an empty capsule on a build nobody stays on for long — and
            // its content is empty while nothing is playing.
            content.tabViewBottomAccessory {
                AccessoryNowPlayingBar(model: model, onTap: onTap)
            }
        } else {
            content.safeAreaInset(edge: .bottom) {
                if model.music.nowPlaying != nil {
                    NowPlayingBar(model: model, chrome: .standalone, onOpen: onTap)
                }
            }
        }
    }
}

/// Collapses the tab bar while the user scrolls down, where the OS supports it.
///
/// A modifier rather than an inline call because `tabBarMinimizeBehavior` is
/// iOS 26-only and the view chain it hangs off still builds for iOS 18.
/// Harmless on iPad: `sidebarAdaptable` means there is no bottom tab bar to
/// minimize there.
private struct TabBarMinimizesOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

/// The accessory-slot mini player, reshaped to match how much room the system
/// is giving it.
///
/// When the tab bar minimizes, the OS moves the accessory *inline* beside the
/// remaining tab icon — roughly two-thirds of the width the expanded slot had.
/// The full control row (play, next, close) doesn't fit there without crushing
/// the title, so the inline placement drops to artwork + title + play/pause:
/// the controls someone mid-scroll actually reaches for. Scroll up and the
/// expanded slot — and the full row — come back.
///
/// Lives in its own view because `tabViewBottomAccessoryPlacement` is an
/// iOS 26-only environment key, which `NowPlayingBar` (still built for
/// iOS 18) cannot declare.
@available(iOS 26.0, *)
private struct AccessoryNowPlayingBar: View {
    let model: MobileModel
    let onTap: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        // Nothing playing draws nothing. The condition belongs here rather than around the
        // accessory modifier itself: this view is a leaf the OS hosts, so swapping its
        // content costs a redraw, where swapping the modifier above it rebuilt the entire
        // TabView and threw the user back to Home.
        //
        // Capped on iPad. The accessory spans whatever width it's given, which on
        // a 13-inch canvas puts the track title at one edge and the controls at
        // the other with two feet of nothing between them — technically a bar,
        // visually a mistake. The phone is untouched: `readableWidth` is a no-op
        // in compact.
        if model.music.nowPlaying != nil {
            NowPlayingBar(
                model: model,
                chrome: .systemAccessory,
                compact: placement == .inline,
                onOpen: onTap
            )
        }
    }
}

// MARK: - Now-playing wash

private struct NowPlayingPaletteKey: EnvironmentKey {
    static let defaultValue = ArtworkPalette.neutral
}

extension EnvironmentValues {
    /// The current track's palette, published by `RootTabView` so any screen
    /// can paint itself with it.
    var nowPlayingPalette: ArtworkPalette {
        get { self[NowPlayingPaletteKey.self] }
        set { self[NowPlayingPaletteKey.self] = newValue }
    }
}

extension View {
    /// Paints a screen's scroll container with the now-playing artwork wash.
    ///
    /// Applied to the scroll view **inside** each screen's `NavigationStack`,
    /// never around the tab: a `NavigationStack` draws an opaque system
    /// background, so a backdrop placed outside it is never seen. Verified on
    /// the simulator — a solid red behind the `TabView`, and again behind
    /// each tab's content, both rendered pure black.
    func nowPlayingWash(_ palette: ArtworkPalette) -> some View {
        scrollContentBackground(.hidden)
            .background { AdaptiveBackdrop(palette: palette) }
    }
}
