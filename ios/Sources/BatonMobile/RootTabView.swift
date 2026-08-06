import SwiftUI

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
            .environment(\.nowPlayingPalette, paletteLoader.palette)
            // Same reason the Mac forces it: dark text on a warm wash is
            // unreadable, and the player is dark on both platforms.
            .preferredColorScheme(.dark)
            .onAppear { paletteLoader.update(url: nowPlayingCoverURL) }
            .onChange(of: model.music.nowPlaying?.id) { _, _ in
                paletteLoader.update(url: nowPlayingCoverURL)
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
            Tab("Settings", systemImage: "gearshape") {
                MobileSettingsView(model: model)
            }
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

    func body(content: Content) -> some View {
        // The condition lives *outside* the accessory, not inside it: an
        // accessory whose content is empty still reserves and draws the
        // capsule, which rendered as a smeared duplicate of the content
        // behind it. With nothing playing there should be no accessory at
        // all.
        if model.music.nowPlaying == nil {
            content
        } else if #available(iOS 26.0, *) {
            content.tabViewBottomAccessory {
                NowPlayingBar(model: model, onOpen: onTap)
            }
        } else {
            content.safeAreaInset(edge: .bottom) {
                NowPlayingBar(model: model, onOpen: onTap)
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
