import SwiftUI

/// The **History** tab: recently-played tracks + top-tracks / top-artists stats over a
/// selectable window, from the local `MusicPlayHistory` log. Shares the **Liked** screen's
/// format — a two-row `MusicBrowseHeader` (title + count badge + pill segments + filter,
/// then transport / window / clear + list⇄grid) over segmented content.
struct MusicHistoryView: View {
    @Environment(MusicModel.self) private var model
    @State private var segment: Segment = .recent
    @State private var window: StatWindow = .week
    @State private var filterText = ""
    @State private var showClearConfirm = false
    @AppStorage("tonebox.music.historyLayout") private var layout: MusicBrowseLayout = .list
    @FocusState private var filterFocused: Bool

    private var history: MusicPlayHistory { model.musicHistory }

    enum Segment: String, CaseIterable, Identifiable {
        case recent, tracks, artists
        var id: String { rawValue }
        /// Short label for the pill switcher.
        var short: String {
            switch self {
            case .recent: "Recent"
            case .tracks: "Tracks"
            case .artists: "Artists"
            }
        }
    }

    enum StatWindow: String, CaseIterable, Identifiable {
        case week = "This Week", month = "This Month", all = "All Time"
        var id: String { rawValue }
        var since: Date {
            switch self {
            case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            case .month: Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? .distantPast
            case .all: .distantPast
            }
        }
    }

    // MARK: - Filtered data

    private var query: String { filterText.trimmingCharacters(in: .whitespaces).lowercased() }

    private var recentSongs: [NavidromeSong] {
        let list = history.recentlyPlayed
        guard !query.isEmpty else { return list }
        return list.filter { $0.title.lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query) }
    }

    private var topTracks: [(song: NavidromeSong, count: Int)] {
        let list = history.topTracks(since: window.since)
        guard !query.isEmpty else { return list }
        return list.filter { $0.song.title.lowercased().contains(query) || ($0.song.artist ?? "").lowercased().contains(query) }
    }

    private var topArtists: [(artist: String, count: Int)] {
        let list = history.topArtists(since: window.since)
        guard !query.isEmpty else { return list }
        return list.filter { $0.artist.lowercased().contains(query) }
    }

    /// Segment item count (unfiltered) — shown on the pills.
    private func count(_ seg: Segment) -> Int {
        switch seg {
        case .recent: history.recentlyPlayed.count
        case .tracks: history.topTracks(since: window.since).count
        case .artists: history.topArtists(since: window.since).count
        }
    }

    /// The visible (filtered) count for the header badge.
    private var currentCount: Int {
        switch segment {
        case .recent: recentSongs.count
        case .tracks: topTracks.count
        case .artists: topArtists.count
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                empty("clock.arrow.circlepath", "No history yet", "Tracks you play show up here.")
            } else {
                MusicBrowseHeader(
                    title: "History",
                    count: currentCount,
                    filter: $filterText,
                    filterPrompt: "Filter history",
                    filterFocused: $filterFocused,
                    filterHistoryKey: "history",
                    layout: $layout,
                    accessory: {
                        HStack(spacing: 12) {
                            Divider().frame(height: 20)
                            segmentPills
                        }
                    },
                    leading: {
                        MusicMiniTransport(onPlayWhenIdle: playCurrent)
                        if segment != .recent {
                            Picker("", selection: $window) {
                                ForEach(StatWindow.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden().fixedSize().controlSize(.small)
                        }
                        Button(role: .destructive) { showClearConfirm = true } label: {
                            Label("Clear", systemImage: "trash").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear play history")
                    },
                    sortMenu: { EmptyView() }
                )
                content
            }
        }
        .confirmationDialog("Clear play history?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { history.clear() }
        } message: {
            Text("Removes your local Recently Played list and stats. It doesn't affect your server's play counts.")
        }
    }

    /// The pill switcher — identical style to the Liked screen's Songs/Albums/Artists.
    private var segmentPills: some View {
        HStack(spacing: 3) {
            ForEach(Segment.allCases) { seg in
                let c = count(seg)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { segment = seg }
                } label: {
                    Text(verbatim: "\(seg.short) \(c)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(segment == seg ? Color.white : .secondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(segment == seg ? Color.accentColor : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(c == 0)
                .opacity(c == 0 ? 0.4 : 1)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.hoverTint))
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch segment {
        case .recent:
            if recentSongs.isEmpty {
                empty("clock.arrow.circlepath", "Nothing here", "No tracks match “\(filterText)”.")
            } else {
                songSegment(recentSongs, label: "History")
            }
        case .tracks:
            if topTracks.isEmpty {
                empty("music.note", "Nothing yet", "No plays in \(window.rawValue.lowercased()).")
            } else {
                songSegment(topTracks.map(\.song), label: "Top Tracks", counts: topTracks.map(\.count))
            }
        case .artists:
            if topArtists.isEmpty {
                empty("music.mic", "Nothing yet", "No plays in \(window.rawValue.lowercased()).")
            } else {
                artistsList
            }
        }
    }

    /// A song segment (Recently Played / Top Tracks) — list or grid, with an optional
    /// per-row play-count badge (Top Tracks). Grid mode drops the count for a compact view.
    @ViewBuilder private func songSegment(_ songs: [NavidromeSong], label: String, counts: [Int]? = nil) -> some View {
        let source = StreamingPlaybackController.QueueSource(label: label, kind: .song, id: nil)
        ScrollView {
            if layout == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        LikedSongGridCell(song: song, isSelected: false, showSelect: false) {
                            model.music.play(songs, startAt: index, source: source)
                        }
                    }
                }
                .padding(16)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        HStack(spacing: 0) {
                            MusicLikedSongRow(song: song, showSelect: false) {
                                model.music.play(songs, startAt: index, source: source)
                            }
                            if let counts, counts.indices.contains(index) { countBadge(counts[index]) }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 16)
    }

    private var artistsList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(topArtists, id: \.artist) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "music.mic").foregroundStyle(.secondary).frame(width: 24)
                        Text(item.artist).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        countBadge(item.count)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 16)
    }

    private func countBadge(_ count: Int) -> some View {
        Text(verbatim: "\(count)×").font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .padding(.trailing, 10)
    }

    // MARK: - Actions

    private func playCurrent() {
        switch segment {
        case .recent: model.music.play(recentSongs, source: .init(label: "History", kind: .song, id: nil))
        case .tracks: model.music.play(topTracks.map(\.song), source: .init(label: "Top Tracks", kind: .song, id: nil))
        case .artists: break // no track list for the artists ranking
        }
    }

    private func empty(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            Text(subtitle).font(.callout).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
