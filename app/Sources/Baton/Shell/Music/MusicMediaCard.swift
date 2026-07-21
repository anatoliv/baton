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

/// A like-heart **badge** for a song's artwork — filled pink when liked, white
/// outline otherwise; tapping toggles the like. `visible` lets a caller reveal it on
/// hover (it's always shown once liked). Sized to sit in a cover corner.
struct SongHeartBadge: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong
    /// Show the badge even when the song isn't liked (e.g. on row hover, or always on
    /// the now-playing artwork). Liked songs always show it regardless.
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
        .opacity(liked || visible ? 1 : 0)
        .help(liked ? "Unlike" : "Like")
    }
}

/// A song's cover thumbnail that doubles as the play affordance and carries a
/// `SongHeartBadge`. Hover reveals a play overlay (and the heart badge); the current
/// track shows a speaker indicator. Shared leading element for every song row.
struct MusicSongThumb: View {
    @Environment(MusicModel.self) private var model
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
                Color.black.opacity(0.4)
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
            } else if isCurrent {
                Color.black.opacity(0.35)
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.caption).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
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

/// A sort field for the shared `MusicSortControls` — each browse screen's sort enum
/// conforms so the one control can render every screen's fields.
protocol MusicSortField: Identifiable, Hashable, CaseIterable {
    var label: String { get }
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
    /// Highlights the card (accent border + glow) when its entity is the current
    /// queue's source — e.g. the playlist/album/artist you're playing from.
    var isPlayingSource = false
    /// Offline-download state, shown as a corner badge over the artwork (bottom-trailing).
    var downloadStatus: DownloadStatusBadge.Status = .hidden
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
            .overlay(alignment: .topLeading) { badge }
            .overlay(alignment: .bottomTrailing) { downloadOverlay }
            .overlay { hoverPlay }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: isPlayingSource ? 3 : 0)
            }
            .shadow(
                color: isPlayingSource ? Color.playingGlowTint() : .black.opacity(isHovering ? 0.4 : 0.2),
                radius: isPlayingSource ? 14 : (isHovering ? 16 : 8),
                y: isHovering ? 8 : 4
            )
            .animation(.easeInOut(duration: 0.18), value: isPlayingSource)
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
    @ViewBuilder private var fill: some View {
        if let coverURL {
            AsyncImage(url: coverURL) { $0.resizable().scaledToFill() } placeholder: {
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
            AsyncImage(url: coverURL) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
        } else {
            Image(systemName: placeholder).font(.largeTitle).foregroundStyle(.secondary)
        }
    }

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

    @ViewBuilder private var hoverPlay: some View {
        if isHovering {
            // Centered play button over a dark scrim — kept away from every edge so a
            // neighboring grid cell can never paint over it.
            ZStack {
                Color.black.opacity(0.3)
                Button(action: onPlay) {
                    ZStack {
                        Circle().fill(.white).frame(width: 46, height: 46).shadow(radius: 8, y: 3)
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "play.fill").font(.title3).foregroundStyle(.black)
                        }
                    }
                }
                .buttonStyle(.plain)
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
