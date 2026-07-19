import SwiftUI

/// The **Podcasts** tab. Baton has two podcast backends and this router picks between them:
///
/// - **Server-side** (`ServerPodcastsView`) — the server's own Subsonic-managed podcast
///   subscriptions. Used only when the server actually implements the podcast API (gonic,
///   Airsonic, Ampache…).
/// - **Client-side** (`ClientPodcastsView`) — Baton's own RSS subscriptions, fetched directly
///   from feeds. The universal fallback that works everywhere, including Navidrome, which
///   never implements the Subsonic podcast API.
///
/// The choice keys off `model.podcastCapability`, which probes the server once. Before that
/// resolves (`.unknown`), we show the client-side view — it works on every server, so it's the
/// safe default; a server that turns out to support podcasts natively then swaps to its view.
struct MusicPodcastsView: View {
    @Environment(MusicModel.self) private var model

    var body: some View {
        if model.podcastCapability.support == .supported {
            ServerPodcastsView()
        } else {
            ClientPodcastsView()
        }
    }
}

/// The server-side Podcasts screen — browses the subscribed podcast channels the *server*
/// manages (Subsonic `getPodcasts`) and plays their episodes through the music player.
/// Read-only over the library (channels/episodes are fetched directly from a `NavidromeClient`,
/// since podcasts live outside `MusicLibraryStore`); playback routes through `model.music.play`,
/// exactly like the album/playlist detail views. Episodes stream just like songs — an episode
/// maps to a `NavidromeSong` by its `streamID`, the same media id `stream`/`getSong` use.
struct ServerPodcastsView: View {
    @Environment(MusicModel.self) private var model

    @State private var channels: [NavidromePodcastChannel] = []
    @State private var newest: [NavidromePodcastEpisode] = []
    @State private var selected: NavidromePodcastChannel?
    @State private var loading = false
    @State private var loaded = false
    @State private var loadError: String?
    /// The server doesn't implement the Subsonic podcast API (e.g. Navidrome). Distinct from
    /// `loadError` so we show an honest "not available here" state, not a scary HTTP error.
    @State private var unsupported = false
    @State private var filterText = ""
    @FocusState private var filterFocused: Bool
    /// List ⇄ grid + sort, persisted like the other browse screens.
    @AppStorage("tonebox.music.podcastLayout") private var layout: MusicBrowseLayout = .grid
    @AppStorage("tonebox.music.podcastSort") private var sortField: PodcastSort = .name
    @AppStorage("tonebox.music.podcastSortAscending") private var sortAscending = true

    /// Sort fields for the Podcasts screen (mirrors the other browse screens).
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

    /// Channels after the header's filter + sort controls are applied.
    private var filteredChannels: [NavidromePodcastChannel] {
        var list = channels
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty { list = list.filter { $0.title.lowercased().contains(query) } }
        switch sortField {
        case .name:
            list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .recent:
            // Episodes are stored newest-first, so the first one's date is the channel's latest.
            list.sort { ($0.episodes.first?.publishDate ?? "") < ($1.episodes.first?.publishDate ?? "") }
        case .episodes:
            list.sort { $0.episodes.count < $1.episodes.count }
        }
        if !sortAscending { list.reverse() }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            if let selected {
                MusicPodcastChannelDetail(channel: selected) { self.selected = nil }
            } else {
                channelBrowser
            }
        }
        .task { await loadIfNeeded() }
    }

    // MARK: - Channel browser

    @ViewBuilder private var channelBrowser: some View {
        if unsupported {
            unsupportedState
        } else if loading, channels.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, channels.isEmpty {
            errorState(loadError)
        } else if channels.isEmpty, loaded {
            emptyState
        } else {
            VStack(spacing: 0) {
                // Shared browse header (title · count · filter, then sort + layout toggle) so
                // Podcasts lines up with Albums/Artists/Playlists/Radio.
                MusicBrowseHeader(
                    title: "Podcasts",
                    count: filteredChannels.count,
                    filter: $filterText,
                    filterPrompt: "Filter podcasts",
                    filterFocused: $filterFocused,
                    filterHistoryKey: "podcasts",
                    layout: $layout,
                    accessory: { EmptyView() },
                    leading: { EmptyView() },
                    sortMenu: { MusicSortControls(ascending: $sortAscending, selection: $sortField) }
                )
                channelsScroll
            }
        }
    }

    private var channelsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !newestPlayable.isEmpty { latestStrip }
                if layout == .grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(filteredChannels) { channel in
                            PodcastChannelCell(channel: channel) { selected = channel }
                        }
                    }
                    .padding(16)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredChannels) { channel in
                            PodcastChannelListRow(channel: channel) { selected = channel }
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: - Latest episodes strip

    /// The newest episodes that are streamable right now (they carry a `streamID`). The strip
    /// only offers things you can press play on; not-yet-downloaded new episodes live in their
    /// channel, where the Download action is.
    private var newestPlayable: [NavidromePodcastEpisode] { newest.filter(\.isPlayable) }

    /// `episodeID → owning channel`, from the already-loaded channel list. Lets a strip episode
    /// borrow its channel's title (for the now-playing artist/queue label) and cover-art
    /// fallback without another request.
    private var channelByEpisodeID: [String: NavidromePodcastChannel] {
        var map: [String: NavidromePodcastChannel] = [:]
        for channel in channels {
            for episode in channel.episodes { map[episode.id] = channel }
        }
        return map
    }

    private var latestStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest Episodes")
                .font(.headline)
                .padding(.horizontal, 16).padding(.top, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(newestPlayable) { episode in
                        LatestEpisodeCard(episode: episode, channel: channelByEpisodeID[episode.id]) {
                            play(newest: episode)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 4)
    }

    /// Plays a strip episode and queues the rest of the strip after it, so pressing one latest
    /// episode rolls into the others. Each episode borrows its channel's title/cover for the
    /// now-playing metadata.
    private func play(newest episode: NavidromePodcastEpisode) {
        let queue = newestPlayable
        guard let index = queue.firstIndex(of: episode) else { return }
        let songs = queue.map { ep -> NavidromeSong in
            let channel = channelByEpisodeID[ep.id]
            return ep.asSong(channelTitle: channel?.title ?? ep.title, fallbackCoverID: channel?.coverArtID)
        }
        model.music.play(
            songs, startAt: index,
            source: .init(label: "Latest Episodes", kind: .playlist, id: "podcast-newest")
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.slash").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No podcasts").font(.headline)
            Text("Subscribe to podcasts on your server and they'll show up here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 40)
    }

    /// Shown when the server can't serve podcasts at all — it doesn't implement the Subsonic
    /// podcast API. The Podcasts nav item normally hides on such servers; this covers the brief
    /// window before that probe resolves, and the case where the tab was already open.
    private var unsupportedState: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.slash").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Podcasts aren't available on this server").font(.headline)
            Text("Your music server doesn't implement the Subsonic podcast API, so Baton can't "
                + "list or play podcasts from it — Navidrome, in particular, doesn't support "
                + "podcasts. A future Baton update will add its own podcast subscriptions that "
                + "work with any server.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Couldn't load podcasts").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try Again") { Task { loaded = false; await loadIfNeeded() } }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 40)
    }

    // MARK: - Data

    private func loadIfNeeded() async {
        guard !loaded, !loading else { return }
        loading = true
        loadError = nil
        defer { loading = false; loaded = true }
        do {
            let client = try NavidromeConfig.makeClient()
            // Channels with episodes inline (one round-trip powers both the grid's "newest
            // episode" subtitles and the detail view) plus the cross-channel "latest episodes"
            // strip, fetched concurrently. The newest list is best-effort — a failure there
            // shouldn't blank the whole tab.
            async let channelList = client.getPodcasts(includeEpisodes: true)
            let latest = try? await client.getNewestPodcasts(count: 12)
            channels = try await channelList
            newest = latest ?? []
            model.podcastCapability.record(.supported)
        } catch {
            // A 501/404 means the server has no podcast API — show the honest "unsupported"
            // state and tell the shared store so the nav item hides. Anything else is a real
            // (often transient) error and keeps the retryable error state.
            if PodcastCapabilityStore.classify(error) == .unsupported {
                unsupported = true
                model.podcastCapability.record(.unsupported)
            } else {
                loadError = (error as? NavidromeError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Channel cell

/// A podcast channel card for the browse grid — cover, title, and the newest episode title
/// as a subtitle. Mirrors the album cards' `MusicMediaCard` layout.
private struct PodcastChannelCell: View {
    @Environment(MusicModel.self) private var model
    let channel: NavidromePodcastChannel
    let onOpen: () -> Void
    @State private var hover = false

    private var newestEpisode: String? {
        channel.episodes.first.map(\.title)
    }

    var body: some View {
        MusicMediaCard(
            coverURL: channel.coverArtID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 400) },
            aspect: 1,
            placeholder: "mic",
            title: channel.title,
            subtitle: newestEpisode ?? "",
            isHovering: hover,
            onPlay: onOpen
        )
        .onHover { hover = $0 }
        .onTapGesture(perform: onOpen)
    }
}

// MARK: - Channel list row

/// A compact row for the list layout: cover/mic thumbnail (with a hover "open" overlay), title,
/// newest-episode subtitle, a fixed-width episode-count column, and an ellipsis actions menu.
/// Mirrors `RadioStationListRow` so the Podcasts and Radio tables read as one system.
private struct PodcastChannelListRow: View {
    @Environment(MusicModel.self) private var model
    let channel: NavidromePodcastChannel
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                thumbnail
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { PodcastRowThumbOverlay(hover: hover) }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title).font(.body.weight(.medium)).lineLimit(1)
                if let newest = channel.episodes.first?.title {
                    Text(newest).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PodcastEpisodeCountColumn(count: channel.episodes.count)

            Menu {
                Button("Open", action: onOpen)
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(hover ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = channel.coverArtID.flatMap({ model.musicLibrary.coverArtURL(id: $0, size: 88) }) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                PodcastRowThumbPlaceholder()
            }
        } else {
            PodcastRowThumbPlaceholder()
        }
    }
}

// MARK: - Shared podcast-row bits (styled to match the Radio table)

/// The dark hover overlay + "open" chevron shown on a channel thumbnail — the podcast
/// equivalent of `RadioStationListRow`'s play/stop overlay.
struct PodcastRowThumbOverlay: View {
    let hover: Bool
    var body: some View {
        if hover {
            ZStack {
                Color.black.opacity(0.34)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The mic-in-a-tinted-square placeholder used when a channel has no artwork.
struct PodcastRowThumbPlaceholder: View {
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: "mic").foregroundStyle(.secondary)
        }
    }
}

/// The fixed-width "N episodes" column that keeps the trailing controls aligned across rows,
/// matching the width of Radio's website column.
struct PodcastEpisodeCountColumn: View {
    let count: Int
    var body: some View {
        Group {
            if count > 0 {
                Text("\(count) episode\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 96, alignment: .trailing)
    }
}

// MARK: - Latest episode card

/// A card in the "Latest Episodes" strip — the episode's cover (falling back to its channel's),
/// title, and the channel name. Tapping plays the episode through the music player.
private struct LatestEpisodeCard: View {
    @Environment(MusicModel.self) private var model
    let episode: NavidromePodcastEpisode
    let channel: NavidromePodcastChannel?
    let onPlay: () -> Void
    @State private var hover = false

    private var coverID: String? { episode.coverArtID ?? channel?.coverArtID }

    var body: some View {
        MusicMediaCard(
            coverURL: coverID.flatMap { model.musicLibrary.coverArtURL(id: $0, size: 300) },
            aspect: 1,
            placeholder: "mic",
            title: episode.title,
            subtitle: channel?.title ?? "",
            isHovering: hover,
            onPlay: onPlay
        )
        .frame(width: 156)
        .onHover { hover = $0 }
        .onTapGesture(perform: onPlay)
    }
}

// MARK: - Channel detail (episode list)

/// One channel's episodes. Tapping an episode plays it through the music player; the whole
/// list becomes the queue (starting at the tapped episode) so playing one continues into the
/// rest of the show. Only "completed" episodes carry a stream id — the others render disabled.
private struct MusicPodcastChannelDetail: View {
    @Environment(MusicModel.self) private var model
    let channel: NavidromePodcastChannel
    let onBack: () -> Void

    @State private var episodes: [NavidromePodcastEpisode]
    @State private var loading = false
    /// Hero artwork, decoded once from the channel's cover (falls back to the first episode's).
    @State private var heroImage: Image?
    /// Episode ids with a download request in flight — the row shows progress while we ask the
    /// server and then reconcile.
    @State private var downloading: Set<String> = []

    init(channel: NavidromePodcastChannel, onBack: @escaping () -> Void) {
        self.channel = channel
        self.onBack = onBack
        _episodes = State(initialValue: channel.episodes)
    }

    /// Only playable (stream-bearing) episodes, in list order — the queue we build from.
    private var playable: [NavidromePodcastEpisode] { episodes.filter(\.isPlayable) }

    private var queueSource: StreamingPlaybackController.QueueSource {
        .init(label: channel.title, kind: .playlist, id: channel.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MusicAlbumBanner(
                    name: channel.title,
                    kindLabel: "PODCAST",
                    detail: episodeCountLabel,
                    heroImage: heroImage,
                    accentColor: ArtistMonogram.color(channel.title),
                    placeholderIcon: "mic",
                    onBack: onBack
                )

                if let description = channel.description {
                    Text(description)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(4)
                        .padding(.horizontal, 16).padding(.top, 12)
                }

                if loading, episodes.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                } else if episodes.isEmpty {
                    Text("No episodes")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(24)
                } else {
                    episodeList
                }
            }
            .padding(.bottom, 16)
        }
        .navigationBarBackButtonHidden(true)
        .task(id: channel.id) { await refreshIfEmpty() }
        .task(id: channel.id) { await loadHero() }
    }

    /// Load the hero image once from the channel cover (falls back to the first episode's).
    private func loadHero() async {
        heroImage = nil
        let coverID = channel.coverArtID ?? episodes.first?.coverArtID
        guard let coverID, let url = model.musicLibrary.coverArtURL(id: coverID, size: 600),
              let image = await MusicAlbumDetail.fetchImage(url) else { return }
        withAnimation(.easeOut(duration: 0.25)) { heroImage = image }
    }

    private var episodeList: some View {
        LazyVStack(spacing: 2) {
            ForEach(episodes) { episode in
                PodcastEpisodeRow(
                    episode: episode,
                    // Guard on a real stream id: a not-downloaded episode has a nil `streamID`,
                    // and with nothing playing `nowPlaying?.id` is also nil — without this an
                    // idle player would flag every undownloaded episode as "now playing".
                    isCurrent: episode.streamID != nil && model.music.nowPlaying?.id == episode.streamID,
                    isDownloading: downloading.contains(episode.id),
                    onDownload: { download(episode) },
                    onPlay: { play(episode) }
                )
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var episodeCountLabel: String {
        let count = episodes.count
        return count == 1 ? "1 episode" : "\(count) episodes"
    }

    // MARK: - Playback

    /// Plays `episode` and queues the rest of the show after it. Builds the queue from the
    /// playable episodes (those with a stream id) mapped to `NavidromeSong`s.
    private func play(_ episode: NavidromePodcastEpisode) {
        guard episode.isPlayable else { return }
        let songs = playable.map { $0.asSong(channelTitle: channel.title, fallbackCoverID: channel.coverArtID) }
        let index = playable.firstIndex(of: episode) ?? 0
        model.music.play(songs, startAt: index, source: queueSource)
    }

    private func refreshIfEmpty() async {
        guard episodes.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        if let client = try? NavidromeConfig.makeClient(),
           let full = try? await client.getPodcastChannel(id: channel.id) {
            episodes = full.episodes
        }
    }

    /// Asks the server to download a not-yet-downloaded episode, then reconciles the list so the
    /// row flips to "downloading"/playable without a manual refresh. The server fetches the
    /// enclosure asynchronously, so a single reconcile may still show "downloading" — that's the
    /// expected in-progress state, not a failure.
    private func download(_ episode: NavidromePodcastEpisode) {
        guard !downloading.contains(episode.id) else { return }
        downloading.insert(episode.id)
        Task {
            defer { downloading.remove(episode.id) }
            guard let client = try? NavidromeConfig.makeClient() else { return }
            do {
                try await client.downloadPodcastEpisode(episodeID: episode.id)
                model.music.postToast("Downloading “\(episode.title)”", symbol: "arrow.down.circle.fill")
                // Let the server register the request, then reconcile the episode's new status.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let full = try? await client.getPodcastChannel(id: channel.id) {
                    episodes = full.episodes
                }
            } catch {
                model.music.postToast("Download failed", symbol: "exclamationmark.triangle.fill")
            }
        }
    }
}

/// A single episode row — title, publish date + duration, and a play button. Disabled (dimmed)
/// when the episode has no stream id yet (still downloading / skipped on the server).
private struct PodcastEpisodeRow: View {
    @Environment(MusicModel.self) private var model
    let episode: NavidromePodcastEpisode
    let isCurrent: Bool
    /// A local download request is in flight for this episode (we asked the server and are
    /// reconciling) — distinct from the server's own "downloading" status.
    let isDownloading: Bool
    let onDownload: () -> Void
    let onPlay: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "mic")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.body)
                    .foregroundStyle(episode.isPlayable ? .primary : .secondary)
                    .lineLimit(1)
                if let meta = metaLine {
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(hover ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if episode.isPlayable { onPlay() } }
    }

    /// Trailing control: play (playable, on hover/current), a download progress spinner
    /// (request in flight or the server is fetching), or a Download button for a
    /// not-yet-downloaded episode we can request.
    @ViewBuilder private var trailing: some View {
        if episode.isPlayable {
            if hover || isCurrent {
                Button(action: onPlay) { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
            }
        } else if isDownloading || episode.isDownloadingOnServer {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Button(action: onDownload) {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .help("Download this episode on the server so it can stream")
        }
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let date = episode.publishDate.flatMap(Self.formatDate) { parts.append(date) }
        if let seconds = episode.duration, seconds > 0 {
            parts.append(String(format: "%d min", max(1, seconds / 60)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Renders the server's ISO-8601 publish date as a short local date; falls back to the
    /// leading `YYYY-MM-DD` if it doesn't parse.
    private static func formatDate(_ raw: String) -> String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        if let date {
            let out = DateFormatter()
            out.dateStyle = .medium
            return out.string(from: date)
        }
        return raw.count >= 10 ? String(raw.prefix(10)) : raw
    }
}

// MARK: - Episode → Song

extension NavidromePodcastEpisode {
    /// Maps a playable episode to the `NavidromeSong` the player streams. The song `id` is the
    /// episode's `streamID` (the media id `stream`/`getSong` use), so playback works with no
    /// changes to the controller. Non-playable episodes have no stream id and must be filtered
    /// out before calling this.
    func asSong(channelTitle: String, fallbackCoverID: String?) -> NavidromeSong {
        NavidromeSong(
            id: streamID ?? id,
            title: title,
            artist: channelTitle,
            album: channelTitle,
            albumID: nil,
            duration: duration,
            coverArtID: coverArtID ?? fallbackCoverID
        )
    }
}
