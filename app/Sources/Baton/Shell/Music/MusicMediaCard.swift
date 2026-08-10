import SwiftUI

/// List (dense table) vs Grid (cards) for the music browse screens (Albums / Artists
/// / Playlists). Each screen persists its own choice (`@AppStorage`) since a good
/// default differs (curation-heavy Artists → list; Albums / Playlists → grid).
enum MusicBrowseLayout: String { case grid, list }

/// A compact playback transport (shuffle · prev · play/pause · next · repeat) that
/// controls the shared player. Reused in every browse screen's header. `onPlayWhenIdle`
/// lets a page start its own collection when the play button is pressed with nothing
/// queued (e.g. Liked "play all"); without it, play is disabled on an empty queue.
struct MusicMiniTransport: View {
    @Environment(MusicModel.self) private var model
    var onPlayWhenIdle: (() -> Void)?
    /// The collection this page represents (e.g. an artist's tracks). When set and the
    /// player is *paused* on some other queue, the play button starts THIS page's list
    /// from the top (via `onPlayWhenIdle`) instead of resuming the unrelated queue —
    /// so pressing play on an artist page plays that artist, not whatever was last cued.
    var pageSource: StreamingPlaybackController.QueueSource?

    /// Hidden when there's nothing to control and no play-all hook — so browse pages
    /// (which pass no `onPlayWhenIdle`) don't show a dead, fully-disabled transport
    /// on an empty queue. Pages with a play-all hook (Liked/Search) stay visible.
    private var isIdleAndDead: Bool { model.music.queue.isEmpty && onPlayWhenIdle == nil }

    var body: some View {
        if !isIdleAndDead { transport }
    }

    private var transport: some View {
        let player = model.music
        return HStack(spacing: 14) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").foregroundStyle(player.isShuffled ? Color.accentColor : .secondary)
            }
            .disabled(player.queue.isEmpty)
            Button { player.previous() } label: { Image(systemName: "backward.fill").foregroundStyle(.secondary) }
                .disabled(player.queue.isEmpty)
            Button {
                if player.isPlaying { player.pause() }
                else if player.nowPlaying == nil { onPlayWhenIdle?() }
                else if let onPlayWhenIdle, let pageSource, player.queueSource != pageSource {
                    // Paused on a different (or unrelated) queue → start this page's list.
                    onPlayWhenIdle()
                } else { player.resume() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title3)
            }
            .disabled(player.queue.isEmpty && onPlayWhenIdle == nil)
            Button { player.next() } label: { Image(systemName: "forward.fill").foregroundStyle(.secondary) }
                .disabled(player.queue.isEmpty)
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
            }
            .disabled(player.queue.isEmpty)
        }
        .font(.callout)
        .buttonStyle(.plain)
    }
}

/// A like-heart for anything the server can star — a song, an album, an artist.
///
/// Subsonic's `star`/`unstar` take a bare id and work for all three, and the store's
/// id-based `toggleLike` already drives them; only the *affordance* was song-only. That
/// left Home looking half-finished: hover a track shelf and a heart appears, hover the
/// album shelf directly below it and nothing does — which reads as a bug rather than as
/// "albums aren't likeable", because from the outside there is no reason they wouldn't be.
///
/// Mixes are the one card that legitimately has none: they're generated locally from your
/// listening, not entities the server knows, so there is nothing to star.
struct EntityHeartBadge: View {
    @Environment(MusicModel.self) private var model
    let id: String
    /// The server's own liked flag, used as the baseline until an optimistic override exists.
    let serverLiked: Bool
    /// Shown only while the caller says so — in practice, while the card is hovered.
    var visible: Bool = true
    var size: CGFloat = 12

    var body: some View {
        let liked = model.musicLibrary.isLiked(id: id, fallback: serverLiked)
        Button {
            Task { await model.musicLibrary.toggleLike(id: id, currentLiked: liked, userRating: nil) }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(liked ? Color.pink : .white)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hover-only, liked or not. Keeping a filled heart pinned to every liked item
        // turned the grids into a field of pink dots that competed with the artwork and
        // with the now-playing badge — and the Liked screen, where everything is liked,
        // became a wall of them. Whether something is liked is what the Liked screen is
        // *for*; on a cover the heart is a control, and a control can wait for the pointer.
        // Callers that pass `visible: true` (the player artwork) still show it always.
        .opacity(visible ? 1 : 0)
        .help(liked ? "Unlike" : "Like")
    }
}

/// A like-heart **badge** for a song's artwork — filled pink when liked, white
/// outline otherwise; tapping toggles the like. `visible` lets a caller reveal it on
/// hover (it's always shown once liked). Sized to sit in a cover corner.
struct SongHeartBadge: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong
    /// Whether the badge is shown at all — callers pass their hover state. The player
    /// artwork passes `true` because there the heart is a permanent control.
    var visible: Bool = true
    var size: CGFloat = 12

    var body: some View {
        let liked = model.musicLibrary.isLiked(song)
        Button { Task { await model.musicLibrary.toggleLike(song) } } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(liked ? Color.pink : .white)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hover-only, liked or not. Keeping a filled heart pinned to every liked item
        // turned the grids into a field of pink dots that competed with the artwork and
        // with the now-playing badge — and the Liked screen, where everything is liked,
        // became a wall of them. Whether something is liked is what the Liked screen is
        // *for*; on a cover the heart is a control, and a control can wait for the pointer.
        // Callers that pass `visible: true` (the player artwork) still show it always.
        .opacity(visible ? 1 : 0)
        .help(liked ? "Unlike" : "Like")
    }
}

/// A song's cover thumbnail that doubles as the play affordance and carries a
/// `SongHeartBadge`. Hover reveals a play overlay (and the heart badge); the current
/// track shows a speaker indicator. Shared leading element for every song row.
struct MusicSongThumb: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let song: NavidromeSong
    var size: CGFloat = 40
    /// Show the like-heart badge. Off on the Liked screen, where every song is already
    /// liked so the badge conveys nothing.
    var showLikeBadge: Bool = true
    var onPlay: () -> Void
    @State private var hovering = false

    private var coverURL: URL? { song.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 80) } }
    private var isCurrent: Bool { model.music.nowPlaying?.id == song.id }
    private var isPlaying: Bool { isCurrent && model.music.isPlaying }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.12))
            if let coverURL {
                AsyncImage(url: coverURL) { $0.resizable().scaledToFill() } placeholder: {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
            if hovering {
                // Pause when this row is the one playing — hovering the track you are
                // listening to used to offer to play it again. Same morph as the card's
                // hover control, so the gesture reads identically at both sizes.
                Color.black.opacity(0.4)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption).foregroundStyle(.white)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: isPlaying)
            } else if isPlaying {
                // Speaker cue only while actively playing — a current-but-paused track
                // shows just its artwork (no indicator), per the "playing only" rule.
                Color.black.opacity(0.35)
                // White over the scrim rather than the accent — same indicator, read
                // against artwork instead of against a row background.
                NowPlayingBars(isPlaying: true, tint: .white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if isPlaying { model.music.pause() } else { onPlay() } }
        .overlay(alignment: .bottomTrailing) {
            if showLikeBadge {
                SongHeartBadge(song: song, visible: hovering).offset(x: 3, y: 3)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// The shared filter/search field used in every browse screen's title row.
struct MusicFilterField: View {
    @Binding var text: String
    var prompt: String = "Filter"
    /// When set, the field submits on Enter (search) rather than filtering live.
    var onSubmit: (() -> Void)?
    /// When provided, mirrors the field's focus to the caller so it can, e.g., disable a
    /// ⌘A "select all" shortcut while the user is typing here. Falls back to a private
    /// focus state when nil, so callers that don't care are unaffected.
    var focused: FocusState<Bool>.Binding?
    /// Per-screen key for recent-filter history (nil disables history for this field).
    var historyKey: String?
    @FocusState private var localFocus: Bool
    @State private var history: [String] = []
    @State private var showHistory = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focused ?? $localFocus)
                .onSubmit { commitToHistory(); onSubmit?() }
            if historyKey != nil, !history.isEmpty {
                Button { reloadHistory(); showHistory.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Recent filters")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { historyPopover }
            }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 240)
        .task(id: historyKey) { reloadHistory() }
        // Commit a used term when focus leaves the field (so live filters — which never
        // fire onSubmit — still record what you searched for).
        .onChange(of: effectiveFocus) { _, focused in if !focused { commitToHistory() } }
    }

    private var effectiveFocus: Bool { focused?.wrappedValue ?? localFocus }

    private func reloadHistory() {
        history = historyKey.map { FilterHistory.items($0) } ?? []
    }

    private func commitToHistory() {
        guard let historyKey, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        FilterHistory.add(text, to: historyKey)
        reloadHistory()
    }

    @ViewBuilder private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(history, id: \.self) { term in
                HStack(spacing: 8) {
                    Button {
                        text = term
                        commitToHistory()      // bump to most-recent
                        onSubmit?()
                        showHistory = false
                    } label: {
                        Label(term, systemImage: "clock").labelStyle(.titleAndIcon)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        if let historyKey { FilterHistory.remove(term, from: historyKey); reloadHistory() }
                        if history.isEmpty { showHistory = false }
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).help("Remove")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            Divider()
            Button {
                if let historyKey { FilterHistory.clear(historyKey); reloadHistory() }
                showHistory = false
            } label: {
                Label("Clear History", systemImage: "trash").font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(width: 240)
        .padding(.vertical, 4)
    }
}

/// The shared two-row header for every music browse screen (Albums / Artists /
/// Playlists / Liked). Row 1: title (+ optional accessory) with the **filter field
/// pinned right**. Row 2: screen-specific `leading` controls, then the **List ⇄ Grid
/// toggle and the Sort menu pinned right (Sort rightmost)**. Keeps all screens aligned.
struct MusicBrowseHeader<Accessory: View, Leading: View, SortMenu: View>: View {
    let title: String
    /// Count of the currently-shown (filtered) records — rendered as a small badge next
    /// to the title so you can see how many rows a filter narrowed the list to. Nil hides it.
    var count: Int? = nil
    @Binding var filter: String
    var filterPrompt: String = "Filter"
    /// When set, the filter field submits on Enter (used by Search).
    var filterOnSubmit: (() -> Void)? = nil
    /// Optional mirror of the filter field's focus (see `MusicFilterField.focused`).
    var filterFocused: FocusState<Bool>.Binding? = nil
    /// Per-screen key for the filter field's recent-history dropdown (nil disables it).
    var filterHistoryKey: String? = nil
    @Binding var layout: MusicBrowseLayout
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var sortMenu: () -> SortMenu

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text(title).font(.title3.weight(.semibold))
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.15), value: count)
                            .help("\(count) shown")
                    }
                }
                accessory()
                Spacer()
                MusicFilterField(text: $filter, prompt: filterPrompt, onSubmit: filterOnSubmit, focused: filterFocused, historyKey: filterHistoryKey)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            // Title + controls read as one header block (no divider between the two
            // rows); a single hairline separates the whole header from the content.
            HStack(spacing: 10) {
                leading()
                Spacer()
                sortMenu()
                MusicLayoutPicker(layout: $layout)
            }
            .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
            Divider()
        }
    }
}

/// The split Sort control used on every browse screen: a left **direction** toggle
/// (ascending/descending) and a right **field dropdown** whose label is the current
/// field. The dropdown opens straight to a flat, checkmarked list of fields (no
/// nested "Sort by" submenu). One shared implementation for all screens; callers can
/// append `extra` menu items (e.g. a "Hide empty" toggle).
struct MusicSortControls<Field: MusicSortField, Extra: View>: View where Field.AllCases: RandomAccessCollection {
    @Binding var ascending: Bool
    @Binding var selection: Field
    @ViewBuilder var extra: () -> Extra

    init(ascending: Binding<Bool>, selection: Binding<Field>, @ViewBuilder extra: @escaping () -> Extra) {
        _ascending = ascending
        _selection = selection
        self.extra = extra
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { ascending.toggle() } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ascending ? "Ascending" : "Descending")

            Menu {
                ForEach(Field.allCases) { field in
                    Button { selection = field } label: {
                        if field == selection {
                            Label(field.label, systemImage: "checkmark")
                        } else {
                            Text(field.label)
                        }
                    }
                }
                extra()
            } label: {
                HStack(spacing: 4) {
                    Text(selection.label)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

extension MusicSortControls where Extra == EmptyView {
    init(ascending: Binding<Bool>, selection: Binding<Field>) {
        self.init(ascending: ascending, selection: selection, extra: { EmptyView() })
    }
}

/// The List ⇄ Grid segmented toggle used on every music browse screen.
struct MusicLayoutPicker: View {
    @Binding var layout: MusicBrowseLayout
    var body: some View {
        Picker("Layout", selection: $layout) {
            Image(systemName: "list.bullet").tag(MusicBrowseLayout.list)
            Image(systemName: "square.grid.2x2").tag(MusicBrowseLayout.grid)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("List or grid")
    }
}

/// The shared music **card** used by the album and artist grids so they have one
/// consistent look. A 16:9 artwork tile — a blurred fill behind a full-fit cover, so
/// nothing is ever cropped — with a centered hover **Play** button, an optional
/// corner badge, and a two-line metadata block (title + trailing stat, subtitle +
/// trailing stat).
///
/// Hover state is supplied by the enclosing hover-lift cell (which owns the single
/// `.onHover` + scale/zIndex), not tracked here — nesting a second `.onHover` makes
/// the outer one miss events.
struct MusicMediaCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Optional so the card still renders where no model is injected (previews, snapshot
    /// tests). Only the hover control needs it, and only to pause.
    @Environment(MusicModel.self) private var model: MusicModel?
    let coverURL: URL?
    var aspect: CGFloat = 16.0 / 9.0
    var placeholder: String = "opticaldisc"
    /// Optional top-leading badge (e.g. "auto-import"), tinted.
    var cornerBadge: (text: String, color: Color)?
    let title: String
    var subtitle: String = ""
    var trailingTop: String?
    var trailingBottom: String?
    var isHovering: Bool
    var isWorking = false
    /// The **selected** item — the album/playlist/artist/song that's currently the player's
    /// source/track. Drives a persistent accent **outline**, kept even when paused, until
    /// something else becomes current. This is the "selected style", independent of playback.
    var isSelected = false
    /// **Playing** right now — layers the glow + speaker-wave badge on top of the selected
    /// outline. Removed the moment playback pauses; the outline stays.
    var isPlaying = false
    /// Offline-download state, shown as a corner badge over the artwork (bottom-leading).
    var downloadStatus: DownloadStatusBadge.Status = .hidden
    /// An optional like control, drawn over the artwork's **bottom-trailing** corner —
    /// the same corner the player hangs its heart off, so the gesture is in the same place
    /// wherever you meet a track.
    ///
    /// It belongs to the card rather than the caller because the card owns the artwork:
    /// an overlay applied by the caller lands on the whole card, and the card is
    /// `VStack { artwork; metadata }` — which put the heart on top of the title.
    var likeBadge: AnyView?
    var onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork
            metadata
        }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        // VoiceOver reads the card as one actionable element ("Title, subtitle, button") instead of
        // announcing the artwork, title, and each badge separately.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Plays this item")
    }

    /// The spoken label: title, then subtitle when present.
    private var accessibilityLabel: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }

    private var artwork: some View {
        // Color.clear drives the aspect from the column width (it has no intrinsic
        // size), so the card can't force itself wider than its cell.
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { fill }
            .overlay { cover }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // One badge per corner of the artwork, so nothing can cover anything else:
            // top-leading a tag, top-trailing the now-playing bars, bottom-leading the
            // offline badge, bottom-trailing the like control. The download badge moved
            // here from bottom-trailing to make room for the heart, which is interactive
            // and therefore wants the corner the pointer already goes to.
            .overlay(alignment: .topLeading) { badge }
            .overlay(alignment: .topTrailing) { nowPlayingOverlay }
            .overlay(alignment: .bottomLeading) { downloadOverlay }
            .overlay { hoverPlay }
            // **After** `hoverPlay`, and that ordering is the whole feature. The hover
            // treatment lays a full-artwork scrim across the cover, and a scrim is
            // hit-testable — so a like button placed before it is covered by it at exactly
            // the moment the button becomes visible, and every click lands on "play"
            // instead. Last in the chain means topmost.
            .overlay(alignment: .bottomTrailing) { likeBadge }
            // A 3pt saturated ring drew a box around the artwork instead of framing it.
            // Two points, slightly softened, still reads instantly as "this is the one"
            // without competing with the cover it surrounds.
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: isSelected ? 2 : 0)
            }
            .shadow(
                color: isPlaying ? Color.playingGlowTint() : .black.opacity(isHovering ? 0.4 : 0.2),
                radius: isPlaying ? 10 : (isHovering ? 16 : 8),
                y: isHovering ? 8 : 4
            )
            .animation(.easeInOut(duration: 0.18), value: isSelected)
            .animation(.easeInOut(duration: 0.18), value: isPlaying)
    }

    /// Now-playing badge over the artwork — white bars on a dark disc, shown only while
    /// this album/playlist/artist/song is *actively playing* (never when paused), matching
    /// the cue on the list rows and song thumbs.
    ///
    /// It used to be white-on-accent at 0.95: a saturated disc that fought the cover for
    /// attention, and on a playing card it was the third accent signal at once alongside
    /// the accent border and the accent glow. The card already says "playing" three ways —
    /// the badge only has to say *which* card, and motion does that better than colour.
    /// So it wears the same dark-disc treatment as the download badge beside it.
    @ViewBuilder private var nowPlayingOverlay: some View {
        if isPlaying {
            // Animated, so a glance tells you it's *running* rather than merely current.
            NowPlayingBars(isPlaying: true, tint: .white)
                .padding(5).background(.black.opacity(0.45), in: Circle())
                .padding(6)
                .transition(.scale.combined(with: .opacity))
                .help("Now playing")
        }
    }

    /// Offline badge over the artwork — white glyph on a dark disc for legibility on any cover.
    /// A spinner isn't shown on cards (only in the denser table rows).
    @ViewBuilder private var downloadOverlay: some View {
        let symbol: String? = switch downloadStatus {
        case .complete: "arrow.down.circle.fill"
        case .partial: "arrow.down.circle"
        case .hidden, .downloading: nil
        }
        if let symbol {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(5).background(.black.opacity(0.45), in: Circle())
                .padding(6)
        }
    }

    // Blurred fill behind — a separate overlay so it can't dictate sizing.
    //
    // Both this and `cover` used to be their own `AsyncImage` for the same URL, so every
    // card decoded the same JPEG twice — twenty grid surfaces' worth. `CachedArtwork` hands
    // back one decoded image and both layers draw from it.
    @ViewBuilder private var fill: some View {
        if let coverURL {
            CachedArtwork(url: coverURL, side: Self.decodeSide) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.12)
            }
            .blur(radius: 18)
            .overlay(Color.black.opacity(0.15))
        } else {
            Color.secondary.opacity(0.12)
        }
    }

    // Full cover on top — scaledToFit, so nothing is ever cropped.
    @ViewBuilder private var cover: some View {
        if let coverURL {
            CachedArtwork(url: coverURL, side: Self.decodeSide) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
        } else {
            Image(systemName: placeholder).font(.largeTitle).foregroundStyle(.secondary)
        }
    }

    /// Decode target for a grid card. The grids are `.adaptive(minimum: 220)`, so a card is
    /// rarely much wider than this; decoding to the drawn size instead of full resolution is
    /// most of the memory saving.
    private static let decodeSide: CGFloat = 260

    @ViewBuilder private var badge: some View {
        if let cornerBadge {
            Text(cornerBadge.text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(cornerBadge.color.opacity(0.9), in: Capsule())
                .padding(6)
        }
    }

    /// The hover control over the artwork — a real transport button, not a picture of one.
    ///
    /// It used to draw `play.fill` unconditionally and always call `onPlay`, so hovering
    /// the track you were already listening to offered to play it again: the glyph said one
    /// thing and the state said another. Now it shows what pressing it will *do* — pause
    /// while this item is playing, play otherwise — and does that.
    ///
    /// The glyph morphs rather than swaps. `.contentTransition(.symbolEffect(.replace))`
    /// interpolates between the two SF Symbols, so the triangle folds into the bars instead
    /// of one disappearing and another appearing; at this size a hard cut reads as a flicker
    /// and makes the button feel like a re-render rather than a state change. Skipped under
    /// Reduce Motion, where an instant swap is the correct behaviour.
    @ViewBuilder private var hoverPlay: some View {
        if isHovering {
            // Centered over a dark scrim — kept away from every edge so a neighboring grid
            // cell can never paint over it.
            ZStack {
                Color.black.opacity(0.3)
                Button {
                    // `isPlaying` already means *this* card's item is the one playing, so
                    // pausing the shared transport is unambiguous.
                    if isPlaying { model?.music.pause() } else { onPlay() }
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 46, height: 46).shadow(radius: 8, y: 3)
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .foregroundStyle(.black)
                                .contentTransition(
                                    reduceMotion ? .identity : .symbolEffect(.replace.downUp)
                                )
                        }
                    }
                }
                .buttonStyle(.plain)
                .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: isPlaying)
                .help(isPlaying ? "Pause" : "Play")
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .transition(.opacity)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 6)
                if let trailingTop {
                    Text(trailingTop).font(.caption2).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
            }
            HStack(spacing: 6) {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                if let trailingBottom {
                    Text(trailingBottom).font(.caption2).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
            }
        }
    }
}

/// A hover "lift" that respects **Reduce Motion**: scales up on hover normally, but holds still when
/// the user has asked for reduced motion (the card's other hover cues — background tint, shadow —
/// still signal the hover). One helper so every card/row across the app gates motion identically.
extension View {
    func hoverLift(_ hovering: Bool, scale: CGFloat = 1.06) -> some View {
        modifier(HoverLift(hovering: hovering, scale: scale))
    }
}

private struct HoverLift: ViewModifier {
    let hovering: Bool
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.scaleEffect(hovering && !reduceMotion ? scale : 1)
    }
}

/// Arrow-key row navigation for the app's custom (non-`List`) browse tables. Apply to the focusable
/// scroll container; the rows must carry `.id(idForIndex(i))` and reflect `highlighted == i`. ↑/↓
/// move the focus row (scrolling it into view), Return activates it, ⌘Return alt-activates. One
/// shared modifier so Liked/Search, album/playlist detail, and the Albums list all navigate alike.
struct KeyboardRowNavigation: ViewModifier {
    @Binding var highlighted: Int?
    let count: Int
    let proxy: ScrollViewProxy
    let idForIndex: (Int) -> AnyHashable
    let onActivate: (Int) -> Void
    var onAltActivate: ((Int) -> Void)?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.return, phases: .down) { press in
                guard let i = highlighted, i < count else { return .ignored }
                if press.modifiers.contains(.command), let onAltActivate { onAltActivate(i) }
                else { onActivate(i) }
                return .handled
            }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        let next = min(max((highlighted ?? -1) + delta, 0), count - 1)
        highlighted = next
        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(idForIndex(next), anchor: .center) }
        return .handled
    }
}

/// Arrow-key navigation for a **grid**, where left/right move by one and up/down move by a
/// row.
///
/// The list layouts have had `KeyboardRowNavigation` for versions; the grids — which are
/// the *default* layout on Albums, Artists, Playlists and the rest — had nothing, so the
/// twenty grid surfaces in this app were keyboard-dead. Tab reached them and the arrow keys
/// did nothing.
///
/// `columns` is supplied by the caller rather than measured: the grid is
/// `.adaptive(minimum:)`, so only the layout knows how many actually fit, and guessing here
/// would put the cursor somewhere the eye did not follow.
struct KeyboardGridNavigation: ViewModifier {
    @Binding var highlighted: Int?
    let count: Int
    let columns: Int
    let proxy: ScrollViewProxy
    let idForIndex: (Int) -> AnyHashable
    let onActivate: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-max(1, columns)) }
            .onKeyPress(.downArrow) { move(max(1, columns)) }
            .onKeyPress(.return, phases: .down) { _ in
                guard let index = highlighted, index < count else { return .ignored }
                onActivate(index)
                return .handled
            }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        // Clamped, not wrapped: wrapping a grid means pressing right at the end of a row
        // lands you at the start of the next one, which is correct for text and wrong for
        // a wall of covers — the eye expects the cursor to stop at the edge.
        let next = min(max((highlighted ?? -1) + delta, 0), count - 1)
        guard next != highlighted else { return .handled }
        highlighted = next
        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(idForIndex(next), anchor: .center) }
        return .handled
    }
}

extension View {
    /// Arrow-key navigation for a grid. See `KeyboardGridNavigation`.
    func keyboardGridNavigation(
        highlighted: Binding<Int?>,
        count: Int,
        columns: Int,
        proxy: ScrollViewProxy,
        idForIndex: @escaping (Int) -> AnyHashable,
        onActivate: @escaping (Int) -> Void
    ) -> some View {
        modifier(KeyboardGridNavigation(
            highlighted: highlighted, count: count, columns: columns,
            proxy: proxy, idForIndex: idForIndex, onActivate: onActivate
        ))
    }

    func keyboardRowNavigation(
        highlighted: Binding<Int?>,
        count: Int,
        proxy: ScrollViewProxy,
        idForIndex: @escaping (Int) -> AnyHashable,
        onActivate: @escaping (Int) -> Void,
        onAltActivate: ((Int) -> Void)? = nil
    ) -> some View {
        modifier(KeyboardRowNavigation(
            highlighted: highlighted, count: count, proxy: proxy,
            idForIndex: idForIndex, onActivate: onActivate, onAltActivate: onAltActivate
        ))
    }
}

/// Scrolls the currently-playing track into view (centered) when a song list first shows its
/// rows and whenever the playing track changes — so the now-playing row (already styled as
/// "selected") is revealed without manual scrolling. A no-op when the current track isn't in
/// this list, so browsing an unrelated album/playlist never jumps. Rows must carry `.id(<songID>)`.
struct RevealNowPlaying: ViewModifier {
    let proxy: ScrollViewProxy
    /// The song ids currently shown, in order — its *count* is the "rows are laid out" signal.
    let ids: [String]
    let currentID: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: currentID) { _, _ in reveal() }
            // Fires when the async-loaded songs populate (0 → N) or a filter changes the set.
            .onChange(of: ids.count) { _, _ in reveal() }
            .onAppear { reveal() }
    }

    private func reveal() {
        guard let currentID, ids.contains(currentID) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(currentID, anchor: .center) }
    }
}

extension View {
    /// See `RevealNowPlaying`. Apply to the scroll container inside a `ScrollViewReader`.
    func revealNowPlaying(proxy: ScrollViewProxy, ids: [String], currentID: String?) -> some View {
        modifier(RevealNowPlaying(proxy: proxy, ids: ids, currentID: currentID))
    }
}
