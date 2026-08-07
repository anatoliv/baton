import SwiftUI

/// Podcasts on the phone — client-side RSS subscriptions via the shared store (the
/// same path the Mac defaults to, since Navidrome has never implemented the Subsonic
/// podcast endpoints). Episodes resume from the shared progress store and play at
/// the user's chosen speed.
struct PodcastsListBody: View {
    let model: MobileModel
    // Grid by default: a show is its cover art. You recognise "Latent Space" by the
    // picture long before you finish reading the words.
    @AppStorage(BrowseLayout.key("podcast")) private var layoutRaw = BrowseLayout.grid.rawValue
    private var layout: BrowseLayout { BrowseLayout(rawValue: layoutRaw) ?? .grid }
    private var layoutBinding: Binding<BrowseLayout> {
        Binding(get: { layout }, set: { layoutRaw = $0.rawValue })
    }
    @State private var showsAddFeed = false
    @State private var feedURLText = ""
    @State private var addError: String?

    var body: some View {
        Group {
            if layout == .grid { channelGrid } else { channelList }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LayoutPicker(layout: layoutBinding) } }
    }

    private var channelGrid: some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: BrowseGrid.spacing) {
                ForEach(model.podcastSubscriptions.channels) { channel in
                    NavigationLink {
                        PodcastChannelView(channel: channel, model: model)
                    } label: {
                        BrowseTile(artwork: channel.imageURL,
                                   title: channel.title,
                                   subtitle: "\(channel.episodes.count) episodes")
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Unsubscribe", role: .destructive) {
                            model.podcastSubscriptions.unsubscribe(channel)
                        }
                    }
                }
            }
            .padding(BrowseGrid.padding)
        }
    }

    private var channelList: some View {
            List {
                ForEach(model.podcastSubscriptions.channels) { channel in
                    NavigationLink {
                        PodcastChannelView(channel: channel, model: model)
                    } label: {
                        HStack {
                            ArtworkView(url: channel.imageURL)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(channel.title).lineLimit(1)
                                Text("\(channel.episodes.count) episodes")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Unsubscribe", role: .destructive) {
                            model.podcastSubscriptions.unsubscribe(channel)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsAddFeed = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await model.podcastSubscriptions.refresh() }
            .task {
                await model.podcastSubscriptions.loadIfNeeded()
                // Subscriptions made on the Mac arrive as a list of feed URLs; this is
                // where they become real subscriptions. Additive — see `adoptSyncedFeeds`.
                _ = await model.podcastSubscriptions.adoptSyncedFeeds()
            }
            .overlay {
                if model.podcastSubscriptions.channels.isEmpty {
                    ContentUnavailableView(
                        "No podcasts yet",
                        systemImage: "mic",
                        description: Text("Add an RSS feed to subscribe.")
                    )
                }
            }
            .alert("Add podcast feed", isPresented: $showsAddFeed) {
                TextField("https://example.com/feed.xml", text: $feedURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Subscribe") { subscribe() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let addError { Text(addError) }
            }
    }

    private func subscribe() {
        guard let url = URL(string: feedURLText.trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true else {
            addError = "That doesn't look like a feed URL."
            showsAddFeed = true
            return
        }
        feedURLText = ""
        Task {
            do {
                _ = try await model.podcastSubscriptions.subscribe(to: url)
                addError = nil
            } catch {
                addError = error.localizedDescription
                showsAddFeed = true
            }
        }
    }
}

/// One show: episodes newest-first, resume indicators, tap to play at podcast speed.
struct PodcastChannelView: View {
    let channel: PodcastChannel
    let model: MobileModel

    var body: some View {
        List {
            Section {
                speedPicker
            }
            Section {
                ForEach(channel.episodes) { episode in
                    Button {
                        play(episode)
                    } label: {
                        episodeRow(episode)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(channel.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var speedPicker: some View {
        Picker("Playback speed", selection: Binding(
            get: { model.music.playbackRate },
            set: { model.music.playbackRate = $0 }
        )) {
            ForEach([Float(0.75), 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                Text(rate == 1.0 ? "1×" : String(format: "%g×", rate)).tag(rate)
            }
        }
        .pickerStyle(.segmented)
    }

    private func episodeRow(_ episode: PodcastEpisode) -> some View {
        let id = episode.enclosureURL.absoluteString
        let played = model.podcastProgress.isPlayed(id: id)
        let fraction = model.podcastProgress.fraction(id: id)
        return VStack(alignment: .leading, spacing: 4) {
            Text(episode.title)
                .lineLimit(2)
                .foregroundStyle(played ? .secondary : .primary)
            HStack(spacing: 8) {
                if let date = episode.publishDate {
                    Text(date, style: .date)
                }
                if let duration = episode.duration {
                    Text("\(duration / 60) min")
                }
                if played {
                    Label("Played", systemImage: "checkmark").labelStyle(.titleAndIcon)
                } else if let fraction, fraction > 0.02 {
                    ProgressView(value: fraction).frame(width: 60)
                }
                if id == model.music.nowPlaying?.id {
                    NowPlayingBars(isPlaying: model.music.state == .playing)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func play(_ episode: PodcastEpisode) {
        let song = episode.asSong(channelTitle: channel.title, artwork: episode.imageURL ?? channel.imageURL)
        model.music.play([song], source: .init(label: channel.title, kind: .playlist, id: channel.id))
    }
}
