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
    // Optional so the bar still renders in contexts without the router (e.g. snapshot tests).
    @Environment(BatonCommandRouter.self) private var router: BatonCommandRouter?
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

    // MARK: Radio takeover
    // When an internet-radio station is on the air it ducks the library player, so the bar
    // reflects the radio transport instead: station art/name/live-track, prev/next switch
    // stations, play/pause + the shared volume slider drive the radio stream. Library-only
    // controls (scrubber, rating, queue, expand) are hidden while on air.

    private var radio: InternetRadioStore { model.internetRadio }
    private var radioStation: NavidromeRadioStation? { radio.onAirStation }
    private var isRadio: Bool { radioStation != nil }
    private var isPlayingNow: Bool { isRadio ? radio.engine.isPlaying : player.isPlaying }

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
                    // Retry re-attempts the current track at its last position (a transient stall
                    // shouldn't force abandoning it); Skip moves on when there's somewhere to go.
                    Button("Retry") { player.retryCurrent() }.buttonStyle(.link)
                    if player.queue.count > 1 {
                        Button("Skip") { player.next() }.buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .transition(.opacity)
            }
            if !barCollapsed, !isRadio { seekRow }
            HStack(spacing: 14) {
                // Artwork carries the like-heart badge and is a standalone tap target
                // (opens the full-screen player) so the heart button isn't nested
                // inside another button.
                artwork
                    .overlay(alignment: .bottomTrailing) {
                        if !isRadio, let song = player.nowPlaying {
                            SongHeartBadge(song: song, visible: true, size: 11).offset(x: 3, y: 3)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if !isRadio, player.nowPlaying != nil { onExpand() } }

                // Radio has no full-screen player, so its title/subtitle render as plain text
                // (not inside the expand button — a disabled button would dim the labels).
                if isRadio {
                    titleBlock.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button(action: onExpand) {
                        HStack(spacing: 14) {
                            titleBlock
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
                }

                // Full control cluster, or — when minimized — just a compact play/pause so
                // the bar shrinks to a slim "what's playing" strip.
                if !barCollapsed {
                    transport
                    volume
                    if !isRadio { queueButton }
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
                    // A shrink-to-mini glyph (mirrors the mini player's expand icon) — clearer than
                    // the video-centric "pip".
                    Image(systemName: "arrow.down.right.and.arrow.up.left").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Switch to mini player")
                .accessibilityLabel("Mini player")
            }
        }
        .animation(.easeInOut(duration: 0.18), value: barCollapsed)
        .padding(.horizontal, 14)
        .padding(.top, barCollapsed ? 3 : 4).padding(.bottom, barCollapsed ? 3 : 6)
        // Translucent frost (not the opaque `.bar`) so the window's adaptive
        // artwork backdrop flows through the player bar, matching the main area.
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
        // Collapsed mode hides the scrubber — keep a 2px progress hairline along the top edge so the
        // slim bar still shows how far into the track you are.
        .overlay(alignment: .top) {
            if barCollapsed, !isRadio, player.duration > 0 {
                GeometryReader { geo in
                    Capsule()
                        .fill(accent)
                        .frame(width: geo.size.width * CGFloat(min(max(player.currentTime / player.duration, 0), 1)), height: 2)
                }
                .frame(height: 2)
                .allowsHitTesting(false)
            }
        }
        // Reconcile the current track's like/rating with the server on launch and
        // whenever the track changes — the persisted queue only has a stale
        // snapshot, so without this the heart/stars read empty after a relaunch.
        .task(id: player.nowPlaying?.id) {
            if let song = player.nowPlaying { await model.musicLibrary.refreshRating(for: song) }
        }
        // "Show Queue" (⌘U) from the Playback menu opens the queue popover here (the bar owns it).
        .onChange(of: router?.showQueueToken) { _, _ in if !isRadio { showingQueue = true } }
    }

    /// The title/artist (or station/live-track) block, shared by the library and radio bar so
    /// the radio version isn't dimmed by the disabled expand button.
    @ViewBuilder private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Source line ("Playing from …" / "On air") — hidden when minimized.
            if isRadio, !barCollapsed {
                Label("On air", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2).foregroundStyle(Color.accentColor).lineLimit(1)
            } else if let source = player.queueSource, player.nowPlaying != nil, !barCollapsed {
                Label(source.label, systemImage: source.icon)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(radioStation?.name ?? player.nowPlaying?.title ?? "Nothing playing")
                .font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            Text(isRadio
                 ? (radio.engine.nowPlayingTitle ?? "On air · live")
                 : (player.nowPlaying?.displayArtistName ?? ""))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var artworkURL: URL? {
        player.nowPlaying?.displayArtworkURL(size: 96) { id, size in
            model.musicLibrary.coverArtURL(id: id, size: size)
        }
    }

    /// Smaller artwork when the bar is minimized.
    private var artSize: CGFloat { barCollapsed ? 30 : 40 }

    @ViewBuilder
    private var artwork: some View {
        if let station = radioStation {
            RadioArtworkView(station: station, cornerRadius: 5)
                .frame(width: artSize, height: artSize)
        } else if let url = artworkURL {
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
            // Like moved to a heart badge on the artwork; rating stays here (library only).
            if !isRadio, let song = player.nowPlaying {
                MusicRatingStars(song: song)
            }
            // Prev/next: skip tracks for the library, switch stations for radio.
            Button { isRadio ? radio.playAdjacent(-1) : player.previous() } label: {
                Image(systemName: "backward.fill")
            }
            .help(isRadio ? "Previous station" : "Previous")
            .accessibilityLabel(isRadio ? "Previous station" : "Previous")
            Button {
                if isRadio {
                    radio.engine.isPlaying ? radio.engine.pause() : radio.engine.resume()
                } else if player.isPlaying {
                    player.pause()
                } else {
                    player.resume()
                }
            } label: {
                ZStack {
                    // ~50% larger than the flanking transport glyphs — the primary
                    // control on the bottom mini-player.
                    Image(systemName: isPlayingNow ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 33))
                        .opacity(!isRadio && player.isBuffering ? 0 : 1)
                    if !isRadio, player.isBuffering { ProgressView().controlSize(.small) }
                }
            }
            .accessibilityLabel(isPlayingNow ? "Pause" : "Play")
            Button { isRadio ? radio.playAdjacent(1) : player.next() } label: {
                Image(systemName: "forward.fill")
            }
            .help(isRadio ? "Next station" : "Next")
            .accessibilityLabel(isRadio ? "Next station" : "Next")
        }
        .buttonStyle(.plain)
        .disabled(!isRadio && player.nowPlaying == nil)
    }

    private var volume: some View {
        // The shared slider governs the library player and, while on air, the radio stream too
        // (radio mirrors the persisted library volume so there's a single volume control).
        MusicVolumeControl(
            percent: player.volumePercent,
            isMuted: player.isMuted,
            tint: accent,
            onChange: { player.setVolume(percent: $0); if isRadio { radio.engine.setVolume(percent: $0) } },
            onToggleMute: { player.toggleMute(); if isRadio { radio.engine.setMuted(player.isMuted) } }
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
        Button {
            if isRadio {
                radio.engine.isPlaying ? radio.engine.pause() : radio.engine.resume()
            } else {
                player.isPlaying ? player.pause() : player.resume()
            }
        } label: {
            Image(systemName: isPlayingNow ? "pause.fill" : "play.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!isRadio && player.nowPlaying == nil)
        .help(isPlayingNow ? "Pause" : "Play")
    }

    /// Upcoming tracks after the current one — drives the queue-button count badge.
    private var upcomingCount: Int { max(0, player.queue.count - player.currentIndex - 1) }

    private var queueButton: some View {
        Button { showingQueue.toggle() } label: {
            Image(systemName: "list.bullet")
                // A small count of what's still queued, so length is visible without opening it
                // (hidden at 0, like the sidebar badges — never a misleading "0").
                .overlay(alignment: .topTrailing) {
                    if upcomingCount > 0 {
                        Text("\(upcomingCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3).padding(.vertical, 0.5)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 9, y: -7)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Queue")
        .accessibilityLabel("Queue")
        .accessibilityValue(upcomingCount > 0 ? "\(upcomingCount) up next" : "Empty")
        .popover(isPresented: $showingQueue, arrowEdge: .top) {
            MusicQueueView()
                .environment(model)
                .frame(minWidth: 340, idealWidth: 360, maxWidth: 460, minHeight: 320, idealHeight: 420, maxHeight: 640)
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
    @Environment(MusicModel.self) private var model

    /// The tracks after the current one, and their summed duration — shown in the header so queue
    /// length is legible without counting rows.
    private var summary: String? {
        let start = model.music.currentIndex + 1
        let queue = model.music.queue
        guard start < queue.count else { return nil }
        let upcoming = queue[start...]
        let mins = upcoming.reduce(0) { $0 + ($1.duration ?? 0) } / 60
        let time = mins >= 60 ? "\(mins / 60) hr \(mins % 60) min" : "\(mins) min"
        return "\(upcoming.count) track\(upcoming.count == 1 ? "" : "s") · \(time)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Up Next").font(.headline)
                if let summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
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
    /// The row under the cursor — Delete removes it (matching the hover ✕), no selection needed.
    @State private var hoveredIndex: Int?

    private func deleteHovered() -> KeyPress.Result {
        guard let i = hoveredIndex, i != model.music.currentIndex, i < model.music.queue.count
        else { return .ignored }
        model.music.removeFromQueue(at: IndexSet(integer: i))
        hoveredIndex = nil
        return .handled
    }

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
                        MusicQueueRow(index: index, song: song, dragging: dragging) { inside in
                            if inside { hoveredIndex = index }
                            else if hoveredIndex == index { hoveredIndex = nil }
                        }
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
            // Delete/Backspace removes the hovered row (the hover ✕ + context menu still work too).
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.delete) { deleteHovered() }
            .onKeyPress(.deleteForward) { deleteHovered() }
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
    /// Reports hover in/out so the list can target Delete at the hovered row.
    var onHoverChange: (Bool) -> Void = { _ in }
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
                if let artist = song.displayArtistName, !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let quality = song.qualityLabel {
                MusicMetaBadge(quality)
            }
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
        .onHover { hovering = $0; onHoverChange($0) }
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
