import SwiftUI
import BatonSubsonicModels

/// Browsing the library the way it sits on disk.
///
/// Tag-based views are Navidrome's opinion of the library; the folder tree is the
/// *owner's* — and for a collection organized by hand over years, the folders often carry
/// meaning the tags don't (label crates, compilations, "to sort"). Subsonic has exposed
/// this since forever (`getIndexes` / `getMusicDirectory`); Amperfy ships it, and Baton
/// simply never pointed a screen at it. Both apps get one in the same release.
struct FoldersView: View {
    let model: MobileModel
    @State private var rootIndex = ServerIndexedList<NavidromeFolder>(buckets: [])
    private var roots: [NavidromeFolder] { rootIndex.items }
    @State private var loaded = false
    @State private var filter = ""

    private var shown: [NavidromeFolder] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return roots }
        return roots.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(shown) { folder in
                NavigationLink { FolderDetailView(folder: folder, model: model) } label: {
                    Label(folder.name, systemImage: "folder")
                }
                .id(folder.id)
            }
            .listStyle(.plain)
            // The roots are typically artist folders — hundreds of them — so the same
            // A–Z rail as Albums and Artists.
            .alphabetIndexRail(indexEntries, proxy: proxy)
        }
        .searchable(text: $filter, prompt: "Filter folders")
        .navigationTitle("Folders")
        .navigationBarTitleDisplayMode(.inline)
        // "The server didn't report a folder tree" was shown whether the server said so or
        // failed to answer at all — a confident explanation of the wrong thing.
        .contentState(
            ContentDisplayState.resolve(isLoading: !loaded,
                                        error: model.musicLibrary.lastError,
                                        isEmpty: roots.isEmpty),
            emptyTitle: "No folders",
            emptyMessage: model.isDemoMode
                ? "The demo library has no folder tree — connect a server to browse by folder."
                : "The server didn't report a folder tree.",
            emptySymbol: "folder",
            onRetry: { Task { rootIndex = await model.musicLibrary.folderRootIndex() } }
        )
        .task {
            rootIndex = await model.musicLibrary.folderRootIndex()
            loaded = true
        }
        .refreshable {
            rootIndex = await model.musicLibrary.folderRootIndex()
        }
    }

    /// The server's own index, exactly as `getIndexes` bucketed it — see `ServerIndexedList`.
    /// Not while filtering: a filtered list is no longer the list the server bucketed.
    private var indexEntries: AlphabetIndex.Ordered {
        guard filter.isEmpty else { return .none }
        return .server(rootIndex)
    }
}

/// One folder: subfolders first, then its songs — a Finder window's order, because the
/// mental model this screen exists to honour is the file system's.
struct FolderDetailView: View {
    let folder: NavidromeFolder
    let model: MobileModel

    @State private var directory: NavidromeDirectory?
    @State private var loaded = false

    var body: some View {
        List {
            if let directory {
                if !directory.folders.isEmpty {
                    Section {
                        ForEach(directory.folders) { sub in
                            NavigationLink { FolderDetailView(folder: sub, model: model) } label: {
                                Label(sub.name, systemImage: "folder")
                            }
                        }
                    }
                }
                if !directory.songs.isEmpty {
                    Section {
                        // Play the folder as an album: top-to-bottom, in file order.
                        Button {
                            model.music.play(directory.songs,
                                             source: .init(label: folder.name, kind: .playlist))
                        } label: {
                            Label("Play Folder", systemImage: "play.fill")
                        }
                        ForEach(Array(directory.songs.enumerated()), id: \.element.id) { index, song in
                            SongRow(song: song, model: model)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.music.play(directory.songs, startAt: index,
                                                     source: .init(label: folder.name, kind: .playlist))
                                }
                                .songContextMenu(song, model: model)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if !loaded {
                ProgressView()
            } else if directory == nil || (directory!.folders.isEmpty && directory!.songs.isEmpty) {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            }
        }
        .task {
            directory = await model.musicLibrary.directory(id: folder.id)
            loaded = true
        }
    }
}
