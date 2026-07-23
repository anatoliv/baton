import SwiftUI

/// The **client-side** Podcasts screen — Baton's own RSS subscriptions, fetched directly from
/// feeds rather than the music server. This is the universal podcast experience (it works on
/// Navidrome, which has no Subsonic podcast API); `MusicPodcastsView` routes here whenever the
/// server can't serve podcasts itself. Episodes play through the normal music player: an
/// episode maps to a `NavidromeSong` whose id is its enclosure URL, which the playback
/// controller streams directly.
struct ClientPodcastsView: View {
    @Environment(MusicModel.self) private var model

    @State private var selected: PodcastChannel?
    @State private var filterText = ""
    @State private var showingAdd = false
    @State private var refreshing = false
    @State private var showSel = MusicMultiSelect()
    @FocusState private var filterFocused: Bool
    @AppStorage("tonebox.music.clientPodcastLayout") private var layout: MusicBrowseLayout = .grid
    @AppStorage("tonebox.music.clientPodcastSort") private var sortField: PodcastSort = .recent
    @AppStorage("tonebox.music.clientPodcastSortAscending") private var sortAscending = false

    enum PodcastSort: String, CaseIterable, Identifiable, MusicSortField {
        case name, recent, episodes
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: "Name"
            case .recent: "Latest episode"
            case .episodes: "Episodes"
            }
        }
    }

    private var store: PodcastSubscriptionStore { model.podcastSubscriptions }

    private var filteredChannels: [PodcastChannel] {
        var list = store.channels
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty { list = list.filter { $0.title.lowercased().contains(query) } }
        switch sortField {
        case .name:
            list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .recent:
            list.sort { ($0.episodes.first?.publishDate ?? .distantPast) < ($1.episodes.first?.publishDate ?? .distantPast) }
        case .episodes:
            list.sort { $0.episodes.count < $1.episodes.count }
        }
        if !sortAscending { list.reverse() }
        return list
    }

    var body: some View {
        browser
            // Push onto the ambient NavigationStack (from `MusicView`) for back-swipe / ⌘[ parity
            // with the rest of the app. Re-derive the live channel so freshly-fetched episodes show.
            .navigationDestination(item: $selected) { channel in
                ClientPodcastChannelDetail(channel: store.channels.first(where: { $0.id == channel.id }) ?? channel)
            }
            .task { await store.loadIfNeeded() }
            .onChange(of: store.channels) { _, channels in
                // A removed show shouldn't strand the detail view on nothing.
                if let selected, !channels.contains(where: { $0.id == selected.id }) { self.selected = nil }
            }
            .sheet(isPresented: $showingAdd) { AddPodcastSheet() }
    }

    // MARK: - Browser

    @ViewBuilder private var browser: some View {
        if store.channels.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                MusicBrowseHeader(
                    title: "Podcasts",
                    count: filteredChannels.count,
                    filter: $filterText,
                    filterPrompt: "Filter podcasts",
                    filterFocused: $filterFocused,
                    filterHistoryKey: "client-podcasts",
                    layout: $layout,
                    accessory: { EmptyView() },
                    // Add Show lives on the second row (leading), matching Radio's Add Station.
                    leading: {
                        if showSel.isEmpty {
                            HStack(spacing: 8) { addButton; refreshButton }
                        } else {
                            showSelectionBar
                        }
                    },
                    sortMenu: { MusicSortControls(ascending: $sortAscending, selection: $sortField) }
                )
                channelsScroll
            }
            .onChange(of: showOrderedIDs) { _, ids in showSel.reconcile(ids) }
        }
    }

    private var showOrderedIDs: [String] { filteredChannels.map(\.id) }
    private var selectedChannels: [PodcastChannel] { filteredChannels.filter { showSel.contains($0.id) } }

    /// Unsubscribes a show and reclaims what it left behind — its downloaded episode files and
    /// listening progress — so nothing is stranded on disk after the channel is gone.
    private func unsubscribe(_ channel: PodcastChannel) {
        let episodeIDs = channel.episodes.map { $0.enclosureURL.absoluteString }
        for id in episodeIDs { MusicDownloadStore.shared.delete(id) }
        model.podcastProgress.remove(ids: episodeIDs)
        store.unsubscribe(channel)
    }

    /// Batch bar for selected shows — unsubscribe several at once, or refresh all feeds.
    private var showSelectionBar: some View {
        MusicSelectionBar(
            count: showSel.selectedCount(in: showOrderedIDs),
            allSelected: showSel.allSelected(showOrderedIDs),
            selectAllShortcut: !filterFocused,
            onToggleSelectAll: { showSel.toggleSelectAll(showOrderedIDs) },
            onClear: { showSel.clear() }
        ) {
            MusicBatchButton(system: "arrow.clockwise", help: "Refresh feeds") {
                Task { await store.refresh() }
            }
            MusicBatchButton(system: "trash", help: "Unsubscribe selected", tint: .red) {
                let toRemove = selectedChannels
                showSel.clear()
                for channel in toRemove { unsubscribe(channel) }
            }
        }
    }

    private var addButton: some View {
        Button { showingAdd = true } label: { Label("Add Show", systemImage: "plus") }
            .buttonStyle(.borderless)
            .help("Subscribe to a podcast by its RSS feed URL")
    }

    /// Refresh all feeds from the header — previously only reachable by first selecting a show.
    private var refreshButton: some View {
        Button {
            Task { refreshing = true; await store.refresh(); refreshing = false }
        } label: {
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(refreshing)
        .help("Check all subscribed feeds for new episodes")
    }

    private var channelsScroll: some View {
        ScrollView {
            if layout == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(filteredChannels) { channel in
                        ClientPodcastCell(
                            channel: channel,
                            isSelected: showSel.contains(channel.id),
                            selecting: !showSel.isEmpty,
                            onToggleSelect: { showSel.clicked(channel.id, ordered: showOrderedIDs) },
                            onOpen: { selected = channel },
                            onRemove: { unsubscribe(channel) }
                        )
                    }
                }
                .padding(16)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(filteredChannels) { channel in
                        ClientPodcastListRow(
                            channel: channel,
                            isSelected: showSel.contains(channel.id),
                            selecting: !showSel.isEmpty,
                            onToggleSelect: { showSel.clicked(channel.id, ordered: showOrderedIDs) },
                            onOpen: { selected = channel },
                            onRemove: { unsubscribe(channel) }
                        )
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No podcasts yet").font(.headline)
            Text("Subscribe to a podcast by pasting its RSS feed URL. Baton fetches episodes "
                + "directly, so this works with any server — including Navidrome.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { showingAdd = true } label: { Label("Add a Show", systemImage: "plus") }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 40)
        .sheet(isPresented: $showingAdd) { AddPodcastSheet() }
    }
}

// MARK: - Add-subscription sheet

/// A small sheet to subscribe to a podcast by feed URL. Validates + fetches the feed before
/// dismissing, surfacing a parse/HTTP failure inline rather than adding a broken subscription.
private struct AddPodcastSheet: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var normalizedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Assume https:// when the user pastes a bare host.
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.scheme?.hasPrefix("http") == true, url.host != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Podcast").font(.headline)
            Text("Paste the show's RSS feed URL.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("https://example.com/feed.xml", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }
                .disabled(working)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button {
                    submit()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Subscribe") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || normalizedURL == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func submit() {
        guard let url = normalizedURL, !working else {
            error = "Enter a valid feed URL."
            return
        }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let channel = try await model.podcastSubscriptions.subscribe(to: url)
                model.music.postToast("Subscribed to “\(channel.title)”", symbol: "mic.fill")
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Channel cell / row

private struct ClientPodcastCell: View {
    @Environment(MusicModel.self) private var model
    let channel: PodcastChannel
    let isSelected: Bool
    let selecting: Bool
    let onToggleSelect: () -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        MusicMediaCard(
            coverURL: channel.imageURL,
            aspect: 1,
            placeholder: "mic",
            title: channel.title,
            subtitle: channel.episodes.first?.title ?? "",
            isHovering: hover,
            onPlay: onOpen
        )
        // Selection checkbox top-leading over the cover, like the Downloads grid cards.
        .overlay(alignment: .topLeading) {
            if hover || selecting {
                MusicSelectCheckbox(isSelected: isSelected, onToggle: onToggleSelect)
                    .padding(8).background(.black.opacity(0.35), in: Circle()).padding(6)
            }
        }
        .onHover { hover = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Open", action: onOpen)
            PinMenuButton(item: .channel(channel), model: model)
            Button("Unsubscribe", systemImage: "trash", role: .destructive, action: onRemove)
        }
    }
}

private struct ClientPodcastListRow: View {
    @Environment(MusicModel.self) private var model
    let channel: PodcastChannel
    let isSelected: Bool
    let selecting: Bool
    let onToggleSelect: () -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            MusicSelectCheckbox(isSelected: isSelected, visible: hover || selecting, onToggle: onToggleSelect)
            Button(action: onOpen) {
                thumbnail
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { PodcastRowThumbOverlay(hover: hover) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(channel.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title).font(.body.weight(.medium)).lineLimit(1)
                if let newest = channel.episodes.first?.title {
                    Text(newest).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(channel.title), podcast, \(channel.episodes.count) episode\(channel.episodes.count == 1 ? "" : "s")")

            PodcastEpisodeCountColumn(count: channel.episodes.count)

            Menu {
                Button("Open", action: onOpen)
                Button("Unsubscribe", systemImage: "trash", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More actions for \(channel.title)")
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(hover ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Open", action: onOpen)
            PinMenuButton(item: .channel(channel), model: model)
            Button("Unsubscribe", systemImage: "trash", role: .destructive, action: onRemove)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = channel.imageURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { PodcastRowThumbPlaceholder() }
        } else {
            PodcastRowThumbPlaceholder()
        }
    }
}

// MARK: - Channel detail

/// One subscribed show's episodes over an album-style hero: cover artwork + blurred backdrop,
/// a meta line, a Play/Shuffle/Queue action bar, and a filter. Tapping an episode plays it and
/// queues the rest of the show after it. Every client-side episode is immediately playable — no
/// per-episode download step, unlike the server-side podcasts.
private struct ClientPodcastChannelDetail: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let channel: PodcastChannel

    /// Hero artwork, decoded once (mirrors the album/artist page — a direct feed image URL,
    /// loaded into an `Image` so the banner backdrop doesn't flicker on re-render).
    @State private var heroImage: Image?
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    @State private var sel = MusicMultiSelect()

    private var queueSource: StreamingPlaybackController.QueueSource {
        .init(label: channel.title, kind: .playlist, id: channel.id)
    }

    private var orderedIDs: [String] { visibleEpisodes.map { $0.enclosureURL.absoluteString } }
    private var selectedEpisodes: [PodcastEpisode] {
        visibleEpisodes.filter { sel.contains($0.enclosureURL.absoluteString) }
    }
    private var selectedSongs: [NavidromeSong] {
        selectedEpisodes.map { $0.asSong(channelTitle: channel.title, artwork: $0.imageURL ?? channel.imageURL) }
    }

    /// The whole show as a play queue (each episode carrying its cover as direct artwork).
    private var allSongs: [NavidromeSong] {
        channel.episodes.map { $0.asSong(channelTitle: channel.title, artwork: $0.imageURL ?? channel.imageURL) }
    }

    private var visibleEpisodes: [PodcastEpisode] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return channel.episodes }
        return channel.episodes.filter {
            $0.title.lowercased().contains(query) || ($0.description ?? "").lowercased().contains(query)
        }
    }

    /// "N episodes · Updated Jul 17, 2026" — the meta after the PODCAST kind label.
    private var metaText: String {
        var parts = [channel.episodes.count == 1 ? "1 episode" : "\(channel.episodes.count) episodes"]
        if let updated = channel.episodes.first?.publishDate ?? channel.lastRefreshed {
            let formatter = DateFormatter(); formatter.dateStyle = .medium
            parts.append("Updated \(formatter.string(from: updated))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MusicAlbumBanner(
                    name: channel.title,
                    kindLabel: "PODCAST",
                    detail: metaText,
                    heroImage: heroImage,
                    accentColor: ArtistMonogram.color(channel.title),
                    placeholderIcon: "mic",
                    onBack: { dismiss() }
                )
                if let description = channel.description {
                    Text(description)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(4)
                        .padding(.horizontal, 16).padding(.top, 12)
                }
                if channel.episodes.isEmpty {
                    Text("No episodes")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(24)
                } else {
                    episodesHeader
                    episodeList
                }
            }
            .padding(.bottom, 16)
        }
        .navigationBarBackButtonHidden(true)
        .task(id: channel.id) { await loadHero() }
    }

    /// The "Episodes" bar — count, transport (Play), Shuffle + Add to Queue, and a filter —
    /// mirroring the album detail's "Songs" header.
    private var episodesHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Episodes").font(.title3.weight(.semibold))
                Text("\(visibleEpisodes.count)")
                    .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            if sel.isEmpty {
                MusicMiniTransport(onPlayWhenIdle: { model.music.play(allSongs, source: queueSource) }, pageSource: queueSource)
                MusicRowActions(actions: [
                    MusicRowAction(title: "Shuffle", systemImage: "shuffle") { shuffle() },
                    MusicRowAction(title: "Add to Queue", systemImage: "text.append") { model.music.enqueue(allSongs) },
                ])
                downloadMenu
            } else {
                episodeSelectionBar
            }
            Spacer()
            MusicFilterField(text: $filter, prompt: "Filter episodes", focused: $filterFocused, historyKey: "clientPodcastEpisodes")
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    /// Batch bar shown while episodes are selected — play / queue / download / mark-played over
    /// the selection, reusing the shared multi-select chrome from the library screens.
    private var episodeSelectionBar: some View {
        MusicSelectionBar(
            count: sel.selectedCount(in: orderedIDs),
            allSelected: sel.allSelected(orderedIDs),
            selectAllShortcut: !filterFocused,
            onToggleSelectAll: { sel.toggleSelectAll(orderedIDs) },
            onClear: { sel.clear() }
        ) {
            MusicBatchButton(system: "play.fill", help: "Play selected") {
                let songs = selectedSongs
                if !songs.isEmpty { model.music.play(songs, source: queueSource) }
            }
            MusicBatchButton(system: "text.line.first.and.arrowtriangle.forward", help: "Play next") {
                model.music.playNext(selectedSongs)
            }
            MusicBatchButton(system: "text.append", help: "Add to queue") {
                model.music.enqueue(selectedSongs)
            }
            MusicBatchButton(system: "arrow.down.circle", help: "Download selected") { downloadSelected() }
            MusicBatchButton(system: "trash.slash", help: "Remove downloads") { removeSelectedDownloads() }
            MusicBatchButton(system: "checkmark.circle", help: "Mark as played") { markSelectedPlayed() }
            // Now routed through the shared component so a large selection confirms first.
            WebhookBatchMenu(
                tokenSets: { selectedEpisodes.map { PodcastWebhookTokens.tokens(episode: $0, channel: channel) } },
                count: selectedEpisodes.count
            )
        }
    }

    private func downloadSelected() {
        let songs = selectedSongs
        guard !songs.isEmpty else { return }
        model.music.postToast("Downloading \(songs.count) episode\(songs.count == 1 ? "" : "s")", symbol: "arrow.down.circle.fill")
        Task { await MusicDownloadStore.shared.download(songs) }
    }

    private func removeSelectedDownloads() {
        for episode in selectedEpisodes { MusicDownloadStore.shared.delete(episode.enclosureURL.absoluteString) }
    }

    private func markSelectedPlayed() {
        for episode in selectedEpisodes { model.podcastProgress.markPlayed(id: episode.enclosureURL.absoluteString) }
        sel.clear()
    }

    /// Show-level download: fetch the newest N episodes (or all) for offline listening, and
    /// remove the show's downloads. Episodes download through `MusicDownloadStore` and then play
    /// from disk automatically.
    private var downloadMenu: some View {
        Menu {
            Button("Download Latest 5") { download(latest: 5) }
            Button("Download Latest 10") { download(latest: 10) }
            Button("Download All Episodes") { download(latest: channel.episodes.count) }
            if downloadedCount > 0 {
                Divider()
                Text("\(downloadedCount) downloaded")
                Button("Remove Downloads", role: .destructive) { removeAllDownloads() }
            }
        } label: {
            Image(systemName: "arrow.down.circle").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Download episodes for offline listening")
    }

    private var downloadedCount: Int {
        channel.episodes.reduce(0) { $0 + (MusicDownloadStore.shared.isDownloaded($1.enclosureURL.absoluteString) ? 1 : 0) }
    }

    private func song(for episode: PodcastEpisode) -> NavidromeSong {
        episode.asSong(channelTitle: channel.title, artwork: episode.imageURL ?? channel.imageURL)
    }

    private func download(latest count: Int) {
        let songs = channel.episodes.prefix(max(0, count)).map { song(for: $0) }
        guard !songs.isEmpty else { return }
        model.music.postToast("Downloading \(songs.count) episode\(songs.count == 1 ? "" : "s")", symbol: "arrow.down.circle.fill")
        Task { await MusicDownloadStore.shared.download(songs) }
    }

    private func removeAllDownloads() {
        for episode in channel.episodes {
            MusicDownloadStore.shared.delete(episode.enclosureURL.absoluteString)
        }
    }

    private var episodeList: some View {
        LazyVStack(spacing: 2) {
            ForEach(visibleEpisodes) { episode in
                let id = episode.enclosureURL.absoluteString
                ClientPodcastEpisodeRow(
                    episode: episode,
                    channel: channel,
                    isCurrent: model.music.nowPlaying?.id == id,
                    isSelected: sel.contains(id),
                    selecting: !sel.isEmpty,
                    onToggleSelect: { sel.clicked(id, ordered: orderedIDs) },
                    onPlay: { play(episode) },
                    onDownload: { Task { await MusicDownloadStore.shared.download(song(for: episode)) } },
                    onRemoveDownload: { MusicDownloadStore.shared.delete(id) }
                )
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .onChange(of: orderedIDs) { _, ids in sel.reconcile(ids) }
    }

    private func play(_ episode: PodcastEpisode) {
        let index = channel.episodes.firstIndex(of: episode) ?? 0
        model.music.play(allSongs, startAt: index, source: queueSource)
    }

    private func shuffle() {
        guard !allSongs.isEmpty else { return }
        model.music.play(allSongs.shuffled(), source: queueSource)
    }

    private func loadHero() async {
        heroImage = nil
        guard let url = channel.imageURL, let image = await MusicAlbumDetail.fetchImage(url) else { return }
        withAnimation(.easeOut(duration: 0.25)) { heroImage = image }
    }
}

/// An episode row with the show's artwork thumbnail (hover → play overlay, current → equalizer),
/// title, and date · duration — the podcast analogue of the album track row.
private struct ClientPodcastEpisodeRow: View {
    @Environment(MusicModel.self) private var model
    let episode: PodcastEpisode
    let channel: PodcastChannel
    let isCurrent: Bool
    let isSelected: Bool
    /// A selection is active somewhere in the list — keep every row's checkbox visible so more
    /// can be added, not just the hovered one.
    let selecting: Bool
    let onToggleSelect: () -> Void
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onRemoveDownload: () -> Void
    @State private var hover = false

    private var artURL: URL? { episode.imageURL ?? channel.imageURL }
    private var songID: String { episode.enclosureURL.absoluteString }
    private var isDownloaded: Bool { MusicDownloadStore.shared.isDownloaded(songID) }
    private var isDownloading: Bool { MusicDownloadStore.shared.isDownloading(songID) }
    private var isPlayed: Bool { model.podcastProgress.isPlayed(id: songID) }
    /// Partial-progress fraction (nil at start / when finished) — drives the thin progress bar.
    private var progressFraction: Double? {
        guard let f = model.podcastProgress.fraction(id: songID), f > 0, f < 1 else { return nil }
        return f
    }

    var body: some View {
        HStack(spacing: 12) {
            MusicSelectCheckbox(isSelected: isSelected, visible: hover || selecting, onToggle: onToggleSelect)
            Button(action: onPlay) {
                thumbnail
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay { thumbOverlay }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.accentColor : (isPlayed ? .secondary : .primary))
                    .lineLimit(1)
                if let sub = subLine {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let fraction = progressFraction { progressBar(fraction) }
            }
            Spacer(minLength: 8)
            // The thumbnail (with its hover play overlay) is the single play affordance — same
            // as the album track rows — so no redundant trailing play button. The equalizer
            // marks the current episode; a checkmark marks a finished one; duration is always
            // shown, tertiary, like a track row.
            if isCurrent {
                EqualizerBars(active: true, color: Color.accentColor)
            } else if isPlayed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).help("Played")
            }
            downloadIndicator
            if let seconds = episode.duration, seconds > 0 {
                Text("\(max(1, seconds / 60)) min")
                    .font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(hover ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button("Play", action: onPlay)
            PinMenuButton(item: .episode(episode, channel: channel), model: model)
            if isPlayed {
                Button("Mark as Unplayed", systemImage: "circle") { model.podcastProgress.markUnplayed(id: songID) }
            } else {
                Button("Mark as Played", systemImage: "checkmark.circle") { model.podcastProgress.markPlayed(id: songID) }
            }
            Divider()
            if isDownloaded {
                Button("Remove Download", systemImage: "trash", role: .destructive, action: onRemoveDownload)
            } else if !isDownloading {
                Button("Download", systemImage: "arrow.down.circle", action: onDownload)
            }
            if !model.webhookActions.actions.isEmpty {
                Divider()
                Menu("Actions") {
                    ForEach(model.webhookActions.actions) { action in
                        Button(action.name, systemImage: action.icon) {
                            WebhookRunner.run(action, tokens: PodcastWebhookTokens.tokens(episode: episode, channel: channel), model)
                        }
                    }
                }
            }
        }
    }

    /// A thin accent progress bar for a partially-played episode.
    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.accentColor).frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 3).frame(maxWidth: 220)
    }

    /// Download affordance: a spinner while fetching, a filled badge when offline-ready, or a
    /// download button on hover — mirroring the library track row's passive indicator. All
    /// states share one fixed, center-aligned slot (with a matching font and a `.plain` button,
    /// so no control chrome offsets it) so the glyph stays vertically centered and the duration
    /// never shifts as the state changes.
    @ViewBuilder private var downloadIndicator: some View {
        Group {
            if isDownloading {
                ProgressView().controlSize(.small)
            } else if isDownloaded {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).help("Downloaded")
            } else if hover {
                Button(action: onDownload) { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Download for offline")
            } else {
                Color.clear
            }
        }
        .font(.callout)
        .frame(width: 22, height: 22)
    }

    @ViewBuilder private var thumbnail: some View {
        if let artURL {
            AsyncImage(url: artURL) { image in image.resizable().scaledToFill() } placeholder: { PodcastRowThumbPlaceholder() }
        } else {
            PodcastRowThumbPlaceholder()
        }
    }

    @ViewBuilder private var thumbOverlay: some View {
        if hover || isCurrent {
            ZStack {
                Color.black.opacity(0.34)
                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.fill")
                    .font(.caption).foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// "Jul 9, 2026" — plus "· 12 min left" while an episode is partway through.
    private var subLine: String? {
        var parts: [String] = []
        if let date = episode.publishDate {
            let formatter = DateFormatter(); formatter.dateStyle = .medium
            parts.append(formatter.string(from: date))
        }
        if let remaining = model.podcastProgress.remaining(id: songID), remaining > 60 {
            parts.append("\(Int(remaining / 60)) min left")
        } else if isPlayed {
            parts.append("Played")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
