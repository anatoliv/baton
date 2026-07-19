import SwiftUI
import UniformTypeIdentifiers

/// A play-from-index list of tracks, each a `MusicTrackRow`. Shared by search,
/// starred, album, and playlist views.
struct MusicSongList: View {
    @Environment(MusicModel.self) private var model
    let songs: [NavidromeSong]
    /// Where these songs came from, so the player can show "Playing from …".
    var source: StreamingPlaybackController.QueueSource?

    var body: some View {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            MusicTrackRow(song: song, isCurrent: model.music.nowPlaying?.id == song.id) {
                model.music.play(songs, startAt: index, source: source)
            }
            .padding(.vertical, 1)
        }
    }
}

/// Album detail — an adaptive hero banner (cover backdrop + name + meta) over the ordered
/// track list, matching the artist page's style. Transport / Queue / Download / Radio and a
/// filter + list/grid toggle live in the shared browse header.
struct MusicAlbumDetail: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let album: NavidromeAlbum
    @State private var songs: [NavidromeSong] = []
    @State private var loading = true
    /// Hero artwork, loaded once into a decoded image (same technique as the artist page —
    /// a computed `coverArtURL` mints a fresh salt per call, so handing one to `AsyncImage`
    /// flashes it away on every re-render).
    @State private var heroImage: Image?
    @State private var filter = ""
    @State private var layout: MusicBrowseLayout = .list

    private var albumSource: StreamingPlaybackController.QueueSource {
        .init(label: album.name, kind: .album, id: album.id)
    }

    private var totalSeconds: Int {
        if let duration = album.duration, duration > 0 { return duration }
        return songs.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// "N tracks · 47 min · 2015" — the meta after the (separately-linked) artist.
    private var detailText: String {
        var parts: [String] = []
        let count = songs.isEmpty ? (album.songCount ?? 0) : songs.count
        if count > 0 { parts.append("\(count) track\(count == 1 ? "" : "s")") }
        if totalSeconds > 0 { parts.append(MusicAlbumCard.albumDuration(totalSeconds)) }
        if let year = album.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    /// A nav target for the album's artist, when the server gave us an artist id.
    private var artistDestination: NavidromeArtist? {
        guard let id = album.artistID, let name = album.artist, !name.isEmpty else { return nil }
        return NavidromeArtist(id: id, name: name)
    }

    private var visibleSongs: [NavidromeSong] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return songs }
        return songs.filter { $0.title.lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MusicAlbumBanner(
                    name: album.name,
                    artist: album.artist,
                    artistDestination: artistDestination,
                    detail: detailText,
                    heroImage: heroImage,
                    accentColor: ArtistMonogram.color(album.artist ?? album.name),
                    downloadStatus: DownloadStatusBadge.status(albumID: album.id, totalTracks: album.songCount),
                    onBack: { dismiss() }
                )

                MusicBrowseHeader(
                    title: "Songs",
                    count: visibleSongs.count,
                    filter: $filter,
                    filterPrompt: "Filter songs",
                    filterHistoryKey: "albumSongs",
                    layout: $layout,
                    accessory: { EmptyView() },
                    leading: {
                        MusicMiniTransport(onPlayWhenIdle: { model.music.play(songs, source: albumSource) }, pageSource: albumSource)
                        // Bare icons, matching the transport + the track-row hover strip.
                        MusicRowActions(actions: [
                            MusicRowAction(title: "Add to Queue", systemImage: "text.append") { model.music.enqueue(songs) },
                            MusicRowAction(title: "Download", systemImage: "arrow.down.circle") { Task { await MusicDownloadStore.shared.download(songs) } },
                            MusicRowAction(title: "Start Radio", systemImage: "dot.radiowaves.left.and.right") { startRadio() },
                        ])
                    },
                    sortMenu: { EmptyView() } // albums keep their track order
                )

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                } else {
                    songsContent
                }
            }
            .padding(.bottom, 16)
        }
        .navigationBarBackButtonHidden(true)
        .task(id: album.id) {
            heroImage = nil
            loading = true
            songs = await model.musicLibrary.albumSongs(id: album.id)
            loading = false
            await loadHeroImage()
        }
    }

    @ViewBuilder private var songsContent: some View {
        if visibleSongs.isEmpty {
            Text(songs.isEmpty ? "No tracks" : "No songs match “\(filter)”")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(24)
        } else if layout == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                    LikedSongGridCell(song: song, isSelected: false, showSelect: false) {
                        model.music.play(visibleSongs, startAt: index, source: albumSource)
                    }
                }
            }
            .padding(16)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                    // Trust the server's track number only when it's a plausible one;
                    // auto-imports carry garbage values (e.g. 3639), so fall back to the
                    // row position.
                    let trackNo = song.track.flatMap { (1 ... 200).contains($0) ? $0 : nil } ?? (index + 1)
                    MusicLikedSongRow(song: song, showSelect: false, trackNumber: trackNo) {
                        model.music.play(visibleSongs, startAt: index, source: albumSource)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    /// Load the hero image once from the album cover (falls back to the first track's cover).
    private func loadHeroImage() async {
        let coverID = album.coverArtID ?? songs.first?.coverArtID
        guard let coverID, let url = model.musicLibrary.coverArtURL(id: coverID, size: 600),
              let image = await Self.fetchImage(url) else { return }
        withAnimation(.easeOut(duration: 0.25)) { heroImage = image }
    }

    /// Download + decode an image off the main actor. Also reused by the playlist detail.
    static func fetchImage(_ url: URL) async -> Image? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
    }

    private func startRadio() {
        Task {
            guard let seed = songs.first else { return }
            let radio = await model.musicLibrary.similarSongs(seedID: seed.id)
            if !radio.isEmpty {
                model.music.play(radio, source: .init(label: "\(album.name) Radio", kind: .radio, id: nil))
            } else {
                model.music.play(songs, source: albumSource)
            }
        }
    }
}

/// The album banner — mirrors `MusicArtistBanner`'s style (blurred cover backdrop, darkening
/// gradient, name + meta overlay, custom back button) but with a square album cover instead
/// of a circular artist portrait.
struct MusicAlbumBanner: View {
    let name: String
    var kindLabel: String = "ALBUM"
    var artist: String?
    /// When set, the artist name in the meta line becomes a link to this artist's page.
    var artistDestination: NavidromeArtist?
    /// The rest of the meta line after the artist — e.g. "1 track · 7 min · 2018".
    var detail: String = ""
    var heroImage: Image?
    var accentColor: Color
    /// SF Symbol shown in the cover slot when there's no artwork.
    var placeholderIcon: String = "opticaldisc"
    /// Offline-download state, shown as a glyph in the meta line.
    var downloadStatus: DownloadStatusBadge.Status = .hidden
    var onBack: () -> Void = {}

    private var metaFont: Font { .caption.weight(.semibold) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                metaLine
                Text(name)
                    .font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                    .lineLimit(2).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        // Tall enough for the cover + title with clear room for the back chevron above.
        .frame(height: 162, alignment: .bottomLeading)
        .background { backdrop }
        .clipped()
        .overlay(alignment: .topLeading) { backButton }
    }

    /// "ALBUM · [Artist] · 1 track · 7 min · 2018" — the artist a tappable link when a
    /// destination is known.
    @ViewBuilder private var metaLine: some View {
        HStack(spacing: 5) {
            Text(kindLabel).font(metaFont).foregroundStyle(.white.opacity(0.85))
            if let artist, !artist.isEmpty {
                dot
                if let artistDestination {
                    NavigationLink(value: artistDestination) {
                        Text(artist).font(metaFont).foregroundStyle(.white).underline()
                    }
                    .buttonStyle(.plain)
                    .help("Go to \(artist)")
                } else {
                    Text(artist).font(metaFont).foregroundStyle(.white.opacity(0.85))
                }
            }
            if !detail.isEmpty {
                dot
                Text(detail).font(metaFont).foregroundStyle(.white.opacity(0.85))
            }
            if let symbol = downloadGlyph {
                dot
                Image(systemName: symbol).font(metaFont).foregroundStyle(.white)
                    .help(downloadStatus == .complete ? "Downloaded" : "Partly downloaded")
            }
        }
    }

    /// The download glyph for the meta line — filled when complete, outline when partial.
    private var downloadGlyph: String? {
        switch downloadStatus {
        case .complete: "arrow.down.circle.fill"
        case .partial: "arrow.down.circle"
        case .hidden, .downloading: nil
        }
    }

    private var dot: some View { Text("·").font(metaFont).foregroundStyle(.white.opacity(0.6)) }

    private var gradient: LinearGradient {
        LinearGradient(colors: [accentColor, accentColor.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var backdrop: some View {
        ZStack {
            gradient
            if let heroImage {
                heroImage.resizable().scaledToFill()
                    .blur(radius: 26).opacity(0.9).transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder private var cover: some View {
        Group {
            if let heroImage {
                heroImage.resizable().scaledToFill()
            } else {
                ZStack {
                    gradient
                    Image(systemName: placeholderIcon).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: 92, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        // Center-align the back chevron with the sidebar's collapse chevron: the rail
        // chevron sits at 8 (rail top inset) + 14 (½ of its 28pt height) = 22pt; this
        // 30pt circle needs a 7pt top inset (7 + 15) to share that center line.
        .padding(.top, 7).padding(.leading, 12)
        .help("Back")
    }
}

/// Artist detail — an adaptive hero banner (name + Play/Radio) over the artist's
/// albums grid.
struct MusicArtistDetail: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let artist: NavidromeArtist

    @State private var albums: [NavidromeAlbum] = []
    @State private var songs: [NavidromeSong] = []
    @State private var info: NavidromeArtistInfo?
    @State private var following = false
    /// Hero artwork, loaded once into a decoded image. We deliberately do NOT hand a
    /// URL to `AsyncImage`: `coverArtURL` mints a fresh random Subsonic salt per call
    /// (so a computed URL differs each render), and AsyncImage re-fetches — flashing to
    /// its empty placeholder — whenever the banner view is recreated. Fetching the
    /// bytes once here and holding the `Image` makes the hero pop in and stay put.
    @State private var heroImage: Image?

    @State private var filter = ""
    @State private var sort: MusicCollectionView.SongSort = .title
    @State private var sortAscending = true
    @State private var layout: MusicBrowseLayout = .list

    private var isAutoImport: Bool { ArtistHeuristics.isAutoImport(artist.name) }

    private var metaText: String {
        var parts = ["ARTIST", "\(albums.count) album\(albums.count == 1 ? "" : "s")"]
        if !songs.isEmpty { parts.append("\(songs.count) track\(songs.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Load the hero image once. Prefer a local album/track cover — it always loads from
    /// our own server — over the remote artist photo, which for auto-imported "artists"
    /// is usually the broken last.fm blank-star placeholder (a non-nil URL that never
    /// loads). The server photo is only a fallback when there's no cover at all.
    private func loadHeroImage() async {
        let coverID = albums.first?.coverArtID ?? songs.first?.coverArtID
        if let coverID, let url = model.musicLibrary.coverArtURL(id: coverID, size: 600),
           let image = await Self.fetchImage(url) {
            withAnimation(.easeOut(duration: 0.25)) { heroImage = image }
            return
        }
        if let photo = info?.imageURL, let image = await Self.fetchImage(photo) {
            withAnimation(.easeOut(duration: 0.25)) { heroImage = image }
        }
    }

    /// Download + decode an image off the main actor. Returns nil on any failure or
    /// task cancellation (e.g. the user navigated away), leaving the monogram in place.
    private static func fetchImage(_ url: URL) async -> Image? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
    }

    private var source: StreamingPlaybackController.QueueSource {
        .init(label: artist.name, kind: .artist, id: artist.id)
    }

    /// The bare-icon header actions: Queue · Download · Radio, plus Follow (a heart that
    /// fills + tints when following) for real artists.
    private var artistActions: [MusicRowAction] {
        var actions: [MusicRowAction] = [
            MusicRowAction(title: "Add to Queue", systemImage: "text.append") { model.music.enqueue(songs) },
            MusicRowAction(title: "Download", systemImage: "arrow.down.circle") { Task { await MusicDownloadStore.shared.download(songs) } },
            MusicRowAction(title: "Start Radio", systemImage: "dot.radiowaves.left.and.right") { startRadio() },
        ]
        if !isAutoImport {
            actions.append(MusicRowAction(
                title: following ? "Following" : "Follow",
                systemImage: following ? "heart.fill" : "heart",
                tint: following ? .accentColor : .secondary
            ) { toggleFollow() })
        }
        return actions
    }

    private var visibleSongs: [NavidromeSong] {
        var list = songs
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query)
            }
        }
        switch sort {
        case .rating: list.sort { model.musicLibrary.rating($0) < model.musicLibrary.rating($1) }
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: list.sort { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .duration: list.sort { ($0.duration ?? 0) < ($1.duration ?? 0) }
        }
        if !sortAscending { list.reverse() }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MusicArtistBanner(
                    name: artist.name,
                    meta: metaText,
                    heroImage: heroImage,
                    monogramInitial: ArtistMonogram.initial(artist.name),
                    monogramColor: ArtistMonogram.color(artist.name),
                    isAutoImport: isAutoImport,
                    downloadStatus: DownloadStatusBadge.status(artistID: artist.id),
                    onBack: { dismiss() }
                )

                if let bio = info?.biography, !bio.isEmpty {
                    Text(bio)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        .padding(.horizontal, 16).padding(.top, 12)
                }

                if !songs.isEmpty {
                    // Same header/controls as every browse page: transport + Radio + Follow
                    // on the left, filter top-right, sort + list/grid toggle on the right.
                    MusicBrowseHeader(
                        title: "Songs",
                        count: visibleSongs.count,
                        filter: $filter,
                        filterPrompt: "Filter songs",
                        filterHistoryKey: "artistSongs",
                        layout: $layout,
                        accessory: { EmptyView() },
                        leading: {
                            MusicMiniTransport(onPlayWhenIdle: { playArtist() }, pageSource: source)
                            // Bare icons, matching the transport + the track-row hover strip.
                            // Follow folds in as a heart (filled + accent-tinted when following).
                            MusicRowActions(actions: artistActions)
                        },
                        sortMenu: { MusicSortControls(ascending: $sortAscending, selection: $sort) }
                    )
                    songsContent
                }

                if albums.count > 1 { albumsSection }
            }
            .padding(.bottom, 16)
        }
        .navigationBarBackButtonHidden(true)
        .task(id: artist.id) {
            heroImage = nil
            albums = await model.musicLibrary.artistAlbums(id: artist.id)
            songs = await model.musicLibrary.artistSongs(id: artist.id)
            // Fill the hero from the local cover as soon as it's known.
            await loadHeroImage()
            if model.musicLibrary.starred.artists.isEmpty { await model.musicLibrary.loadStarred() }
            following = model.musicLibrary.isArtistFollowed(id: artist.id)
            info = await model.musicLibrary.artistInfo(id: artist.id)
            // Fall back to the server artist photo only if there was no cover at all.
            if heroImage == nil { await loadHeroImage() }
        }
    }

    @ViewBuilder private var songsContent: some View {
        if visibleSongs.isEmpty {
            Text("No songs match “\(filter)”")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(24)
        } else if layout == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                    LikedSongGridCell(song: song, isSelected: false, showSelect: false) {
                        model.music.play(visibleSongs, startAt: index, source: source)
                    }
                }
            }
            .padding(16)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                    MusicLikedSongRow(song: song, showSelect: false) {
                        model.music.play(visibleSongs, startAt: index, source: source)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Albums")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16).padding(.top, 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(albums) { AlbumGridCell(album: $0) }
            }
            .padding(16)
        }
    }

    private func toggleFollow() {
        following.toggle()
        let newValue = following
        Task { await model.musicLibrary.setArtistFollowed(id: artist.id, followed: newValue) }
    }

    private func playArtist() {
        // Play the list as shown — first visible track first, honoring the current
        // sort/filter — not raw fetch order.
        let list = visibleSongs
        guard !list.isEmpty else { return }
        model.music.play(list, source: source)
    }

    private func startRadio() {
        Task {
            var radio = await model.musicLibrary.similarSongs(seedID: artist.id)
            if radio.isEmpty, let seed = songs.first {
                radio = await model.musicLibrary.similarSongs(seedID: seed.id)
            }
            if !radio.isEmpty {
                model.music.play(radio, source: .init(label: "\(artist.name) Radio", kind: .radio, id: nil))
            } else { playArtist() }
        }
    }
}

/// The artist banner — a blurred artwork backdrop (server photo → album/track cover →
/// monogram gradient), a circular portrait, the name + meta, an optional auto-import
/// chip, and a custom back button (the default nav back button is hidden so it doesn't
/// collide with the window's top-left traffic lights). Standalone so it renders in
/// snapshots; playback/actions live in the header below it.
struct MusicArtistBanner: View {
    let name: String
    let meta: String
    /// Preloaded hero artwork (see `MusicArtistDetail.heroImage`). Rendered directly —
    /// no AsyncImage — so re-renders never flash it away. Nil ⇒ monogram gradient.
    var heroImage: Image?
    var monogramInitial: String
    var monogramColor: Color
    var isAutoImport: Bool = false
    var downloadStatus: DownloadStatusBadge.Status = .hidden
    var onBack: () -> Void = {}

    var body: some View {
        // The name/portrait are the foreground; the artwork + darkening gradient sit
        // strictly *behind* as a background, so a loaded hero image can never cover the
        // text (a plain ZStack sibling could, depending on the fill image's overflow).
        HStack(alignment: .bottom, spacing: 14) {
            portrait
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(meta).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    if isAutoImport { autoImportChip }
                    switch downloadStatus {
                    case .complete: Image(systemName: "arrow.down.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.white).help("Downloaded")
                    case .partial: Image(systemName: "arrow.down.circle").font(.caption.weight(.semibold)).foregroundStyle(.white).help("Partly downloaded")
                    case .hidden, .downloading: EmptyView()
                    }
                }
                Text(name)
                    .font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                    .lineLimit(2).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        // Tall enough for the portrait + title with clear room for the back chevron above.
        .frame(height: 162, alignment: .bottomLeading)
        .background { backdrop }
        .clipped()
        .overlay(alignment: .topLeading) { backButton }
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [monogramColor, monogramColor.opacity(0.45)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private var backdrop: some View {
        ZStack {
            gradient
            if let heroImage {
                heroImage.resizable().scaledToFill()
                    .blur(radius: 26).opacity(0.9)
                    .transition(.opacity)
            }
            // Darken toward the bottom so the white title/meta stay legible on any image.
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder private var portrait: some View {
        Group {
            if let heroImage {
                heroImage.resizable().scaledToFill()
            } else {
                monogram
            }
        }
        .frame(width: 82, height: 82)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
    }

    private var monogram: some View {
        ZStack {
            Circle().fill(monogramColor.gradient)
            Text(monogramInitial).font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
        }
    }

    private var autoImportChip: some View {
        Label("Auto-import", systemImage: "arrow.down.doc")
            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(.orange.opacity(0.9)))
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        // Center-align the back chevron with the sidebar's collapse chevron: the rail
        // chevron sits at 8 (rail top inset) + 14 (½ of its 28pt height) = 22pt; this
        // 30pt circle needs a 7pt top inset (7 + 15) to share that center line.
        .padding(.top, 7).padding(.leading, 12)
        .help("Back")
    }
}

/// Playlist detail — the same adaptive hero + browse-header style as the album/artist
/// pages, plus playlist management (rename, share, delete) and per-track remove.
struct MusicPlaylistDetail: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlist: NavidromePlaylist
    @State private var loaded: NavidromePlaylist?
    @State private var heroImage: Image?
    @State private var filter = ""
    @State private var layout: MusicBrowseLayout = .list
    @State private var renaming = false
    @State private var newName = ""
    /// The live track order — seeded from the server, mutated during a drag-reorder, and
    /// persisted on drop. `songs` reads this so the UI reflects an in-progress reorder.
    @State private var orderedSongs: [NavidromeSong] = []
    @State private var dragging: NavidromeSong?

    private var library: MusicLibraryStore { model.musicLibrary }
    private var songs: [NavidromeSong] { orderedSongs }
    private var name: String { loaded?.name ?? playlist.name }
    /// Reorder is only meaningful on the full, unfiltered list. Also capped by size:
    /// persisting a reorder overwrites the playlist by sending every id in a GET URL, so
    /// very large playlists are excluded to stay well under proxy/server URL limits (and
    /// avoid any risk of a truncated overwrite).
    private var canReorder: Bool {
        filter.trimmingCharacters(in: .whitespaces).isEmpty && orderedSongs.count <= 200
    }
    private var isPublic: Bool { loaded?.isPublic ?? playlist.isPublic }

    private var playlistSource: StreamingPlaybackController.QueueSource {
        .init(label: name, kind: .playlist, id: playlist.id)
    }

    private var totalSeconds: Int {
        if let duration = (loaded?.duration ?? playlist.duration), duration > 0 { return duration }
        return songs.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// "N songs · 42 min · Shared" — the banner meta line.
    private var detailText: String {
        var parts: [String] = []
        let count = songs.isEmpty ? playlist.songCount : songs.count
        if count > 0 { parts.append("\(count) song\(count == 1 ? "" : "s")") }
        if totalSeconds > 0 { parts.append(MusicAlbumCard.albumDuration(totalSeconds)) }
        if isPublic { parts.append("Shared") }
        return parts.joined(separator: " · ")
    }

    private var visibleSongs: [NavidromeSong] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return songs }
        return songs.filter { $0.title.lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MusicAlbumBanner(
                    name: name,
                    kindLabel: "PLAYLIST",
                    detail: detailText,
                    heroImage: heroImage,
                    accentColor: ArtistMonogram.color(name),
                    placeholderIcon: "music.note.list",
                    downloadStatus: DownloadStatusBadge.status(playlistID: playlist.id),
                    onBack: { dismiss() }
                )

                MusicBrowseHeader(
                    title: "Songs",
                    count: visibleSongs.count,
                    filter: $filter,
                    filterPrompt: "Filter songs",
                    filterHistoryKey: "playlistSongs",
                    layout: $layout,
                    accessory: { EmptyView() },
                    leading: {
                        MusicMiniTransport(onPlayWhenIdle: { model.music.play(songs, source: playlistSource) }, pageSource: playlistSource)
                        MusicRowActions(actions: [
                            MusicRowAction(title: "Add to Queue", systemImage: "text.append") { model.music.enqueue(songs) },
                            MusicRowAction(title: "Download", systemImage: "arrow.down.circle") { Task { await MusicDownloadStore.shared.download(songs) } },
                            MusicRowAction(title: "Start Radio", systemImage: "dot.radiowaves.left.and.right") { startRadio() },
                        ])
                        playlistMenu
                    },
                    sortMenu: { EmptyView() } // playlists keep their curated order
                )

                if loaded == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                } else {
                    songsContent
                }
            }
            .padding(.bottom, 16)
        }
        .navigationBarBackButtonHidden(true)
        .task(id: playlist.id) {
            heroImage = nil
            await reload()
            await loadHeroImage()
        }
        .alert("Rename playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { Task { await library.renamePlaylist(id: playlist.id, to: trimmed); await reload() } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The playlist-management menu (rename / share / delete) — a bare ⋯ icon matching the
    /// header's other actions.
    private var playlistMenu: some View {
        Menu {
            Button("Rename…", systemImage: "pencil") { newName = name; renaming = true }
            Button(isPublic ? "Make private" : "Make shared (public)", systemImage: isPublic ? "lock" : "person.2") {
                Task { await library.setPlaylistPublic(id: playlist.id, isPublic: !isPublic); await reload() }
            }
            Divider()
            Button("Delete playlist", systemImage: "trash", role: .destructive) {
                Task { await library.deletePlaylist(id: playlist.id); dismiss() }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.callout).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary).help("Playlist options")
    }

    @ViewBuilder private var songsContent: some View {
        if songs.isEmpty {
            emptyState
        } else if visibleSongs.isEmpty {
            Text("No songs match “\(filter)”")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(24)
        } else if layout == .grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                    LikedSongGridCell(song: song, isSelected: false, showSelect: false) {
                        model.music.play(visibleSongs, startAt: index, source: playlistSource)
                    }
                }
            }
            .padding(16)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                    trackRow(song, index)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            // Catch a drop that lands between/around rows so the drag state never sticks.
            .onDrop(of: [.plainText], delegate: PlaylistDragResetDrop(dragging: $dragging, onCommit: commitReorder))
        }
    }

    @ViewBuilder private func trackRow(_ song: NavidromeSong, _ index: Int) -> some View {
        let row = MusicLikedSongRow(
            song: song,
            showSelect: false,
            onRemoveFromPlaylist: { removeFromPlaylist(song) }
        ) {
            model.music.play(visibleSongs, startAt: index, source: playlistSource)
        }
        if canReorder {
            // Drag-to-reorder (unfiltered list only). Dim the row being dragged.
            row
                .opacity(dragging?.id == song.id ? 0.35 : 1)
                .onDrag {
                    dragging = song
                    return NSItemProvider(object: song.id as NSString)
                }
                .onDrop(of: [.plainText], delegate: PlaylistReorderDrop(
                    item: song, songs: $orderedSongs, dragging: $dragging, onCommit: commitReorder
                ))
        } else {
            row
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("This playlist is empty").font(.headline)
            Text("Add tracks from any song's right-click (⋯) menu → **Add to Playlist → \(name)**.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 44).padding(.horizontal, 40)
    }

    /// Remove by the track's index in the *full* list (filter/UI order may differ).
    private func removeFromPlaylist(_ song: NavidromeSong) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        Task { await library.removeFromPlaylist(id: playlist.id, indexes: [index]); await reload() }
    }

    private func startRadio() {
        Task {
            guard let seed = songs.first else { return }
            let radio = await library.similarSongs(seedID: seed.id)
            if !radio.isEmpty {
                model.music.play(radio, source: .init(label: "\(name) Radio", kind: .radio, id: nil))
            } else {
                model.music.play(songs, source: playlistSource)
            }
        }
    }

    /// Load the hero image once from the playlist's mosaic cover (falls back to the first
    /// track's cover).
    private func loadHeroImage() async {
        let coverID = (loaded?.coverArtID ?? playlist.coverArtID) ?? songs.first?.coverArtID
        guard let coverID, let url = library.coverArtURL(id: coverID, size: 600),
              let image = await MusicAlbumDetail.fetchImage(url) else { return }
        withAnimation(.easeOut(duration: 0.25)) { heroImage = image }
    }

    private func reload() async {
        loaded = await library.playlist(id: playlist.id)
        orderedSongs = loaded?.songs ?? []
    }

    /// Persist the current order after a drag-reorder (optimistic — the local order already
    /// reflects the move).
    private func commitReorder() {
        Task { await library.reorderPlaylist(id: playlist.id, songIDs: orderedSongs.map(\.id), name: name, isPublic: isPublic) }
    }
}

/// Live drag-reorder for the playlist track list: as a dragged row hovers over another, the
/// two swap in the bound array; the drop persists the new order.
private struct PlaylistReorderDrop: DropDelegate {
    let item: NavidromeSong
    @Binding var songs: [NavidromeSong]
    @Binding var dragging: NavidromeSong?
    let onCommit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id,
              let from = songs.firstIndex(of: dragging),
              let to = songs.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            songs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onCommit()
        return true
    }
}

/// Container-level drop that resets the drag state (and persists the current order) when a
/// drag ends off any row, so a cancelled drag never leaves a row dimmed.
private struct PlaylistDragResetDrop: DropDelegate {
    @Binding var dragging: NavidromeSong?
    let onCommit: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard dragging != nil else { return false }
        dragging = nil
        onCommit()
        return true
    }
}
