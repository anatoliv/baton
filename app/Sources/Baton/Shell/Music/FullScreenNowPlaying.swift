import AppKit
import SwiftUI

/// The full-screen "Now Playing" hero — the headline UI upgrade. An adaptive
/// color-from-artwork backdrop, large artwork, big type, inline like + 5-star, a
/// smooth scrubber, transport, volume, and a collapsible "Up Next" queue. Presented
/// as an overlay over `MusicView`.
struct FullScreenNowPlaying: View {
    @Environment(MusicModel.self) private var model
    // Optional so snapshot/preview renders that don't inject the router still work; the live
    // window always provides it, so the deep link fires there.
    @Environment(BatonCommandRouter.self) private var router: BatonCommandRouter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppearanceSetting.key, store: BatonStorage.defaults)
    private var appearanceRaw = AppearanceSetting.defaultValue.rawValue
    @Binding var isPresented: Bool
    /// Override palette for snapshots/previews (nil = live-extracted from artwork).
    var previewPalette: ArtworkPalette?
    /// Namespace for the artwork morph from the mini-bar (nil = no morph).
    var artNamespace: Namespace.ID?
    @State private var paletteLoader = ArtworkPaletteLoader()
    /// nil = auto (show the Up Next panel when the window is wide enough, per the
    /// mockup's 2-column layout); non-nil = the user's explicit toggle.
    @State private var queueVisibleOverride: Bool?
    @State private var sidePanel: SidePanel = .queue
    @State private var breathing = false
    /// Whether the artwork should be mid-breath. Combines "the view has appeared" with "audio is
    /// actually playing" so the repeating animation arms on playback start, not just on appear.
    private var isBreathing: Bool { breathing && player.isPlaying }
    /// The current cover, loaded as an NSImage so the artwork can keep a fixed
    /// height and let its width follow the image's natural aspect ratio.
    @State private var coverImage: NSImage?
    @State private var showRemovalConfirm = false
    /// Real waveform for the scrubber — only available for downloaded tracks.
    @State private var waveform: [Float]?

    enum SidePanel: String, CaseIterable {
        case queue = "Up Next", lyrics = "Lyrics", transcript = "Transcript", related = "Related"
    }

    private var player: StreamingPlaybackController {
        model.music
    }

    private var palette: ArtworkPalette {
        previewPalette ?? paletteLoader.palette
    }

    private var tone: ArtworkPalette.BackdropTone { .resolved(for: colorScheme) }
    private var backdropPalette: ArtworkPalette { Self.backdropPalette(palette, for: colorScheme) }
    private var accent: Color {
        let candidate = palette.uiAccent(for: tone)
        guard colorScheme == .dark else { return candidate }
        return Contrast.ensureContrast(of: candidate,
                                       against: backdropPalette.backdropWorstCase(for: .dark), min: 4.5)
    }

    /// Keep bright cover art within a charcoal range so semantic text stays readable.
    /// This is local to the Mac player; the library and iPhone wash are unchanged.
    static func backdropPalette(_ palette: ArtworkPalette, for scheme: ColorScheme) -> ArtworkPalette {
        guard scheme == .dark else { return palette }
        let charcoal = Color(white: 0.08)
        return ArtworkPalette(
            primary: Contrast.blend(palette.primary, toward: charcoal, amount: 0.75),
            secondary: Contrast.blend(palette.secondary, toward: charcoal, amount: 0.75),
            accent: Contrast.blend(palette.accent, toward: charcoal, amount: 0.75)
        )
    }
    private var chromeAccent: Color { ArtworkPalette.neutral.uiAccent(for: tone) }

    var body: some View {
        GeometryReader { geo in
            let showQueue = queueVisibleOverride ?? (geo.size.width >= 900)
            ZStack {
                AdaptiveBackdrop(palette: backdropPalette)

                VStack(spacing: 0) {
                    header(showQueue: showQueue)
                    HStack(spacing: 34) {
                        heroColumn(availableHeight: geo.size.height)
                            .frame(maxWidth: .infinity)
                        if showQueue { queuePanel.frame(width: 320) }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 34)
                }
            }
        }
        // ←/→ seek ∓10s (the standard media-player affordance) via keyboard-shortcut buttons —
        // same mechanism as the Space/Esc controls, so no explicit focus juggling is needed.
        .background {
            Group {
                Button("Back 10 seconds") { player.seek(to: max(0, player.currentTime - 10)) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Forward 10 seconds") {
                    player.seek(to: min(player.duration, player.currentTime + 10))
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                // [ / ] cycle the side panel (Queue / Lyrics / Related) — keyboard access for the
                // otherwise click-only tab picker.
                Button("Previous panel") { cyclePanel(-1) }.keyboardShortcut("[", modifiers: [])
                Button("Next panel") { cyclePanel(1) }.keyboardShortcut("]", modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .accentColor(chromeAccent)
        .tint(chromeAccent)
        .onAppear { paletteLoader.update(url: coverURL(size: ArtworkColorExtractor.coverSize)) }
        // Key on the song id, not coverArtID: podcast episodes all have a nil coverArtID
        // (their art is a direct URL), so keying on the cover id would never refresh between
        // episodes.
        .onChange(of: player.nowPlaying?.id) { _, _ in paletteLoader.update(url: coverURL(size: ArtworkColorExtractor.coverSize)) }
        // Clear first. The old artwork stayed on screen for the whole fetch, so skipping
        // a track showed the *previous* song's cover under the new song's title — briefly,
        // but on the one surface that is entirely about the artwork.
        .task(id: player.nowPlaying?.id) {
            coverImage = nil
            coverImage = await loadCoverImage()
        }
        .confirmationDialog(
            "Delete this track?",
            isPresented: $showRemovalConfirm,
            titleVisibility: .visible
        ) {
            Button("Mark for removal", role: .destructive) { deleteCurrentTrack() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Subsonic can't delete files, so \"\(player.nowPlaying?.title ?? "this track")\" will be unliked and rated lowest (★) so a library-cleanup tool can remove it later, and skipped now."
            )
        }
    }

    /// Mark the current track for pipeline removal and drop it from the queue
    /// (which advances to the next track).
    private func deleteCurrentTrack() {
        guard let song = player.nowPlaying else { return }
        let index = player.currentIndex
        Task { await model.musicLibrary.markForRemoval(song) }
        player.removeFromQueue(at: IndexSet(integer: index))
    }

    /// Fetch the cover, through the shared decoded cache.
    ///
    /// Was a bare `URLSession` fetch plus `NSImage(data:)` on every track change — no
    /// decoded cache, full-resolution decode, and a second request for a cover the palette
    /// extractor had just downloaded at a different size.
    private func loadCoverImage() async -> NSImage? {
        guard let url = coverURL(size: 500) else { return nil }
        return await ArtworkCache.shared.image(for: url, side: 500)
    }

    /// Compute a real waveform for the scrubber when the current track is downloaded
    /// (a live stream can't be analyzed). Guards against a track change mid-load.
    private func loadWaveform() async {
        waveform = nil
        guard let song = player.nowPlaying else { return }
        // A permanent download first, then whatever the gapless prefetcher already pulled
        // down for this track. The second case is most of a listening session: the
        // prefetcher writes the next track to disk for gapless playback, so by the time you
        // are hearing it there is a real file to analyse — and the scrubber drew a plain
        // capsule anyway, because "streamed" was treated as "unanalysable".
        let url = MusicDownloadStore.shared.localURL(for: song.id)
            ?? player.prefetchedLocalURL(for: song.id)
        guard let url else { return }
        let bars = await WaveformExtractor.bars(forSongID: song.id, url: url)
        if player.nowPlaying?.id == song.id { waveform = bars }
    }

    private func header(showQueue: Bool) -> some View {
        HStack {
            Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { isPresented = false } } label: {
                Image(systemName: "chevron.down")
                    .font(.title2.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Collapse player (Esc)")
            .accessibilityLabel("Collapse player")
            // Clear the window's top-left traffic lights.
            .padding(.leading, 52)
            Spacer()
            if let source = player.queueSource {
                if Self.isNavigable(source) {
                    Button { navigateToSource(source) } label: {
                        playingFrom(source, navigable: true)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Go to \(source.label)")
                } else {
                    playingFrom(source, navigable: false)
                }
            } else {
                Text("Now Playing").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 20) {
                appearanceMenu
                AirPlayRoutePicker(tint: .labelColor)
                    .frame(width: 22, height: 22)
                    .help("AirPlay / output device")
                if player.isSpokenNowPlaying {
                    SpokenRateMenu(font: .title3, tint: .secondary)
                }
                sleepTimerMenu
                MacAlarmClockButton(font: .title3, tint: .secondary)
                Button { showRemovalConfirm = true } label: {
                    Image(systemName: "xmark.bin").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(player.nowPlaying == nil)
                .help("Delete: unlike + rate lowest so a cleanup tool can remove it later")
                .accessibilityLabel("Mark for removal")
                Button { withAnimation(.spring) { queueVisibleOverride = !showQueue } } label: {
                    Image(systemName: "list.bullet").font(.title3)
                        .foregroundStyle(showQueue ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle queue")
                .accessibilityLabel("Toggle queue")
            }
        }
        .padding(20)
        .foregroundStyle(.primary)
    }

    /// The "PLAYING FROM · <name>" block. When `navigable`, a trailing chevron hints it's a
    /// link to the source's album/playlist/artist page.
    private func playingFrom(_ source: StreamingPlaybackController.QueueSource, navigable: Bool) -> some View {
        VStack(spacing: 1) {
            Text("Playing from").font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
            HStack(spacing: 4) {
                Label(source.label, systemImage: source.icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if navigable {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// Only album/playlist/artist/folder sources have a detail page to open; radio/search/
    /// liked/song (and any source without an id) stay plain text.
    static func isNavigable(_ source: StreamingPlaybackController.QueueSource) -> Bool {
        guard source.id != nil else { return false }
        switch source.kind {
        case .album, .playlist, .artist, .folder: return true
        case .radio, .search, .liked, .song: return false
        }
    }

    /// Raise the deep-link intent for `MusicView` to resolve, then collapse the player so the
    /// pushed detail view is visible underneath.
    private func navigateToSource(_ source: StreamingPlaybackController.QueueSource) {
        router?.pendingSourceNavigation = source
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { isPresented = false }
    }

    private var appearanceMenu: some View {
        Menu {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppearanceSetting.allCases) { setting in
                    Text(setting.label).tag(setting.rawValue)
                }
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled").font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance: System, Light or Dark")
        .accessibilityLabel("Appearance")
        .accessibilityIdentifier("player-appearance")
        .accessibilityValue((AppearanceSetting(rawValue: appearanceRaw) ?? .defaultValue).label)
    }

    private var sleepTimerMenu: some View { SleepTimerMenu(font: .title3, tint: .secondary) }

    private func heroColumn(availableHeight: CGFloat) -> some View {
        // Scale the artwork with the window so a tall window doesn't leave a big empty
        // band under the header. Clamped so it stays sensible on small/huge windows.
        let artHeight = min(620, max(140, min(availableHeight * 0.46, availableHeight - 440)))
        // Keep transport and volume visible in the default-height window.
        return VStack(spacing: availableHeight < 850 ? 12 : 24) {
            // Small, capped top gap so the hero sits just under the header (any extra
            // window height falls to the flexible bottom spacer) — no big empty band.
            Spacer(minLength: 0).frame(maxHeight: 16)
            artwork
                // Height follows the window; width follows the cover's natural aspect
                // ratio — cohesive size, no crop, no blurred frame.
                .frame(height: artHeight)
                .frame(maxWidth: 640)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .matchedArtwork(artNamespace, isSource: true)
                // Playback glow: a soft artwork-colored halo while playing, over the
                // depth shadow. Dynamic accent per the design doc's Player section.
                .shadow(color: player.isPlaying ? accent.opacity(colorScheme == .light ? 0.15 : 0.38) : .clear, radius: 44)
                .shadow(color: .black.opacity(colorScheme == .light ? 0.16 : 0.55), radius: player.isPlaying ? 52 : 34, y: 26)
                // Applied *before* the scale below so it animates the glow only — leaving the
                // breathing loop as the sole animation driving scaleEffect (two `.animation`s
                // racing over one property is what froze it, see below).
                .animation(.easeInOut(duration: 0.4), value: player.isPlaying)
                // Subtle "breathing" motion while playing (Apple-Music-style life) — held still
                // under Reduce Motion (the continuous repeatForever loop is exactly what it targets).
                //
                // Keyed on `isBreathing`, not `breathing`: `.animation(value:)` only fires when its
                // value *changes*, and `breathing` changes exactly once (on appear). Opening the
                // hero while paused therefore armed nothing, and pressing play afterwards just slid
                // the scale to its end value and left it frozen there. Folding `isPlaying` into the
                // value makes playback start/stop arm and disarm the loop. Verified on-device.
                .scaleEffect(reduceMotion ? 1.0 : (isBreathing ? 1.02 : 0.98))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 3.4).repeatForever(autoreverses: true),
                    value: isBreathing
                )
                .onAppear { if !reduceMotion { breathing = true } }
            VStack(spacing: 6) {
                Text(player.nowPlaying?.title ?? "Nothing playing")
                    .font(.system(size: 32, weight: .bold)).lineLimit(1)
                Text([player.nowPlaying?.displayArtistName, player.nowPlaying?.album].compactMap(\.self).joined(separator: " · "))
                    .font(.title3).foregroundStyle(.secondary).lineLimit(1)
                if let song = player.nowPlaying {
                    HStack(spacing: 6) {
                        if let quality = song.qualityLabel { MusicMetaBadge(quality) }
                        if let genre = song.genres.first ?? song.genre, !genre.isEmpty { MusicMetaBadge(genre) }
                        if let year = song.year { MusicMetaBadge(String(year)) }
                        if let plays = song.playCount, plays > 0 {
                            MusicMetaBadge("\(plays) play\(plays == 1 ? "" : "s")")
                        }
                    }
                }
            }
            if let song = player.nowPlaying {
                MusicRatingCluster(song: song, tint: accent)
            }
            MusicScrubber(
                currentTime: player.currentTime, duration: player.duration,
                tint: accent, waveform: waveform
            ) { player.seek(to: $0) }
                .task(id: player.nowPlaying?.id) { await loadWaveform() }
                .frame(maxWidth: 520)
            transport
            MusicVolumeControl(
                percent: player.volumePercent,
                isMuted: player.isMuted,
                tint: accent,
                onChange: { player.setVolume(percent: $0) },
                onToggleMute: { player.toggleMute() }
            )
            .frame(maxWidth: 220)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
    }

    /// The cover as a resizable Image so a fixed height yields a proportional width
    /// (natural aspect, no crop). A square placeholder holds the space while loading.
    @ViewBuilder
    private var artwork: some View {
        if let coverImage {
            Image(nsImage: coverImage).resizable().aspectRatio(contentMode: .fit)
        } else if coverURL(size: 500) != nil {
            Color.primary.opacity(0.06).aspectRatio(1, contentMode: .fit)
        } else {
            ZStack {
                Color.primary.opacity(0.06)
                Image(systemName: "music.note").font(.system(size: 64)).foregroundStyle(.secondary)
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    private var transport: some View {
        HStack(spacing: 26) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.title3)
                    .foregroundStyle(player.isShuffled ? accent : .primary)
            }
            .help("Shuffle")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.isShuffled ? "On" : "Off")
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title2) }
                .accessibilityLabel("Previous track")
            Button { player.isPlaying ? player.pause() : player.resume() } label: {
                ZStack {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .opacity(player.isBuffering ? 0.35 : 1)
                    if player.isBuffering { ProgressView().controlSize(.large) }
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title2) }
                .accessibilityLabel("Next track")
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? .primary : accent)
            }
            .help("Repeat")
            .accessibilityLabel("Repeat")
            .accessibilityValue(player.repeatMode.rawValue)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(player.nowPlaying == nil)
    }

    /// Side-panel tabs retain their selected pill in both appearances.
    /// A book chapter's Transcript tab reads along, so it is named for that.
    private var playingBookChapter: Bool {
        guard let song = player.nowPlaying else { return false }
        return model.clippings.item(forSongID: song.id)?.clipping.isBookChapter ?? false
    }

    private var panelTabs: some View {
        HStack(spacing: 4) {
            ForEach(SidePanel.allCases, id: \.self) { panel in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { sidePanel = panel }
                } label: {
                    Text(panel == .transcript && playingBookChapter ? "Read Along" : panel.rawValue)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(sidePanel == panel
                            ? (colorScheme == .light ? Color.white : Color.black)
                            : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(sidePanel == panel ? chromeAccent : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sidePanel == panel ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// Cycle the side panel selection (bracket-key access).
    private func cyclePanel(_ delta: Int) {
        let all = SidePanel.allCases
        guard let i = all.firstIndex(of: sidePanel) else { return }
        withAnimation(.easeOut(duration: 0.15)) { sidePanel = all[(i + delta + all.count) % all.count] }
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelTabs
            Group {
                switch sidePanel {
                case .queue:
                    VStack(spacing: 0) {
                        // What's feeding the queue. The engine has recorded this on every
                        // play() since sources shipped; the panel just never said it — so
                        // "why is this song next" had no answer on screen.
                        if let source = player.queueSource {
                            Text("Playing from \(source.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                        }
                        MusicQueueList()
                        Divider()
                        MusicQueueActions().padding(10)
                    }
                case .lyrics:
                    if let song = player.nowPlaying {
                        MusicLyricsView(song: song)
                    } else {
                        nothingPlaying
                    }
                case .transcript:
                    // A book chapter's words are known, so it reads along instead.
                    if let song = player.nowPlaying, let chapter = model.clippings.item(forSongID: song.id),
                       chapter.clipping.isBookChapter {
                        ReadAlongPanel(item: chapter, currentTime: player.currentTime,
                                       loadTiming: { await model.documents.readAlongTiming(for: $0) },
                                       onSeek: { player.seek(to: $0) })
                    } else if let song = player.nowPlaying {
                        MusicTranscriptView(song: song)
                    } else {
                        nothingPlaying
                    }
                case .related:
                    if let song = player.nowPlaying {
                        MusicRelatedView(song: song)
                    } else {
                        nothingPlaying
                    }
                }
            }
            // Opaque semantic ground keeps queue text and controls independent of the artwork.
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accentColor(chromeAccent)
            .foregroundStyle(.primary)
        }
    }

    private var nothingPlaying: some View {
        Text("Nothing playing")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func coverURL(size: Int) -> URL? {
        player.nowPlaying?.displayArtworkURL(size: size) { id, size in
            model.musicLibrary.coverArtURL(id: id, size: size)
        }
    }
}
