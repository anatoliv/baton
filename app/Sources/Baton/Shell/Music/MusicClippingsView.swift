import BatonPlaybackKit
import BatonSubsonicKit
import BatonSubsonicModels
import SwiftUI

/// **Clippings** — audio Baton made and kept: a saved reading, and in time anything clipped out
/// of what is playing.
///
/// Built from `MusicBrowseHeader` and the same list rows as every other browse view, which is
/// what makes it *look and behave* like the rest rather than merely resemble it: the filter, the
/// filter history, the layout toggle, the mini transport and the sort control are all the shared
/// ones. Nothing here is a bespoke copy.
///
/// A clipping plays through the ordinary player. Its id is its file URL, which `MediaKind`
/// classifies as `.localFile` and `resolveStreamURL` resolves directly, so the transport, the
/// now-playing bar, the queue and the scrubber all work with no second playback path.
struct MusicClippingsView: View {
    @Environment(MusicModel.self) private var model

    @State private var filterText = ""
    @FocusState private var filterFocused: Bool
    @AppStorage(BrowseScreen.clipping.layoutKey) private var layout: MusicBrowseLayout = .list
    @State private var renaming: ClippingStore.Item?
    @State private var newTitle = ""
    @State private var pendingDelete: ClippingStore.Item?
    @Environment(BatonCommandRouter.self) private var router: BatonCommandRouter?
    /// A file to import, from Import Document… or a drop (document clippings, M3.4).
    @State private var importing: URL?
    @State private var expandedBooks: Set<String> = []
    @State private var pendingBookDelete: BookShelf.Book?

    private var store: ClippingStore { model.clippings }

    /// Books are behind `baton.documents.enabled` until the Mac book flow is complete.
    private var documentsOn: Bool { DocumentLibrary.isEnabled() }

    /// Render jobs, so a book shows from the moment it is submitted. Matched by title while
    /// filtering, and by its chapters through `filtered`.
    private var jobs: [DocumentLibrary.Job] {
        guard documentsOn else { return [] }
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.documents.jobs
        guard !query.isEmpty else { return all }
        let matched = Set(filtered.compactMap(\.clipping.documentID))
        return all.filter { matched.contains($0.documentID) || $0.summary.title.lowercased().contains(query) }
    }

    /// Readings as rows, and each book as one row that opens into its chapters.
    private var entries: [BookShelf.Entry] {
        BookShelf.entries(items: filtered, jobs: jobs, ledger: store.ledger)
    }

    /// Where the "play all clippings" transport queues from, named as the other views name
    /// themselves.
    private var clippingsSource: StreamingPlaybackController.QueueSource {
        .init(label: "Clippings", kind: .liked, id: nil)
    }

    /// Filtered by name, source **and text**.
    ///
    /// Searching the words is the point: a clipping is the only thing in Baton that knows what is
    /// said inside it, so filtering by "the bit about notarization" finds the reading rather than
    /// requiring you to remember what you called it.
    private var filtered: [ClippingStore.Item] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.items }
        return store.items.filter {
            $0.clipping.title.lowercased().contains(query)
                || ($0.clipping.source?.lowercased().contains(query) ?? false)
                || ($0.clipping.text?.lowercased().contains(query) ?? false)
        }
    }

    /// Only what can actually be played. A missing file in a queue is a track that stalls with no
    /// explanation, which is worse than one that is visibly unavailable in the list.
    private var playable: [NavidromeSong] { filtered.filter(\.isPresent).map(\.asSong) }

    private var totalSizeText: String {
        let bytes = store.totalBytes
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        Group {
            if store.items.isEmpty && jobs.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    MusicBrowseHeader(
                        title: "Clippings",
                        count: entries.count,
                        filter: $filterText,
                        filterPrompt: "Filter clippings",
                        filterFocused: $filterFocused,
                        filterHistoryKey: "clippings",
                        layout: $layout,
                        accessory: {
                            if !totalSizeText.isEmpty {
                                Text(totalSizeText).font(.caption).foregroundStyle(.secondary)
                            }
                        },
                        leading: {
                            MusicMiniTransport(
                                onPlayWhenIdle: { model.music.play(playable, source: clippingsSource) },
                                pageSource: clippingsSource
                            )
                        },
                        sortMenu: { EmptyView() }
                    )
                    list
                }
            }
        }
        .task { store.loadIfNeeded() }
        .onAppear {
            store.reload()
            if documentsOn { model.documents.refresh() }
            takePendingImport()
        }
        .onChange(of: router?.pendingDocumentImport) { _, _ in takePendingImport() }
        .modifier(DocumentDropTarget(enabled: documentsOn, importing: $importing))
        .sheet(isPresented: .init(get: { importing != nil }, set: { if !$0 { importing = nil } })) {
            if let importing {
                DocumentImportSheet(url: importing, library: model.documents) { self.importing = nil }
            }
        }
        .confirmationDialog("Delete this book?", isPresented: .init(
            get: { pendingBookDelete != nil },
            set: { if !$0 { pendingBookDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Remove from This Mac", role: .destructive) {
                if let book = pendingBookDelete { deleteBook(book, everywhere: false) }
                pendingBookDelete = nil
            }
            Button("Delete Everywhere", role: .destructive) {
                if let book = pendingBookDelete { deleteBook(book, everywhere: true) }
                pendingBookDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingBookDelete = nil }
        } message: {
            Text("This stops making the book and removes its chapters. Removing it here leaves "
                 + "whatever is on your iPhone. Deleting everywhere also removes it from your "
                 + "home gateway and from your other devices.")
        }
        .alert("Rename clipping", isPresented: .init(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newTitle)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming, !newTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    // No `noteLocalChange` here on purpose. `PreferenceSync.startObservingChanges`
                    // watches UserDefaults and stamps any synced key that moves, and its own note
                    // says hand-placed calls had drifted to covering 3 of 16 keys — every setting
                    // somebody forgot to instrument silently stopped syncing. The ledger lives in
                    // UserDefaults, so the observer already has it.
                    store.rename(id: renaming.id, to: newTitle)
                }
                renaming = nil
            }
        }
        // Two outcomes, in the same words the iPhone uses. A single "Delete" had to
        // pick one of them silently, and either choice is wrong half the time: deleting only
        // here leaves it on your phone for ever, and deleting everywhere destroys a copy you may
        // have wanted to keep. Only the person knows which they mean.
        .confirmationDialog("Delete this clipping?", isPresented: .init(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Remove from This Mac", role: .destructive) {
                if let pendingDelete {
                    // Off the speakers and out of the queue before the file goes. Deleting told
                    // the player nothing, and on Darwin an open file outlives its directory
                    // entry, so a deleted clipping played on to the end of something that no
                    // longer existed.
                    model.music.dropFromQueue(ids: [pendingDelete.asSong.id])
                    store.remove(id: pendingDelete.id)
                }
                pendingDelete = nil
            }
            Button("Delete Everywhere", role: .destructive) {
                if let item = pendingDelete { deleteEverywhere(item) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Baton made this audio and there is no other copy of it. Removing it here leaves "
                 + "whatever is on your iPhone. Deleting everywhere also removes it from your "
                 + "home gateway and from your other devices.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    switch entry {
                    case let .reading(item): row(item)
                    case let .book(book): bookRow(book)
                    }
                    Divider().padding(.leading, 52)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func row(_ item: ClippingStore.Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isPresent ? "waveform" : "exclamationmark.triangle")
                .foregroundStyle(item.isPresent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.clipping.title).lineLimit(1)
                HStack(spacing: 6) {
                    if let source = item.clipping.source, !source.isEmpty {
                        Text(source)
                    }
                    Text(item.clipping.createdAt, style: .date)
                    if let seconds = item.clipping.durationSeconds, seconds > 0 {
                        Text(Self.durationText(seconds))
                    }
                    // Said plainly rather than shown as a silent failure at play time.
                    if !item.isPresent {
                        Text("the audio file has gone").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play(item) }
        .opacity(item.isPresent ? 1 : 0.6)
        .contextMenu {
            Button("Play") { play(item) }.disabled(!item.isPresent)
            Button("Play Next") {
                model.music.playNext([item.asSong])
            }.disabled(!item.isPresent)
            Divider()
            Button("Rename…") {
                newTitle = item.clipping.title
                renaming = item
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }.disabled(!item.isPresent)
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = item }
        }
    }

    /// Delete here, state it in the shared ledger, and remove the shared copy.
    ///
    /// The ledger write is what reaches the other device; the gateway delete is what stops it
    /// being collected afresh by a device that has never seen it. Both are needed, and the ledger
    /// is the one that must not fail silently — a gateway that is unreachable still leaves a
    /// tombstone that will be honoured the next time anything syncs.
    private func deleteEverywhere(_ item: ClippingStore.Item) {
        let digest = item.clipping.sha256
        model.music.dropFromQueue(ids: [item.asSong.id])
        store.remove(id: item.id, everywhere: true)

        guard let digest else { return }        // never travelled; nothing shared to remove
        let raw = (BatonStorage.defaults.string(forKey: "baton.agent.gatewayURL") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let token = (NavidromeKeychain.secret(account: "baton.agent.gatewayToken") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !token.isEmpty, let url = URL(string: raw), url.host != nil else { return }

        Task {
            do {
                try await GatewayFiles(gatewayURL: url, token: token).delete(id: digest)
            } catch {
                // Named rather than swallowed: the clipping is gone from this Mac either way,
                // and the tombstone still travels, so this is "the shared copy outlived the
                // request" rather than a failed delete.
                model.music.postToast("Deleted here; the shared copy is still on the gateway",
                                      symbol: "exclamationmark.triangle", seconds: 4)
            }
        }
    }

    /// Play from this clipping onwards, so the list behaves like every other list here rather
    /// than playing one item and stopping.
    private func play(_ item: ClippingStore.Item) {
        let songs = playable
        guard let index = songs.firstIndex(where: { $0.id == item.asSong.id }) else { return }
        model.music.play(Array(songs[index...]), source: clippingsSource)
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return minutes > 0 ? "\(minutes) min \(remainder)s" : "\(remainder)s"
    }

    // MARK: - Books (document clippings, M3.5)

    private func takePendingImport() {
        guard documentsOn, let url = router?.pendingDocumentImport else { return }
        router?.pendingDocumentImport = nil
        importing = url
    }

    private func bookRow(_ book: BookShelf.Book) -> some View {
        let expanded = expandedBooks.contains(book.documentID)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if expanded { expandedBooks.remove(book.documentID) } else { expandedBooks.insert(book.documentID) }
                } label: {
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: expanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                .offset(x: 5, y: 4)
                        }
                }
                .buttonStyle(.plain)
                .frame(width: 28)
                .accessibilityLabel(expanded ? "Hide chapters" : "Show chapters")

                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).lineLimit(1)
                    HStack(spacing: 6) {
                        if let author = book.author, !author.isEmpty { Text(author) }
                        Text(book.summaryText)
                        Text(book.storedText)
                        if book.finished {
                            Text("Finished")
                        } else if book.listenedFraction > 0 {
                            Text("\(Int((book.listenedFraction * 100).rounded()))% heard")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if let status = Self.statusLine(book) {
                        Text(status.text)
                            .font(.caption)
                            .foregroundStyle(status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                    }
                    if book.listenedFraction > 0 && !book.finished {
                        ProgressView(value: book.listenedFraction).controlSize(.mini).frame(maxWidth: 240)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { play(book) }
            .contextMenu {
                Button("Play") { play(book) }.disabled(book.chapters.allSatisfy { $0.item?.isPresent != true })
                Button(expanded ? "Hide Chapters" : "Show Chapters") {
                    if expanded { expandedBooks.remove(book.documentID) } else { expandedBooks.insert(book.documentID) }
                }
                if let first = book.chapters.compactMap(\.item).first(where: \.isPresent) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([first.url]) }
                }
                Divider()
                Button("Delete Book…", role: .destructive) { pendingBookDelete = book }
            }

            if expanded {
                ForEach(book.chapters) { chapter in
                    chapterRow(book, chapter)
                }
            }
        }
    }

    private func chapterRow(_ book: BookShelf.Book, _ chapter: BookShelf.Chapter) -> some View {
        HStack(spacing: 8) {
            Text("\(chapter.index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            Text(chapter.title).lineLimit(1)
            Spacer()
            Text(Self.chapterStateText(chapter)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 52)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .opacity(chapter.item?.isPresent == true ? 1 : 0.6)
        .onTapGesture(count: 2) { play(book, fromChapter: chapter.index) }
    }

    /// One line under the book: why it is waiting, or what it is making.
    static func statusLine(_ book: BookShelf.Book) -> (text: String, isProblem: Bool)? {
        if let reason = book.pauseReason {
            return ("Paused: \(reason). It carries on by itself when the voice server answers.", true)
        }
        if let failure = book.failure { return ("Stopped: \(failure)", true) }
        guard book.isRendering, let next = book.chapters.first(where: { $0.item == nil && $0.state != .removed }) else {
            return nil
        }
        let of = "chapter \(next.index + 1) of \(book.chapters.count)"
        switch next.state {
        case let .rendering(progress): return ("Making \(of), \(Int((progress * 100).rounded()))%", false)
        case .encoding: return ("Finishing \(of)", false)
        default: return ("Waiting to make \(of)", false)
        }
    }

    static func chapterStateText(_ chapter: BookShelf.Chapter) -> String {
        switch chapter.state {
        case .ready:
            if chapter.item?.isPresent == false { return "the audio file has gone" }
            return chapter.item?.clipping.durationSeconds.map(BookShelf.durationText) ?? ""
        case .queued: return "waiting"
        case let .rendering(progress): return "\(Int((progress * 100).rounded()))%"
        case .encoding: return "finishing"
        case .failed: return "failed"
        case .removed: return "removed from this Mac"
        }
    }

    /// Play from the synced position, or from a chosen chapter.
    private func play(_ book: BookShelf.Book, fromChapter index: Int? = nil) {
        var (songs, start) = BookPlayback.queue(for: book)
        if let index {
            let present = book.chapters.compactMap(\.item).filter(\.isPresent)
            if let i = present.firstIndex(where: { $0.clipping.chapterIndex == index }) { start = i }
        }
        guard !songs.isEmpty else { return }
        model.music.play(songs, startAt: start, source: .init(label: book.title, kind: .liked, id: nil))
    }

    /// Stop making the book and remove its chapters, here or everywhere.
    private func deleteBook(_ book: BookShelf.Book, everywhere: Bool) {
        if let job = model.documents.job(forDocument: book.documentID) {
            let library = model.documents
            Task { await library.cancel(job.id) }
        }
        for item in book.chapters.compactMap(\.item) {
            if everywhere {
                deleteEverywhere(item)
            } else {
                model.music.dropFromQueue(ids: [item.asSong.id])
                store.remove(id: item.id)
            }
        }
        expandedBooks.remove(book.documentID)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No clippings yet").font(.headline)
            Text("Read something aloud, then choose File → Keep Reading in Clippings. It is kept "
                 + "here, plays like anything else, and works with no server and no network."
                 + (documentsOn ? " Or choose File → Import Document to hear a PDF or text file "
                    + "as a narrated book, or drop one here." : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Drop a PDF, text or Markdown file onto Clippings to import it. Only while the feature flag is
/// on, so nothing about Clippings changes for anyone else.
private struct DocumentDropTarget: ViewModifier {
    let enabled: Bool
    @Binding var importing: URL?

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: DocumentLibrary.canImport) else { return false }
                importing = url
                return true
            }
        } else {
            content
        }
    }
}
