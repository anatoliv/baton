import SwiftUI
import BatonPlaybackKit

/// The Albums browse tab — a two-column grid over `MusicLibraryStore.albums`, the
/// iPhone rendering of the Mac app's grid branch. Artwork rides `AsyncImage` +
/// `URLCache`, which works because the client's per-instance salt keeps cover-art
/// URLs byte-identical.
struct AlbumsGridView: View {
    let model: MobileModel
    @Environment(\.nowPlayingPalette) private var wash

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]
    /// Grid shows covers; list shows more of a 2,604-album library per screen. Persisted,
    /// because a view style is a preference, not a mood.
    // Was `baton.albums.style`, the one layout toggle the phone had, named unlike the
    // Mac's and unlike the five that just joined it. Moved onto the shared key so all six
    // read the same way. The cost is that an existing choice resets to grid once — which
    // is the default it almost certainly already was.
    @AppStorage(BrowseScreen.album.layoutKey) private var styleRaw = BrowseLayout.grid.rawValue
    private var isGrid: Bool { styleRaw == "grid" }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if isGrid {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(model.musicLibrary.albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCell(album: album, model: model)
                                }
                                .buttonStyle(.plain)
                                .id(album.id)
                            }
                        }
                        .padding(.horizontal)
                        // Room for the rail, so the last column's titles don't slide under it.
                        .padding(.trailing, indexEntries.isEmpty ? 0 : 18)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(model.musicLibrary.albums) { album in
                                NavigationLink(value: album) {
                                    AlbumListRow(album: album, model: model)
                                }
                                .buttonStyle(.plain)
                                .id(album.id)
                                Divider().padding(.leading, 74)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.trailing, indexEntries.isEmpty ? 0 : 18)
                    }
                }
                // The A–Z rail, for alphabetical sorts on a big library. 2,604 albums
                // without one is a flick marathon.
                .overlay(alignment: .trailing) {
                    if !indexEntries.isEmpty {
                        AlphabetIndexRail(entries: indexEntries) { entry in
                            proxy.scrollTo(entry.firstID, anchor: .top)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .nowPlayingWash(wash)
            .rootScreenHeader("Albums", subtitle: countLine) { sortMenu }
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album, model: model)
            }
            .refreshable { await model.musicLibrary.loadAlbums() }
            // Was a spinner and nothing else: a server returning 500 left an empty grid
            // that read as "you have no music".
            .contentState(
                ContentDisplayState.resolve(isLoading: model.musicLibrary.isLoading,
                                            error: model.musicLibrary.lastError,
                                            isEmpty: model.musicLibrary.albums.isEmpty),
                emptyTitle: "No albums",
                emptyMessage: "Nothing in your library yet.",
                emptySymbol: "square.stack",
                onRetry: { Task { await model.musicLibrary.loadAlbums() } }
            )
        }
    }

    /// What the shelf actually holds. Empty while the first load is in flight rather
    /// than "0 albums", which reads as an empty library instead of a pending one.
    private var countLine: String? {
        let albums = model.musicLibrary.albums.count
        let artists = model.musicLibrary.artists.count
        return Counted.line([
            albums > 0 ? Counted.phrase(albums, "album") : nil,
            artists > 0 ? Counted.phrase(artists, "artist") : nil,
        ])
    }

    /// Rail entries for the current sort — empty (rail hidden) unless the order is
    /// alphabetical, because jumping to "S" in a most-played ordering means nothing.
    /// Thirty-plus items is where flicking starts to lose to jumping.
    private var indexEntries: [AlphabetIndex.Entry] {
        let albums = model.musicLibrary.albums
        guard albums.count > 30 else { return [] }
        switch model.musicLibrary.albumSort {
        case .name:
            return AlphabetIndex.entries(from: albums.map { ($0.id, $0.name) })
        case .artist:
            return AlphabetIndex.entries(from: albums.map { ($0.id, $0.artist ?? "") })
        default:
            return []
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Style", selection: $styleRaw) {
                Label("Grid", systemImage: "square.grid.2x2").tag("grid")
                Label("List", systemImage: "list.bullet").tag("list")
            }
            Divider()
            ForEach(AlbumSort.allCases) { sort in
                Button {
                    model.musicLibrary.albumSort = sort
                    Task { await model.musicLibrary.loadAlbums() }
                } label: {
                    if model.musicLibrary.albumSort == sort {
                        Label(sort.label, systemImage: "checkmark")
                    } else {
                        Text(sort.label)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

/// One album as a dense row — the list style for people who scan by name, not cover.
private struct AlbumListRow: View {
    let album: NavidromeAlbum
    let model: MobileModel

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 120))
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).lineLimit(1)
                Text(Counted.line([album.artist,
                                   album.year.map(String.init),
                                   PlayTime.total(album.duration)]) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct AlbumCell: View {
    let album: NavidromeAlbum
    let model: MobileModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 400), wholeCover: true)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // Decorative: the title and artist below say everything the cover does,
                // and VoiceOver announcing "image" before each one is pure noise.
                .accessibilityHidden(true)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            Text(album.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(album.artist ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Every cell the same width as its column, so two columns line up and a long
        // title truncates instead of widening its cell.
        .frame(maxWidth: .infinity, alignment: .leading)
        // One stop per album, not three. Uncombined, VoiceOver reads cover, then title,
        // then artist — so reaching the end of a 2,600-album grid is 7,800 swipes instead
        // of 2,600, and the album is never announced as one thing.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(album.artist.map { "\(album.name), by \($0)" } ?? album.name)
    }
}

/// Shared artwork loader with the placeholder every cell uses.
struct ArtworkView: View {
    let url: URL?
    /// Draw the cover *whole* over a blurred enlargement of itself, instead of cropping it
    /// to the cell. Off for small row thumbnails, where the blur is invisible.
    var wholeCover = false
    /// Decode target in points. A row thumbnail wants a fraction of a hero's pixels, and
    /// decoding both at hero size is most of what a naive image cache wastes.
    var side: CGFloat = 200

    var body: some View {
        // `Color.clear` first, image in an overlay.
        //
        // The old version put `AsyncImage` at the root, so once a cover loaded the *image*
        // reported the layout size — and covers are not all square. A 16:9 thumbnail in a
        // grid cell made that cell wider than its column: rows went ragged, titles ran off
        // the edge, and the whole grid looked broken the moment it met a real library
        // instead of four bundled tracks. `Color.clear` has no opinion about its size, so
        // the container decides.
        //
        // `wholeCover` then decides what fills that box. Cropping is fine for square art,
        // but a 16:9 thumbnail loses its outer thirds — and a library ripped from YouTube
        // is almost entirely 16:9. So the cover is drawn `scaledToFit` (nothing cropped)
        // over a blurred enlargement of *the same decoded image*, which is what the
        // letterboxing is for and how the Mac's cards have always drawn.
        //
        // **One request, drawn twice.** The first attempt fetched a second, smaller copy
        // for the blur, reasoning that a blur can't show detail so the bytes would be
        // cheap. The bytes were — the *connections* were not. URLSession allows around six
        // per host, so two requests per cell put the fill layer in direct competition with
        // the covers for that pool, and across a grid the visible artwork simply never
        // arrived: forty seconds in, every cell was still a placeholder. Reusing the
        // decoded image costs one extra draw and no network at all.
        // `CachedArtwork` rather than `AsyncImage`: the latter caches *bytes* in a
        // `URLCache` that defaults to 512KB in memory — roughly four covers — and decodes
        // again on every appearance. Against 2,600 albums that means scrolling back up a
        // grid re-downloads and re-decodes artwork it showed seconds ago. This decodes to
        // the drawn size, once, and keeps it.
        Color.clear
            .overlay {
                CachedArtwork(url: url, side: side) { image in
                    if wholeCover {
                        ZStack {
                            image.resizable()
                                .scaledToFill()
                                .blur(radius: 18)
                                .overlay(Color.black.opacity(0.15))
                            image.resizable().scaledToFit()
                        }
                    } else {
                        image.resizable().scaledToFill()
                    }
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipped()
    }
}

/// Album detail: artwork header + tap-to-play track list, playing through the shared
/// gapless engine exactly as on the Mac.
struct AlbumDetailView: View {
    let album: NavidromeAlbum
    let model: MobileModel
    @State private var songs: [NavidromeSong] = []
    /// Opening the artist through `navigationDestination(item:)` rather than a
    /// `NavigationLink`: a link inside a List row makes the *row* disclosable, which
    /// stranded a chevron at the far right of the header, a hand's width from the name
    /// it belonged to.
    @State private var openArtist: NavidromeArtist?

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 600), wholeCover: true)
                            .frame(width: 230, height: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                        Text(album.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        // The artist is a destination, not a caption. Every other surface
                        // in the app lets you go from a record to who made it.
                        if let artist = album.artist, !artist.isEmpty {
                            if let id = album.artistID, !model.isDemoMode {
                                Button {
                                    openArtist = NavidromeArtist(id: id, name: artist)
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(artist).font(.subheadline)
                                        Image(systemName: "chevron.right")
                                            .font(.caption2.weight(.semibold))
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                            } else {
                                Text(artist).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        // Tracks, running time, year, genre — all of it already on the
                        // album and none of it shown. The Mac has always printed this line;
                        // without it a listing is a bare list of titles with no sense of
                        // how long the record is or when it came from.
                        if let summary = albumSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        HStack(spacing: 10) {
                            Button {
                                play(from: 0)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(songs.isEmpty)

                            Button {
                                model.music.playShuffleToggling(songs, source: .init(label: album.name, kind: .album, id: album.id))
                            } label: {
                                Label("Shuffle", systemImage: model.music.isShuffled ? "shuffle.circle.fill" : "shuffle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(model.music.isShuffled ? Color.accentColor : Color.secondary)
                            .accessibilityLabel(model.music.isShuffled ? "Shuffle on" : "Shuffle")
                            .disabled(songs.isEmpty)
                        }
                    }
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    HStack {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading) {
                            Text(song.title).lineLimit(1)
                            if let artist = song.artist, artist != album.artist {
                                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        if model.musicLibrary.isLiked(song) {
                            Image(systemName: "heart.fill").font(.caption).foregroundStyle(.tint)
                        }
                        if song.id == model.music.nowPlaying?.id {
                            NowPlayingBars(isPlaying: model.music.state == .playing)
                        }
                        // Every music app puts a duration column in a track listing, and
                        // this is the screen where "how long is this record" is asked.
                        if let time = PlayTime.track(song.duration) {
                            Text(time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 38, alignment: .trailing)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { play(from: index) }
                    .listRowBackground(Color.clear)
                    .songContextMenu(song, model: model)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background {
            // Full-bleed blurred cover behind the whole page (Tidal / Apple Music).
            // The material overlay keeps every row legible over any artwork.
            ArtworkView(url: model.musicLibrary.coverArtURL(id: album.coverArtID ?? album.id, size: 400), wholeCover: true)
                .scaledToFill()
                .blur(radius: 60)
                .opacity(0.55)
                .overlay(.ultraThinMaterial)
                .ignoresSafeArea()
        }
        // No title in the bar: the header already sets the album name in full, and it
        // wraps. The bar could only ever show a truncated copy of the line directly
        // beneath it — "netBloc Vol. 42: Live, The Univ…" above "netBloc Vol. 42: Live,
        // The Universe & Everything".
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openArtist) { artist in
            ArtistDetailView(artist: artist, model: model)
        }
        // Download and Like moved here from the hero. They were full-width buttons under
        // Play — a secondary action drawn larger than the primary one — and they pushed
        // the track listing below the fold on a phone.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { _ = await MusicDownloadStore.shared.download(songs) }
                    } label: { Label(downloadLabel, systemImage: downloadSymbol) }
                        .disabled(songs.isEmpty || isFullyDownloaded)

                    if !model.isDemoMode {
                        let liked = model.musicLibrary.isLiked(id: album.id, isLiked: album.isLiked)
                        Button {
                            Task {
                                await model.musicLibrary.toggleLike(
                                    id: album.id, currentLiked: album.isLiked, userRating: album.userRating
                                )
                            }
                        } label: {
                            Label(liked ? "Liked" : "Like", systemImage: liked ? "heart.fill" : "heart")
                        }
                    }

                    Divider()

                    Button {
                        model.music.playNext(songs)
                    } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        .disabled(songs.isEmpty)
                    Button {
                        model.music.enqueue(songs)
                    } label: { Label("Add to Queue", systemImage: "text.append") }
                        .disabled(songs.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
        .task { songs = await model.musicLibrary.albumSongs(id: album.id) }
    }

    /// "4 tracks · 4 min · 2026 · Electronic" — whichever of those the server knows.
    ///
    /// Prefers the *loaded* track count and running time over the album's own fields:
    /// those come from the browse listing and are occasionally stale or absent, and by the
    /// time this line is drawn the real songs are usually in hand.
    private var albumSummary: String? {
        let count = songs.isEmpty ? album.songCount : songs.count
        let seconds = songs.isEmpty ? album.duration : songs.reduce(0) { $0 + ($1.duration ?? 0) }
        return Counted.line([
            count.map { Counted.phrase($0, "track") },
            PlayTime.total(seconds),
            album.year.map(String.init),
            album.genre,
        ])
    }

    private func play(from index: Int) {
        model.music.play(songs, startAt: index, source: .init(label: album.name, kind: .album, id: album.id))
    }

    private var isFullyDownloaded: Bool {
        !songs.isEmpty && songs.allSatisfy { MusicDownloadStore.shared.isDownloaded($0.id) }
    }

    private var downloadLabel: String {
        if isFullyDownloaded { return "Downloaded" }
        let inFlight = songs.filter { MusicDownloadStore.shared.inFlight.contains($0.id) }.count
        return inFlight > 0 ? "Downloading…" : "Download"
    }

    private var downloadSymbol: String {
        isFullyDownloaded ? "checkmark.circle" : "arrow.down.circle"
    }
}
