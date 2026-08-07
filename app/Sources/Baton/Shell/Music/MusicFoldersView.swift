import SwiftUI
import BatonPlaybackKit
import BatonSubsonicModels

/// Browsing the library the way it sits on disk — the Mac's half of the Folders surface
/// the phone gained in the same release.
///
/// Tag views are Navidrome's opinion of the library; the folder tree is the *owner's*,
/// and for a collection organized by hand over years the folders carry meaning the tags
/// don't. `getIndexes`/`getMusicDirectory` have been in Subsonic forever; nothing here
/// ever pointed a screen at them. Column-free on purpose: a pushed list per folder is the
/// navigation the rest of this window already speaks, and a Miller-column browser would
/// be a second idiom to maintain for the same walk.
struct MusicFoldersView: View {
    @Environment(MusicModel.self) private var model

    @State private var roots: [NavidromeFolder] = []
    @State private var loaded = false
    @State private var filter = ""

    private var shown: [NavidromeFolder] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return roots }
        return roots.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { folder in
                NavigationLink {
                    MusicFolderDetailView(folder: folder)
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
            }
            .navigationTitle("Folders")
        }
        .searchable(text: $filter, prompt: "Filter folders")
        .overlay {
            if loaded, roots.isEmpty {
                ContentUnavailableView(
                    "No folders",
                    systemImage: "folder",
                    description: Text("The server didn't report a folder tree.")
                )
            } else if !loaded {
                ProgressView()
            }
        }
        .task {
            roots = await model.musicLibrary.folderRoots()
            loaded = true
        }
    }
}

/// One folder: subfolders first, then songs in file order — a Finder window's reading.
struct MusicFolderDetailView: View {
    @Environment(MusicModel.self) private var model
    let folder: NavidromeFolder

    @State private var directory: NavidromeDirectory?
    @State private var loaded = false

    var body: some View {
        List {
            if let directory {
                if !directory.folders.isEmpty {
                    Section {
                        ForEach(directory.folders) { sub in
                            NavigationLink {
                                MusicFolderDetailView(folder: sub)
                            } label: {
                                Label(sub.name, systemImage: "folder")
                            }
                        }
                    }
                }
                if !directory.songs.isEmpty {
                    Section {
                        Button {
                            model.music.play(directory.songs,
                                             source: .init(label: folder.name, kind: .playlist))
                        } label: {
                            Label("Play Folder", systemImage: "play.fill")
                        }
                        ForEach(Array(directory.songs.enumerated()), id: \.element.id) { index, song in
                            MusicTrackRow(song: song) {
                                model.music.play(directory.songs, startAt: index,
                                                 source: .init(label: folder.name, kind: .playlist))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(folder.name)
        .overlay {
            if !loaded {
                ProgressView()
            } else if directory == nil || (directory!.folders.isEmpty && directory!.songs.isEmpty) {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            }
        }
        .task(id: folder.id) {
            directory = await model.musicLibrary.directory(id: folder.id)
            loaded = true
        }
    }
}
