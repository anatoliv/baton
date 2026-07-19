import SwiftUI
import UniformTypeIdentifiers

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
    @State private var exportDocument: ListenExportDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var importMessage: String?
    @AppStorage("tonebox.music.historyLayout") private var layout: MusicBrowseLayout = .list
    @FocusState private var filterFocused: Bool

    private var history: MusicPlayHistory { model.musicHistory }

    enum Segment: String, CaseIterable, Identifiable {
        case recent, tracks, albums, artists
        var id: String { rawValue }
        /// Short label for the pill switcher.
        var short: String {
            switch self {
            case .recent: "Recent"
            case .tracks: "Tracks"
            case .albums: "Albums"
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

    private var topAlbums: [(album: String, count: Int, artwork: NavidromeSong)] {
        let list = history.topAlbums(since: window.since)
        guard !query.isEmpty else { return list }
        return list.filter { $0.album.lowercased().contains(query) || ($0.artwork.artist ?? "").lowercased().contains(query) }
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
        case .albums: history.topAlbums(since: window.since).count
        case .artists: history.topArtists(since: window.since).count
        }
    }

    /// The visible (filtered) count for the header badge.
    private var currentCount: Int {
        switch segment {
        case .recent: recentSongs.count
        case .tracks: topTracks.count
        case .albums: topAlbums.count
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
                        archiveMenu
                    },
                    sortMenu: { EmptyView() }
                )
                summaryStrip
                content
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument ?? ListenExportDocument(data: Data(), type: .json),
            contentType: exportDocument?.type ?? .json,
            defaultFilename: exportDocument?.suggestedName ?? "baton-listens"
        ) { _ in }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .plainText]) { result in
            if case let .success(url) = result { importListens(from: url) }
        }
        .alert("Imported", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importMessage ?? "") }
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
        case .albums:
            if topAlbums.isEmpty {
                empty("square.stack", "Nothing yet", "No plays in \(window.rawValue.lowercased()).")
            } else {
                albumsList
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

    private var albumsList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(topAlbums.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 12) {
                        MusicRowThumb(url: item.artwork.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 80) },
                                      isHovering: false, isWorking: false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.album).lineLimit(1)
                            if let artist = item.artwork.artist, !artist.isEmpty {
                                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        countBadge(item.count)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                }
            }
            .padding(.vertical, 8)
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
        case .albums, .artists: break // rankings, not concrete play queues
        }
    }

    // MARK: - Archive menu, summary, export/import

    /// The private-log actions: enable/disable, export (JSON/CSV), import, clear.
    private var archiveMenu: some View {
        Menu {
            Toggle("Log listens on this Mac", isOn: Binding(
                get: { history.isEnabled }, set: { history.isEnabled = $0 }
            ))
            Section("Your data stays on this Mac") {
                Button("Export as ListenBrainz JSON…") { beginExport(.json) }
                Button("Export as CSV…") { beginExport(.csv) }
                Button("Import listens…") { isImporting = true }
            }
            Divider()
            Button("Clear History…", role: .destructive) { showClearConfirm = true }
        } label: {
            Label("Listening log", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Listening log: export, import, or clear — your data stays private")
    }

    /// A compact lifetime/trend banner above the list: total plays, window plays, and a tiny
    /// per-day sparkline so you can see your listening at a glance.
    @ViewBuilder private var summaryStrip: some View {
        // Only for bounded windows — an all-time per-day strip would be thousands of bars.
        let daily = window == .all ? [] : history.dailyCounts(since: window.since)
        HStack(spacing: 14) {
            stat("\(history.lifetimeCount)", "all-time")
            if window != .all {
                stat("\(history.playCount(since: window.since))", window.rawValue.lowercased())
            }
            Spacer()
            if daily.count > 1 {
                Sparkline(values: daily.map { Double($0.count) })
                    .frame(width: 120, height: 22)
                    .help("Plays per day over \(window.rawValue.lowercased())")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func beginExport(_ kind: ListenExportKind) {
        exportDocument = ListenExportDocument(listens: history.portableListens, kind: kind)
        isExporting = true
    }

    private func importListens(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { importMessage = "Couldn't read that file."; return }
        let listens = ListenArchiveIO.parse(data)
        guard !listens.isEmpty else { importMessage = "No listens found in that file."; return }
        let added = history.ingest(listens)
        importMessage = added == 0 ? "Those \(listens.count) listens were already in your history."
            : "Added \(added) listen\(added == 1 ? "" : "s") to your history."
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

/// A tiny bar sparkline for the listening-trend strip. Bars are normalised to the peak; an
/// empty day still shows a hairline so gaps read as "nothing played," not "no data."
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 1, 1)
            let count = max(values.count, 1)
            let gap: CGFloat = values.count > 60 ? 0 : 1
            let barWidth = (geo.size.width - CGFloat(count - 1) * gap) / CGFloat(count)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(barWidth, 0.5),
                               height: max(CGFloat(value / peak) * geo.size.height, value > 0 ? 1.5 : 0.5))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }
}

/// Which portable format the archive is exported as.
enum ListenExportKind { case json, csv }

/// A `FileDocument` wrapper so the listening archive can be saved via the system Save panel in a
/// portable format (ListenBrainz-compatible JSON, or CSV).
struct ListenExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .plainText] }

    var data: Data
    var type: UTType
    var suggestedName: String

    init(data: Data, type: UTType, suggestedName: String = "baton-listens") {
        self.data = data
        self.type = type
        self.suggestedName = suggestedName
    }

    init(listens: [PortableListen], kind: ListenExportKind) {
        switch kind {
        case .json:
            self.init(data: ListenArchiveIO.exportJSON(listens), type: .json)
        case .csv:
            self.init(data: Data(ListenArchiveIO.exportCSV(listens).utf8), type: .commaSeparatedText)
        }
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = .json
        suggestedName = "baton-listens"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
