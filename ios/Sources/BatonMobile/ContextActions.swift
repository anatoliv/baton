import SwiftUI

/// Long-press actions for songs, albums, artists and playlists — the phone's answer to
/// the Mac's right-click menus.
///
/// These are one modifier rather than menus written per screen because the same actions
/// have to be available everywhere a track appears (search, album, playlist, mix, shelf,
/// queue) and a menu that exists on three of six screens is worse than none: you learn to
/// long-press, then learn it sometimes does nothing.
///
/// The engine and client methods behind every item already existed and were already
/// proven on the Mac — until now the phone simply offered no way to reach them.

// MARK: - Songs

struct SongContextMenu: ViewModifier {
    let song: NavidromeSong
    let model: MobileModel
    @State private var showsPlaylistPicker = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    model.music.playNext([song])
                } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }

                Button {
                    model.music.enqueue([song])
                } label: { Label("Add to Queue", systemImage: "text.append") }

                // Everything below needs a server: rating, playlists and similarity are
                // all server-side. In demo mode they'd fail silently, so they're absent.
                if !model.isDemoMode {
                    Divider()

                    Button {
                        Task { await model.musicLibrary.toggleLike(song) }
                    } label: {
                        let liked = model.musicLibrary.isLiked(song)
                        Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart")
                    }

                    // A menu can't show five tappable stars, so the current rating is
                    // marked with a checkmark — the idiom this app already uses for sort
                    // order. Every row previously carried the same outline star, so the
                    // menu could tell you what the ratings *are* but never which one you
                    // had chosen, and the parent row said "Rate" whatever the song scored.
                    let rating = model.musicLibrary.rating(song)
                    Menu {
                        ForEach((1 ... 5).reversed(), id: \.self) { stars in
                            Button {
                                Task { await model.musicLibrary.setRating(song, rating: stars) }
                            } label: {
                                if stars == rating {
                                    Label(String(repeating: "★", count: stars), systemImage: "checkmark")
                                } else {
                                    Text(String(repeating: "★", count: stars))
                                }
                            }
                        }
                        if rating > 0 {
                            Divider()
                            Button {
                                Task { await model.musicLibrary.setRating(song, rating: 0) }
                            } label: { Label("Clear rating", systemImage: "star.slash") }
                        }
                    } label: {
                        // Says the current score rather than a bare "Rate", so the rating
                        // is legible without opening anything.
                        Label(rating > 0 ? "Rated \(rating)★" : "Rate",
                              systemImage: rating > 0 ? "star.fill" : "star")
                    }

                    // Where this song lives. The player and the queue were dead ends —
                    // no path from a playing track to its album or artist anywhere on
                    // the phone, while the Mac has auto-revealed the playing track for
                    // versions. Reveal is model-level because this menu can be two
                    // sheets deep (queue, inside the player).
                    Divider()
                    if song.albumID != nil {
                        Button {
                            model.revealAlbum(of: song)
                        } label: { Label("Go to Album", systemImage: "square.stack") }
                    }
                    if let artist = model.artistNamed(song.artist) {
                        Button {
                            model.revealedArtist = artist
                        } label: { Label("Go to Artist", systemImage: "music.mic") }
                    }

                    Button {
                        showsPlaylistPicker = true
                    } label: { Label("Add to Playlist…", systemImage: "music.note.list") }

                    Divider()

                    Button {
                        Task { await startRadio() }
                    } label: { Label("Start Radio", systemImage: "dot.radiowaves.left.and.right") }

                    // A ban keeps the song in your library and playlists — it only stops
                    // radio and autoplay suggesting it, so those suggestions learn.
                    Button {
                        model.radioBans.toggle(song.id)
                        model.preferenceSync.noteLocalChange("tonebox.music.radioBans")
                    } label: {
                        let banned = model.radioBans.isBanned(song.id)
                        Label(banned ? "Allow in Radio" : "Never Play in Radio",
                              systemImage: banned ? "checkmark.circle" : "hand.raised")
                    }

                    // The library-curation signal the Mac's pipeline reads: unlike + rate 1.
                    // Destructive-styled because it's a vote to delete the file later.
                    Button(role: .destructive) {
                        Task { await model.musicLibrary.markForRemoval(song) }
                    } label: { Label("Mark for Removal", systemImage: "trash.slash") }
                }

                Button {
                    Task { _ = await MusicDownloadStore.shared.download([song]) }
                } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            .sheet(isPresented: $showsPlaylistPicker) {
                PlaylistPickerSheet(songIDs: [song.id], model: model)
            }
    }

    /// Seed a radio from this track — the shared similarity endpoint, same as the Mac's
    /// "start radio from this". The seed plays first so the tap has an immediate result.
    private func startRadio() async {
        let similar = model.radioBans.filtered(await model.musicLibrary.similarSongs(seedID: song.id))
        let queue = [song] + similar.filter { $0.id != song.id }
        model.music.play(queue, source: .init(label: "Radio · \(song.title)", kind: .radio, id: song.id))
    }
}

// MARK: - Albums

struct AlbumContextMenu: ViewModifier {
    let album: NavidromeAlbum
    let model: MobileModel
    @State private var showsPlaylistPicker = false
    @State private var pickerSongIDs: [String] = []

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    Task { model.music.play(await songs(), source: source) }
                } label: { Label("Play", systemImage: "play.fill") }

                Button {
                    Task { model.music.play(await songs().shuffled(), source: source) }
                } label: { Label("Shuffle", systemImage: "shuffle") }

                Button {
                    Task { model.music.playNext(await songs()) }
                } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }

                Button {
                    Task { model.music.enqueue(await songs()) }
                } label: { Label("Add to Queue", systemImage: "text.append") }

                if !model.isDemoMode {
                    Divider()
                    Button {
                        Task { await model.musicLibrary.toggleLike(id: album.id, currentLiked: album.isLiked, userRating: album.userRating) }
                    } label: {
                        let liked = model.musicLibrary.isLiked(id: album.id, isLiked: album.isLiked)
                        Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart")
                    }
                    Button {
                        Task {
                            pickerSongIDs = await songs().map(\.id)
                            showsPlaylistPicker = true
                        }
                    } label: { Label("Add to Playlist…", systemImage: "music.note.list") }
                }

                Button {
                    Task { _ = await MusicDownloadStore.shared.download(await songs()) }
                } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            .sheet(isPresented: $showsPlaylistPicker) {
                PlaylistPickerSheet(songIDs: pickerSongIDs, model: model)
            }
    }

    private var source: QueueSource { .init(label: album.name, kind: .album, id: album.id) }
    private func songs() async -> [NavidromeSong] { await model.musicLibrary.albumSongs(id: album.id) }
}

// MARK: - Convenience

extension View {
    func songContextMenu(_ song: NavidromeSong, model: MobileModel) -> some View {
        modifier(SongContextMenu(song: song, model: model))
    }

    func albumContextMenu(_ album: NavidromeAlbum, model: MobileModel) -> some View {
        modifier(AlbumContextMenu(album: album, model: model))
    }
}

// MARK: - Add to playlist

/// Pick a playlist to add to, or make one on the spot. Shown from every "Add to
/// Playlist…" action so the flow is identical wherever it's reached from.
struct PlaylistPickerSheet: View {
    let songIDs: [String]
    let model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var isWorking = false
    @State private var status: String?

    var body: some View {
        NavigationStack {
            List {
                Section("New playlist") {
                    HStack {
                        TextField("Name", text: $newName)
                        Button("Create") { Task { await createAndAdd() } }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    }
                }
                Section("Add to") {
                    if model.musicLibrary.playlists.isEmpty {
                        Text("No playlists yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.musicLibrary.playlists) { playlist in
                        Button {
                            Task { await add(to: playlist) }
                        } label: {
                            HStack {
                                Label(playlist.name, systemImage: "music.note.list")
                                Spacer()
                                Text("\(playlist.songCount)").foregroundStyle(.secondary).font(.caption)
                            }
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .navigationTitle(songIDs.count == 1 ? "Add to Playlist" : "Add \(songIDs.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await model.musicLibrary.loadPlaylists() }
            .overlay { if isWorking { ProgressView() } }
            .alert("Playlist", isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) {
                Button("OK") { status = nil; dismiss() }
            } message: {
                if let status { Text(status) }
            }
        }
    }

    private func add(to playlist: NavidromePlaylist) async {
        isWorking = true
        let added = await model.musicLibrary.addToPlaylist(id: playlist.id, songIDs: songIDs)
        isWorking = false
        // Report the count the server accepted, not the count we sent — a playlist that
        // already held the track is a different outcome from a failure, and saying
        // "added" either way would be a small lie.
        status = added > 0
            ? "Added \(added) \(added == 1 ? "song" : "songs") to \(playlist.name)."
            : "Nothing was added to \(playlist.name)."
    }

    private func createAndAdd() async {
        isWorking = true
        let name = newName.trimmingCharacters(in: .whitespaces)
        let created = await model.musicLibrary.createPlaylist(name: name, songIDs: songIDs)
        isWorking = false
        status = created != nil
            ? "Created \(name) with \(songIDs.count) \(songIDs.count == 1 ? "song" : "songs")."
            : "Couldn't create that playlist."
    }
}
