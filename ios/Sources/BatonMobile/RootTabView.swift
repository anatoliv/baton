import SwiftUI
import UIKit

/// The iPhone shell: tabs over the shared library store, with the Now Playing bar
/// floating above the tab bar (the phone-shaped answer to the Mac's bottom bar).
struct RootTabView: View {
    let model: MobileModel
    @State private var showsFullPlayer = false
    @State private var showsWhatsNew = false
    @Environment(\.scenePhase) private var scenePhase
    /// Paints every screen with the now-playing cover's colors, the way the
    /// Mac's window does (`MusicView` — "whole-window color-from-artwork
    /// wash"). The phone previously did this only inside the full player, so
    /// every tab was flat black while the Mac's whole window took its color
    /// from the track.
    @State private var paletteLoader = ArtworkPaletteLoader()

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
            #endif
            .environment(\.nowPlayingPalette, paletteLoader.palette)
            // Same reason the Mac forces it: dark text on a warm wash is
            // unreadable, and the player is dark on both platforms.
            .preferredColorScheme(.dark)
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
                    artworkURL: nowPlayingCoverURL
                )
            }
    }

    private var tabs: some View {
        TabView {
            // Only once a connection test has passed. A Friend tab that opens on
            // "configure me first" is a promise the app can't keep — and "configured"
            // isn't enough to promise it either, since a typo'd key is configured.
            if model.agentConfig.isReady {
                Tab("Friend", systemImage: "sparkles") {
                    MusicFriendView(model: model)
                }
            }
            // Home leads: on a phone the question is almost always "what do I put on",
            // not "what do I own", and the album grid answers the second one.
            Tab("Home", systemImage: "house") {
                HomeView(model: model)
            }
            Tab("Albums", systemImage: "square.stack") {
                AlbumsGridView(model: model)
            }
            Tab("Library", systemImage: "books.vertical") {
                LibraryView(model: model)
            }
            Tab("Search", systemImage: "magnifyingglass") {
                SearchView(model: model)
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
        // iOS 26 gives the tab bar a real accessory slot — the same one Apple
        // Music's mini player sits in. `safeAreaInset` predates it and draws
        // *over* the floating tab bar instead of above it, which clipped the
        // tab labels behind the bar (visible in any screenshot with a track
        // loaded). The inset stays as the fallback on iOS 18-25.
        .modifier(NowPlayingAccessory(model: model) { showsFullPlayer = true })
        .sheet(isPresented: $showsFullPlayer) {
            FullPlayerView(model: model)
        }
        // "Go to Album" / "Go to Artist", from anywhere. The asker may be inside the
        // player sheet or the queue sheet, so the target is presented here at the root —
        // and any open player is dismissed first, because iOS will not stack a second
        // sheet on top of one it is already showing.
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
            // onboarding, not a changelog.
            if WhatsNewView.shouldShow { showsWhatsNew = true }
        }
        .sheet(isPresented: $showsWhatsNew) { WhatsNewView() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Become the gateway's player while we're on screen.
                model.deviceLink.start()
                // Reconcile shared settings on the way in — this is the moment someone
                // would otherwise notice their EQ is the one they set on the other device.
                // Throttled, so a glance at Control Center doesn't cost a round trip.
                Task { await model.syncPreferences() }
            case .background:
                model.handoff.saveNow()
                model.deviceLink.stop()
            default:
                break
            }
        }
        .onChange(of: model.music.isPlaying) { was, is_ in
            if was, !is_ { model.handoff.saveNow() }
            WidgetBridge.publish(
                song: model.music.nowPlaying, isPlaying: is_,
                artworkURL: model.music.nowPlaying.flatMap {
                    model.musicLibrary.coverArtURL(id: $0.coverArtID ?? $0.id, size: 300)
                }
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
    }
}


// MARK: - Now-playing bar placement

/// Puts the mini player in the tab bar's accessory slot where the OS has one,
/// and falls back to a bottom safe-area inset where it doesn't.
private struct NowPlayingAccessory: ViewModifier {
    let model: MobileModel
    let onTap: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        // The condition lives *outside* the accessory, not inside it: an
        // accessory whose content is empty still reserves and draws the
        // capsule, which rendered as a smeared duplicate of the content
        // behind it. With nothing playing there should be no accessory at
        // all.
        if model.music.nowPlaying == nil {
            content
        } else if UIDevice.current.userInterfaceIdiom == .pad {
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
                NowPlayingBar(model: model, chrome: .standalone, onOpen: onTap)
                    .readableWidth(620)
                    .padding(.bottom, 6)
            }
        } else if #available(iOS 26.0, *) {
            content.tabViewBottomAccessory {
                // Capped on iPad. The accessory spans whatever width it's given, which on
                // a 13-inch canvas puts the track title at one edge and the controls at
                // the other with two feet of nothing between them — technically a bar,
                // visually a mistake. The phone is untouched: `readableWidth` is a no-op
                // in compact.
                NowPlayingBar(model: model, chrome: .systemAccessory, onOpen: onTap)
            }
        } else {
            content.safeAreaInset(edge: .bottom) {
                NowPlayingBar(model: model, chrome: .standalone, onOpen: onTap)
            }
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
