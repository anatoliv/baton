import AppKit
import SwiftUI

/// A small, detachable, always-on-top **mini player** — artwork, title/artist, a
/// scrubber, and transport — that stays available when the main Music window is closed.
/// Playback lives on `AppModel.music` (window-independent), so this just controls the
/// shared player. Opened from the Playback menu or the now-playing bar; the expand
/// button opens the full Music window.
struct MiniPlayerWindowView: View {
    static let windowID = "tonebox-mini-player"

    @Environment(MusicModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// Compact (tiny) by default; expanded reveals volume, rating, and Up Next. Persisted.
    @AppStorage("tonebox.miniPlayer.expanded") private var expanded = false
    /// Own artwork-palette loader so the mini player's track-visualizing fills pick up
    /// the dynamic accent, matching the full player (Brand ⇄ Dynamic rule).
    @State private var paletteLoader = ArtworkPaletteLoader()

    private var player: StreamingPlaybackController { model.music }

    private var artworkURL: URL? {
        player.nowPlaying?.displayArtworkURL(size: 120) { id, size in
            model.musicLibrary.coverArtURL(id: id, size: size)
        }
    }

    /// Cover URL sized for palette extraction (canonical size, so the mini player's
    /// accent matches the main window's for the same track). Separate from the 120px
    /// display thumbnail above.
    private var paletteCoverURL: URL? {
        player.nowPlaying?.displayArtworkURL(size: ArtworkColorExtractor.coverSize) { id, size in
            model.musicLibrary.coverArtURL(id: id, size: size)
        }
    }

    /// Contrast-corrected dynamic accent for the scrubber/volume fills + active state.
    private var accent: Color { paletteLoader.palette.uiAccent }

    var body: some View {
        VStack(spacing: 10) {
            header

            // The scrubber renders its own elapsed / −remaining time labels.
            MusicScrubber(currentTime: player.currentTime, duration: player.duration, tint: accent) {
                player.seek(to: $0)
            }

            transport

            if expanded {
                MusicVolumeControl(
                    percent: player.volumePercent,
                    isMuted: player.isMuted,
                    tint: accent,
                    onChange: { player.setVolume(percent: $0) },
                    onToggleMute: { player.toggleMute() }
                )
                ratingRow
                upNextSection
            }

            expandToggle
        }
        .animation(.easeInOut(duration: 0.2), value: expanded)
        .onAppear { paletteLoader.update(url: artworkURL) }
        .onChange(of: player.nowPlaying?.coverArtID) { _, _ in paletteLoader.update(url: artworkURL) }
        // Return-to-full-player, pinned to the panel's top-right corner.
        .overlay(alignment: .topTrailing) { expandButton }
        .padding(14)
        .frame(width: 320)
        .miniPlayerPanel(cornerRadius: 16)
        .preferredColorScheme(.dark)
        .background(MiniPlayerWindowConfigurator())
    }

    /// Artwork + title (both open the full player) + "Playing from …" + like.
    private var header: some View {
        HStack(spacing: 12) {
            artwork
                .onTapGesture { openFull() }
                .help("Open full player")
            VStack(alignment: .leading, spacing: 2) {
                Text(player.nowPlaying?.title ?? "Nothing playing")
                    .font(.callout.weight(.semibold)).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { if player.nowPlaying != nil { openFull() } }
                Text(player.nowPlaying?.displayArtistName ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let context = playingFrom {
                    Text(context).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            likeButton
        }
        // Reserve room so the title never runs under the corner expand button.
        .padding(.trailing, 22)
    }

    private var playingFrom: String? {
        guard let source = player.queueSource, !source.label.isEmpty else { return nil }
        return "Playing from \(source.label)"
    }

    /// Rate the current track (expanded only).
    @ViewBuilder private var ratingRow: some View {
        if let song = player.nowPlaying {
            HStack {
                MusicStarRating(rating: model.musicLibrary.rating(song)) { newRating in
                    Task { await model.musicLibrary.setRating(song, rating: newRating) }
                }
                Spacer()
            }
        }
    }

    /// The upcoming tracks in the queue (absolute index kept for `jump`).
    private var upNext: [(index: Int, song: NavidromeSong)] {
        let start = player.currentIndex + 1
        guard start < player.queue.count else { return [] }
        return (start ..< player.queue.count).map { ($0, player.queue[$0]) }
    }

    /// A compact, tappable "Up Next" list (expanded only) — tap a track to jump to it.
    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Up Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if upNext.isEmpty {
                Text("Nothing queued").font(.caption).foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(upNext, id: \.index) { item in
                            Button { player.jump(to: item.index) } label: {
                                HStack(spacing: 8) {
                                    Text(item.song.title).font(.caption).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(item.song.displayArtistName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 132)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The compact ⇄ expanded chevron (distinct from the return-to-full-window button).
    private var expandToggle: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Show less" : "Show volume, rating & Up Next")
    }

    /// Open the full Music window and close the mini player.
    private func openFull() {
        openWindow(id: MusicWindowView.windowID)
        dismissWindow(id: MiniPlayerWindowView.windowID)
    }

    /// Shuffle · previous · play/pause · next · repeat — parity with the full-screen player.
    private var transport: some View {
        HStack(spacing: 20) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffled ? accent : .secondary)
            }
            .help("Shuffle")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.isShuffled ? "On" : "Off")
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous track")
            Button { player.isPlaying ? player.pause() : player.resume() } label: {
                ZStack {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .opacity(player.isBuffering ? 0 : 1)
                    if player.isBuffering { ProgressView().controlSize(.small) }
                }
            }
            .disabled(player.nowPlaying == nil)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next track")
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? .secondary : accent)
            }
            .help("Repeat")
            .accessibilityLabel("Repeat")
            .accessibilityValue(player.repeatMode.rawValue)
        }
        .buttonStyle(.plain)
        .font(.title3)
    }

    /// Like / unlike the current track (heart, pink when liked).
    @ViewBuilder private var likeButton: some View {
        if let song = player.nowPlaying {
            let liked = model.musicLibrary.isLiked(song)
            Button { Task { await model.musicLibrary.toggleLike(song) } } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .foregroundStyle(liked ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            .help(liked ? "Unlike" : "Like")
        }
    }

    /// Switch formats: open the full player and close the mini. Pinned top-right.
    private var expandButton: some View {
        Button(action: openFull) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Return to full player")
    }

    @ViewBuilder
    private var artwork: some View {
        Group {
            if let artworkURL {
                AsyncImage(url: artworkURL) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                    Color.secondary.opacity(0.12)
                }
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension View {
    /// The mini player's panel surface. On macOS 26+ this is real **Liquid Glass** —
    /// the window is borderless + transparent, so the glass refracts the desktop/content
    /// behind it (the canonical floating-panel use of the material). On macOS 15 it falls
    /// back to the previous opaque rounded window-background fill so older systems still
    /// get a clean panel.
    @ViewBuilder
    func miniPlayerPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
        }
    }
}

/// Configures the hosting window as a compact, floating, always-on-top panel that
/// survives losing focus and can be dragged by its body.
private struct MiniPlayerWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        // Fully chromeless: a borderless window has no title bar at all, so the content
        // fills it exactly — no traffic lights, no phantom title-bar gap, and nothing to
        // clip on show/hide. The rounded panel look + shadow come from the content's
        // rounded background on a transparent window.
        window.styleMask = [.borderless, .fullSizeContentView]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Round the window's content layer so the window's *shape* (and therefore its
        // shadow + any focus edge) follows the rounded panel — otherwise the square
        // window bounds show as sharp corners when the window becomes key.
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 16
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
        }
        window.invalidateShadow()
    }
}
