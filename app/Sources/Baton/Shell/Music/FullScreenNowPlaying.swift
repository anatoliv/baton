import AppKit
import SwiftUI

/// The full-screen "Now Playing" hero — the headline UI upgrade. An adaptive
/// color-from-artwork backdrop, large artwork, big type, inline like + 5-star, a
/// smooth scrubber, transport, volume, and a collapsible "Up Next" queue. Presented
/// as an overlay over `MusicView`.
struct FullScreenNowPlaying: View {
    @Environment(MusicModel.self) private var model
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
        .preferredColorScheme(.dark)
        .onAppear { paletteLoader.update(url: coverURL(size: 500)) }
        .onChange(of: player.nowPlaying?.coverArtID) { _, _ in paletteLoader.update(url: coverURL(size: 500)) }
        .task(id: player.nowPlaying?.coverArtID) { coverImage = await loadCoverImage() }
        .confirmationDialog(
            "Delete this track?",
            isPresented: $showRemovalConfirm,
            titleVisibility: .visible
        ) {
            Button("Mark for removal", role: .destructive) { deleteCurrentTrack() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Subsonic can't delete files, so \"\(player.nowPlaying?.title ?? "this track")\" will be unliked and rated lowest (★) — the signal your pipeline uses to prune it — and skipped now."
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
                .help("Delete — unlike + rate lowest so your pipeline prunes it")
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
                .shadow(color: .black.opacity(0.55), radius: player.isPlaying ? 52 : 34, y: 26)
                // Subtle "breathing" motion while playing (Apple-Music-style life).
                .scaleEffect(breathing && player.isPlaying ? 1.02 : 0.98)
                .animation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true), value: breathing)
                .animation(.easeInOut(duration: 0.4), value: player.isPlaying)
                .onAppear { breathing = true }
            VStack(spacing: 6) {
                Text(player.nowPlaying?.title ?? "Nothing playing")
                    .font(.system(size: 32, weight: .bold)).lineLimit(1)
                Text([player.nowPlaying?.artist, player.nowPlaying?.album].compactMap(\.self).joined(separator: " · "))
                    .font(.title3).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
            }
            if let song = player.nowPlaying {
                MusicRatingCluster(song: song)
            }
            MusicScrubber(currentTime: player.currentTime, duration: player.duration, waveform: waveform) { player.seek(to: $0) }
                .task(id: player.nowPlaying?.id) { await loadWaveform() }
                .frame(maxWidth: 520)
            transport
            MusicVolumeControl(
                percent: player.volumePercent,
                isMuted: player.isMuted,
                tint: .white,
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
                    .foregroundStyle(player.isShuffled ? Color.accentColor : .white.opacity(0.7))
            }
            .help("Shuffle")
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title2) }
            Button { player.isPlaying ? player.pause() : player.resume() } label: {
                ZStack {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .opacity(player.isBuffering ? 0.35 : 1)
                    if player.isBuffering { ProgressView().controlSize(.large) }
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title2) }
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.7) : Color.accentColor)
            }
            .help("Repeat")
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
        guard let id = player.nowPlaying?.coverArtID else { return nil }
        return model.musicLibrary.coverArtURL(id: id, size: size)
    }
}
