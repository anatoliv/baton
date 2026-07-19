import SwiftUI
import UniformTypeIdentifiers

/// Shared id + conditional helper for the mini-bar ⇄ full-screen artwork morph
/// (`matchedGeometryEffect`). The namespace is optional so the bar/hero still
/// work when used without a morph host.
enum MusicArtMorph {
    static let id = "nowPlayingArtwork"
}

extension View {
    @ViewBuilder
    func matchedArtwork(_ namespace: Namespace.ID?, isSource: Bool) -> some View {
        if let namespace {
            matchedGeometryEffect(id: MusicArtMorph.id, in: namespace, isSource: isSource)
        } else {
            self
        }
    }
}

/// The persistent now-playing bar for the full player: artwork, title/artist, a
/// seek bar, transport, volume, and a queue popover. Binds to the shared
/// `StreamingPlaybackController` (`model.music`).
struct NowPlayingBar: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingQueue = false
    /// Collapse the control cluster (rating · transport · volume · queue · sleep · AirPlay)
    /// for a slim "what's playing" bar — the same expand/collapse idea as the mini player.
    /// Persisted.
    @AppStorage("tonebox.music.barCollapsed") private var barCollapsed = false
    /// Namespace + state for the artwork morph into the full-screen hero.
    var artNamespace: Namespace.ID?
    var expanded = false
    /// Dynamic artwork accent for the track-visualizing fills (progress + volume).
    /// Defaults to brand orange for hosts that don't supply a palette. Per the design
    /// doc's Brand ⇄ Dynamic rule, only the continuous fills use this; discrete
    /// selection/mode highlights stay brand orange.
    var accent: Color = .accentColor
    /// Called when the user taps the artwork/title to open the full-screen player.
    var onExpand: () -> Void = {}

    private var player: StreamingPlaybackController {
        model.music
    }

    /// The player's last playback error, if the transport is in an error state.
    private var playerError: String? {
        if case let .error(message) = player.state { return message }
        return nil
    }

    var body: some View {
        VStack(spacing: 2) {
            if let playerError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(playerError).lineLimit(1)
                    Spacer(minLength: 6)
                    if player.queue.count > 1 {
                        Button("Skip") { player.next() }.buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .transition(.opacity)
            }
            if !barCollapsed { seekRow }
            HStack(spacing: 14) {
                // Artwork carries the like-heart badge and is a standalone tap target
                // (opens the full-screen player) so the heart button isn't nested
                // inside another button.
                artwork
                    .overlay(alignment: .bottomTrailing) {
                        if let song = player.nowPlaying {
                            SongHeartBadge(song: song, visible: true, size: 11).offset(x: 3, y: 3)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if player.nowPlaying != nil { onExpand() } }

                Button(action: onExpand) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 1) {
                            // Source line ("Playing from …") — hidden when minimized so the
                            // strip is just title + artist.
                            if let source = player.queueSource, player.nowPlaying != nil, !barCollapsed {
                                Label(source.label, systemImage: source.icon)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text(player.nowPlaying?.title ?? "Nothing playing")
                                .font(.body.weight(.medium)).lineLimit(1)
                            Text(player.nowPlaying?.artist ?? "")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if player.nowPlaying != nil, !barCollapsed {
                            Image(systemName: "chevron.up").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(player.nowPlaying == nil)
                .help("Open full-screen player")

                // Full control cluster, or — when minimized — just a compact play/pause so
                // the bar shrinks to a slim "what's playing" strip.
                if !barCollapsed {
                    transport
                    volume
                    queueButton
                    SleepTimerMenu(font: .body, tint: .secondary)
                        .help("Sleep timer")
                    AirPlayRoutePicker(tint: .secondaryLabelColor)
                        .frame(width: 18, height: 18)
                        .help("AirPlay / output device")
                } else {
                    compactPlayPause
                }
                collapseToggle
                Button {
                    // Switch formats: open the mini and close the pop-out Music window
                    // (no-op when this bar is the inline main-window player).
                    openWindow(id: MiniPlayerWindowView.windowID)
                    dismissWindow(id: MusicWindowView.windowID)
                } label: {
                    Image(systemName: "pip").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Switch to mini player")
            }
        }
        .animation(.easeInOut(duration: 0.18), value: barCollapsed)
        .padding(.horizontal, 14)
        .padding(.top, barCollapsed ? 3 : 4).padding(.bottom, barCollapsed ? 3 : 6)
        // Translucent frost (not the opaque `.bar`) so the window's adaptive
        // artwork backdrop flows through the player bar, matching the main area.
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
        // Reconcile the current track's like/rating with the server on launch and
        // whenever the track changes — the persisted queue only has a stale
        // snapshot, so without this the heart/stars read empty after a relaunch.
        .task(id: player.nowPlaying?.id) {
            if let song = player.nowPlaying { await model.musicLibrary.refreshRating(for: song) }
        }
    }

    private var artworkURL: URL? {
        guard let coverID = player.nowPlaying?.coverArtID else { return nil }
        return model.musicLibrary.coverArtURL(id: coverID, size: 96)
    }

    /// Smaller artwork when the bar is minimized.
    private var artSize: CGFloat { barCollapsed ? 30 : 40 }

    @ViewBuilder
    private var artwork: some View {
        if let url = artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.1)
            }
            .frame(width: artSize, height: artSize)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .matchedArtwork(artNamespace, isSource: !expanded)
        } else {
            Image(systemName: "music.note")
                .frame(width: artSize, height: artSize)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.secondary)
        }
    }

    private var seekRow: some View {
        MusicScrubber(currentTime: player.currentTime, duration: player.duration, tint: accent) {
            player.seek(to: $0)
        }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            // Like moved to a heart badge on the artwork; rating stays here.
            if let song = player.nowPlaying {
                MusicRatingStars(song: song)
            }
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
            Button {
                if player.isPlaying { player.pause() } else { player.resume() }
            } label: {
                ZStack {
                    // ~50% larger than the flanking transport glyphs — the primary
                    // control on the bottom mini-player.
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 33))
                        .opacity(player.isBuffering ? 0 : 1)
                    if player.isBuffering { ProgressView().controlSize(.small) }
                }
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
        .disabled(player.nowPlaying == nil)
    }

    private var volume: some View {
        MusicVolumeControl(
            percent: player.volumePercent,
            isMuted: player.isMuted,
            tint: accent,
            onChange: { player.setVolume(percent: $0) },
            onToggleMute: { player.toggleMute() }
        )
        .frame(width: 96)
    }

    /// Minimize the whole bar to a slim strip (hides the scrubber + control cluster) or
    /// expand it back. `chevron.down` = minimize, `chevron.up` = expand.
    private var collapseToggle: some View {
        Button { withAnimation(.easeInOut(duration: 0.18)) { barCollapsed.toggle() } } label: {
            Image(systemName: barCollapsed ? "chevron.up" : "chevron.down")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(barCollapsed ? "Expand player" : "Minimize player")
    }

    /// A single play/pause shown in the minimized bar so playback stays controllable.
    private var compactPlayPause: some View {
        Button { player.isPlaying ? player.pause() : player.resume() } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(player.nowPlaying == nil)
        .help(player.isPlaying ? "Pause" : "Play")
    }

    private var queueButton: some View {
        Button { showingQueue.toggle() } label: {
            Image(systemName: "list.bullet")
        }
        .buttonStyle(.plain)
        .help("Queue")
        .popover(isPresented: $showingQueue, arrowEdge: .top) {
            MusicQueueView()
                .environment(model)
                .frame(width: 340, height: 360)
        }
    }

    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The play queue popover — a reorderable list with jump-to plus queue actions.
struct MusicQueueView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up next").font(.headline).padding(10)
            Divider()
            MusicQueueList()
            Divider()
            MusicQueueActions().padding(8)
        }
    }
}

/// Actions on the current play queue: save it as a new Navidrome playlist, or clear
/// it. Shared by the mini-bar popover and the full-screen queue panel.
struct MusicQueueActions: View {
    @Environment(MusicModel.self) private var model
    @State private var showingSave = false
    @State private var name = ""

    private var isEmpty: Bool { model.music.queue.isEmpty }

    var body: some View {
        HStack {
            Button { model.music.autoplayEnabled.toggle() } label: {
                Label("Autoplay", systemImage: "infinity")
                    .foregroundStyle(model.music.autoplayEnabled ? Color.accentColor : .secondary)
            }
            .help("Keep playing similar tracks when the queue ends")
            Spacer()
            Button { showingSave = true } label: {
                Label("Save as Playlist", systemImage: "square.and.arrow.down")
            }
            .disabled(isEmpty)
            Button(role: .destructive) { model.music.clearQueue() } label: {
                Label("Clear", systemImage: "xmark")
            }
            .disabled(isEmpty)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .alert("Save queue as playlist", isPresented: $showingSave) {
            TextField("Playlist name", text: $name)
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                name = ""
                guard !trimmed.isEmpty else { return }
                let ids = model.music.queue.map(\.id)
                Task {
                    _ = await model.musicLibrary.createPlaylist(name: trimmed, songIDs: ids)
                    await model.musicLibrary.loadPlaylists()
                }
            }
            Button("Cancel", role: .cancel) { name = "" }
        } message: {
            Text("Creates a new playlist from the \(model.music.queue.count) queued track\(model.music.queue.count == 1 ? "" : "s").")
        }
    }
}

/// Reorderable "Up Next" list: drag a row to reorder (live), a hover ✕ or context
/// menu to remove, tap to jump, current track highlighted with a tinted pill. Custom
/// rows (no default separators) for the premium look. Uses an explicit drag-and-drop
/// `DropDelegate` rather than `List.onMove` — native List reordering is unreliable on
/// macOS. Shared by the popover + full-screen player.
struct MusicQueueList: View {
    @Environment(MusicModel.self) private var model
    /// The row currently being dragged (nil when not dragging).
    @State private var dragging: NavidromeSong?

    var body: some View {
        if model.music.queue.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "music.note.list").font(.title).foregroundStyle(.tertiary)
                Text("Queue is empty").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.music.queue.enumerated()), id: \.element.id) { index, song in
                        MusicQueueRow(index: index, song: song, dragging: dragging)
                            .onDrag {
                                dragging = song
                                return NSItemProvider(object: song.id as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: QueueDropDelegate(item: song, model: model, dragging: $dragging)
                            )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
    }
}

/// Reorders the live play queue as a dragged row passes over each target row. The
/// underlying array is the real queue, so `moveQueueItem` keeps the current-track
/// index and persistence correct.
private struct QueueDropDelegate: DropDelegate {
    let item: NavidromeSong
    let model: MusicModel
    @Binding var dragging: NavidromeSong?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id else { return }
        let queue = model.music.queue
        guard let from = queue.firstIndex(where: { $0.id == dragging.id }),
              let to = queue.firstIndex(where: { $0.id == item.id }), from != to
        else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            model.music.moveQueueItem(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}

/// One "Up Next" row — number/now-playing indicator, title/artist, and a hover-reveal
/// remove button, on a rounded highlight (accent-tinted for the current track, faint
/// on hover). Uses semantic colors so it reads correctly on both the dark full-screen
/// panel and the mini-bar popover.
private struct MusicQueueRow: View {
    @Environment(MusicModel.self) private var model
    let index: Int
    let song: NavidromeSong
    /// The song currently being dragged (this row dims while it's the one moving).
    var dragging: NavidromeSong?
    @State private var hovering = false

    private var isCurrent: Bool { index == model.music.currentIndex }
    private var isPlaying: Bool { isCurrent && model.music.isPlaying }
    private var isDragging: Bool { dragging?.id == song.id }

    var body: some View {
        HStack(spacing: 11) {
            leading
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                if let artist = song.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if hovering, !isCurrent {
                Button {
                    model.music.removeFromQueue(at: IndexSet(integer: index))
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
        )
        .opacity(isDragging ? 0.4 : 1)
        .contentShape(Rectangle())
        // A *simultaneous* tap (not `.onTapGesture`, which would consume the press and
        // compete with the drag). TapGesture doesn't fire after a drag, so
        // reorder-drag and tap-to-jump coexist.
        .simultaneousGesture(TapGesture().onEnded { model.music.jump(to: index) })
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.18), value: isCurrent)
        .contextMenu {
            Button("Play Now", systemImage: "play.fill") { model.music.jump(to: index) }
            if !isCurrent {
                Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) {
                    model.music.removeFromQueue(at: IndexSet(integer: index))
                }
            }
        }
    }

    /// The leading glyph: an animated speaker for the current track, otherwise the
    /// 1-based position (fading to a grip on hover to hint at drag-to-reorder).
    @ViewBuilder
    private var leading: some View {
        if isCurrent {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        } else if hovering {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var background: Color {
        if isCurrent { return Color.nowPlayingRowTint() }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }
}
