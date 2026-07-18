import SwiftUI

/// The **Podcasts** tab — browses the subscribed podcast channels on the Navidrome server
/// and plays their episodes through the existing music player. Read-only over the library
/// (channels/episodes are fetched directly from a `NavidromeClient`, since podcasts live
/// outside `MusicLibraryStore`); playback routes through `model.music.play`, exactly like the
/// album/playlist detail views. Episodes stream just like songs — an episode maps to a
/// `NavidromeSong` by its `streamID`, which is the same media id `stream`/`getSong` use.
struct MusicPodcastsView: View {
    @Environment(MusicModel.self) private var model

    @State private var channels: [NavidromePodcastChannel] = []
    @State private var selected: NavidromePodcastChannel?
    @State private var loading = false
    @State private var loaded = false
    @State private var loadError: String?

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

    private var channelBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Podcasts").font(.title3.weight(.semibold))
                Spacer()
            }
            .frame(height: 28)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            Divider()
            content
        }
    }

    @ViewBuilder private var content: some View {
        if loading, channels.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, channels.isEmpty {
            errorState(loadError)
        } else if channels.isEmpty, loaded {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(channels) { channel in
                        PodcastChannelCell(channel: channel) { selected = channel }
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.slash").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No podcasts").font(.headline)
            Text("Subscribe to podcasts in your Navidrome server and they'll show up here.")
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
            // Fetch channels with episodes inline — one round-trip gives the browser its
            // "newest episode" subtitle and lets the detail view open without a second call.
            channels = try await client.getPodcasts(includeEpisodes: true)
        } catch {
            loadError = (error as? NavidromeError)?.errorDescription ?? error.localizedDescription
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
                    heroImage: nil,
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
    }

    private var episodeList: some View {
        LazyVStack(spacing: 2) {
            ForEach(episodes) { episode in
                PodcastEpisodeRow(
                    episode: episode,
                    isCurrent: model.music.nowPlaying?.id == episode.streamID
                ) { play(episode) }
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
}

/// A single episode row — title, publish date + duration, and a play button. Disabled (dimmed)
/// when the episode has no stream id yet (still downloading / skipped on the server).
private struct PodcastEpisodeRow: View {
    @Environment(MusicModel.self) private var model
    let episode: NavidromePodcastEpisode
    let isCurrent: Bool
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
            if !episode.isPlayable {
                Text(episode.status?.capitalized ?? "Unavailable")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if hover || isCurrent {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(hover ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if episode.isPlayable { onPlay() } }
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
