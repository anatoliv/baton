import AppKit
import SwiftUI

/// The full-screen "Now Playing" hero — the headline UI upgrade. An adaptive
/// color-from-artwork backdrop, large artwork, big type, inline like + 5-star, a
/// smooth scrubber, transport, volume, and a collapsible "Up Next" queue. Presented
/// as an overlay over `MusicView`.
struct FullScreenNowPlaying: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// The current cover, loaded as an NSImage so the artwork can keep a fixed
    /// height and let its width follow the image's natural aspect ratio.
    @State private var coverImage: NSImage?
    @State private var showRemovalConfirm = false
    /// Real waveform for the scrubber — only available for downloaded tracks.
    @State private var waveform: [Float]?

    enum SidePanel: String, CaseIterable { case queue = "Up Next", lyrics = "Lyrics", related = "Related" }

    private var player: StreamingPlaybackController {
        model.music
    }

    private var palette: ArtworkPalette {
        previewPalette ?? paletteLoader.palette
    }

    var body: some View {
        GeometryReader { geo in
            let showQueue = queueVisibleOverride ?? (geo.size.width >= 900)
            ZStack {
                AdaptiveBackdrop(palette: palette)

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
        .preferredColorScheme(.dark)
        .onAppear { paletteLoader.update(url: coverURL(size: ArtworkColorExtractor.coverSize)) }
        // Key on the song id, not coverArtID: podcast episodes all have a nil coverArtID
        // (their art is a direct URL), so keying on the cover id would never refresh between
        // episodes.
        .onChange(of: player.nowPlaying?.id) { _, _ in paletteLoader.update(url: coverURL(size: ArtworkColorExtractor.coverSize)) }
        .task(id: player.nowPlaying?.id) { coverImage = await loadCoverImage() }
        .confirmationDialog(
            "Delete this track?",
            isPresented: $showRemovalConfirm,
            titleVisibility: .visible
        ) {
            Button("Mark for removal", role: .destructive) { deleteCurrentTrack() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Subsonic can't delete files, so \"\(player.nowPlaying?.title ?? "this track")\" will be unliked and rated lowest (★) so a library-cleanup tool can remove it later — and skipped now."
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

    /// Fetch the cover as an NSImage (self-authenticating URL; URLCache-backed).
    private func loadCoverImage() async -> NSImage? {
        guard let url = coverURL(size: 500) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    /// Compute a real waveform for the scrubber when the current track is downloaded
    /// (a live stream can't be analyzed). Guards against a track change mid-load.
    private func loadWaveform() async {
        waveform = nil
        guard let song = player.nowPlaying,
              let url = MusicDownloadStore.shared.localURL(for: song.id) else { return }
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
            // Clear the window's top-left traffic lights.
            .padding(.leading, 52)
            Spacer()
            if let source = player.queueSource {
                VStack(spacing: 1) {
                    Text("Playing from").font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
                    Label(source.label, systemImage: source.icon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            } else {
                Text("Now Playing").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 20) {
                AirPlayRoutePicker(tint: .white)
                    .frame(width: 22, height: 22)
                    .help("AirPlay / output device")
                sleepTimerMenu
                Button { showRemovalConfirm = true } label: {
                    Image(systemName: "xmark.bin").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(player.nowPlaying == nil)
                .help("Delete — unlike + rate lowest so a cleanup tool can remove it later")
                Button { withAnimation(.spring) { queueVisibleOverride = !showQueue } } label: {
                    Image(systemName: "list.bullet").font(.title3)
                        .foregroundStyle(showQueue ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle queue")
            }
        }
        .padding(20)
        .foregroundStyle(.white)
    }

    private var sleepTimerMenu: some View { SleepTimerMenu(font: .title3, tint: .secondary) }

    private func heroColumn(availableHeight: CGFloat) -> some View {
        // Scale the artwork with the window so a tall window doesn't leave a big empty
        // band under the header. Clamped so it stays sensible on small/huge windows.
        let artHeight = min(max(availableHeight * 0.46, 300), 620)
        return VStack(spacing: 24) {
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
                .shadow(color: player.isPlaying ? palette.uiAccent.opacity(0.38) : .clear, radius: 44)
                .shadow(color: .black.opacity(0.55), radius: player.isPlaying ? 52 : 34, y: 26)
                // Subtle "breathing" motion while playing (Apple-Music-style life) — held still
                // under Reduce Motion (the continuous repeatForever loop is exactly what it targets).
                .scaleEffect(reduceMotion ? 1.0 : (breathing && player.isPlaying ? 1.02 : 0.98))
                .animation(reduceMotion ? nil : .easeInOut(duration: 3.4).repeatForever(autoreverses: true), value: breathing)
                .animation(.easeInOut(duration: 0.4), value: player.isPlaying)
                .onAppear { if !reduceMotion { breathing = true } }
            VStack(spacing: 6) {
                Text(player.nowPlaying?.title ?? "Nothing playing")
                    .font(.system(size: 32, weight: .bold)).lineLimit(1)
                Text([player.nowPlaying?.displayArtistName, player.nowPlaying?.album].compactMap(\.self).joined(separator: " · "))
                    .font(.title3).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
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
                MusicRatingCluster(song: song, tint: palette.uiAccent)
            }
            MusicScrubber(
                currentTime: player.currentTime, duration: player.duration,
                tint: palette.uiAccent, waveform: waveform
            ) { player.seek(to: $0) }
                .task(id: player.nowPlaying?.id) { await loadWaveform() }
                .frame(maxWidth: 520)
            transport
            MusicVolumeControl(
                percent: player.volumePercent,
                isMuted: player.isMuted,
                tint: palette.uiAccent,
                onChange: { player.setVolume(percent: $0) },
                onToggleMute: { player.toggleMute() }
            )
            .frame(maxWidth: 220)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    /// The cover as a resizable Image so a fixed height yields a proportional width
    /// (natural aspect, no crop). A square placeholder holds the space while loading.
    @ViewBuilder
    private var artwork: some View {
        if let coverImage {
            Image(nsImage: coverImage).resizable().aspectRatio(contentMode: .fit)
        } else if coverURL(size: 500) != nil {
            Color.white.opacity(0.06).aspectRatio(1, contentMode: .fit)
        } else {
            ZStack {
                Color.white.opacity(0.06)
                Image(systemName: "music.note").font(.system(size: 64)).foregroundStyle(.white.opacity(0.5))
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    private var transport: some View {
        HStack(spacing: 26) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.title3)
                    .foregroundStyle(player.isShuffled ? palette.uiAccent : .white.opacity(0.7))
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
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.7) : palette.uiAccent)
            }
            .help("Repeat")
            .accessibilityLabel("Repeat")
            .accessibilityValue(player.repeatMode.rawValue)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .disabled(player.nowPlaying == nil)
    }

    /// Custom segmented control for the side panel — a clear pill selector so all
    /// three tabs stay legible on the dark panel (the stock `.segmented` Picker
    /// renders the unselected tabs almost invisibly here).
    private var panelTabs: some View {
        HStack(spacing: 4) {
            ForEach(SidePanel.allCases, id: \.self) { panel in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { sidePanel = panel }
                } label: {
                    Text(panel.rawValue)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(sidePanel == panel ? Color.white : Color.white.opacity(0.65))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(sidePanel == panel ? Color.accentColor : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.08))
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
                case .related:
                    if let song = player.nowPlaying {
                        MusicRelatedView(song: song)
                    } else {
                        nothingPlaying
                    }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
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
