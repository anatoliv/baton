import BatonDocuments
import BatonPlaybackKit
import BatonSpeech
import BatonSubsonicKit
import BatonSubsonicModels
import SwiftUI
import UniformTypeIdentifiers

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
    /// "Previously…" when a book is picked up after a break (M8.4).
    @State private var recap = BookRecapOffer()
    /// The book whose Play is fetching the other device's place first, and the one
    /// showing "Getting your place…" once that wait is long enough to notice.
    @State private var pullingPlace: String?
    @State private var gettingPlace: String?
    /// The book whose pronunciations are being corrected (M8.6).
    @State private var pronouncing: BookShelf.Book?
    /// The book open in Read Along.
    @State private var readingAlong: BookShelf.Book?
    /// The book or kept reading whose voice is being changed.
    @State private var changingBook: BookShelf.Book?
    @State private var changingReading: ClippingStore.Item?
    private var revoicer: ClippingRevoicer { ClippingRevoicer.shared }
    /// An export in progress, or why the last one failed (M8.8).
    @State private var exportLine: String?
    @State private var exportFailed = false
    /// The weekly storage suggestion, while it is on offer (M6.5).
    @State private var suggestion: BookStorage.Suggestion?
    /// A document sent from the iPhone, open in the import sheet.
    @State private var sentImport: DocumentInbox.Item?

    private var store: ClippingStore { model.clippings }

    /// `baton.documents.enabled`, read live, so the book rows, the drop target and the import
    /// line follow the Settings switch at once.
    private var documentsOn: Bool { model.documentsSwitch.isOn }

    /// Render jobs, so a book shows from the moment it is submitted. Matched by title while
    /// filtering, and by its chapters through `filtered`.
    private var jobs: [DocumentLibrary.Job] {
        guard documentsOn else { return [] }
        let all = model.documents.jobs
        guard search.isFiltering else { return all }
        let matched = Set(filtered.compactMap(\.clipping.documentID))
        return all.filter { matched.contains($0.documentID) || search.matches(title: $0.summary.title) }
    }

    /// Readings as rows, and each book as one row that opens into its chapters.
    private var entries: [BookShelf.Entry] {
        // With the voice changes, so a book being made again says so.
        BookShelf.entries(items: filtered, jobs: jobs, ledger: store.ledger,
                          changes: documentsOn ? model.documents.voiceChanges.all : [])
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
    ///
    /// Through the shared search index (M8.9), which ignores case and accents and answers a pause
    /// in typing rather than every keystroke; a book's chapters are 70,000 characters each.
    private var filtered: [ClippingStore.Item] { search.filter(store.items) }

    private var search: ClippingSearch { model.clippingSearch }

    /// Only what can actually be played. A missing file in a queue is a track that stalls with no
    /// explanation, which is worse than one that is visibly unavailable in the list. Readings
    /// only: a book plays as its own queue, from its row.
    private var playable: [NavidromeSong] { ClippingQueue.readings(filtered) }

    private var totalSizeText: String {
        let bytes = store.totalBytes
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Documents sent from the iPhone and waiting here, while Documents is on.
    private var sentItems: [DocumentInbox.Item] { documentsOn ? model.documentInbox.items : [] }

    var body: some View {
        Group {
            if store.items.isEmpty && jobs.isEmpty && sentItems.isEmpty {
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
                    if let suggestion, documentsOn { suggestionBanner(suggestion) }
                    if !sentItems.isEmpty { sentBanner }
                    if recap.offer != nil { recapBanner }
                    if let exportLine {
                        HStack(spacing: 8) {
                            if !exportFailed { ProgressView().controlSize(.small) }
                            Text(exportLine).font(.callout).foregroundStyle(exportFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            Spacer()
                            if exportFailed { Button("Dismiss") { self.exportLine = nil } }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    list
                }
            }
        }
        .task { store.loadIfNeeded() }
        #if DEBUG
        // DEBUG only: `scripts/probe-pronunciations-home-server.sh` opens Pronunciations… for the
        // first book made on the home server once every chapter is here, rather than driving a
        // row's context menu. An environment variable, never a launch argument.
        .task {
            guard ProcessInfo.processInfo.environment["BATON_DEBUG_OPEN_PRONUNCIATIONS"] == "1" else { return }
            for _ in 0..<240 {
                if documentsOn, let book = model.documents.shelf.first(where: { book in
                    book.madeOn == .homeServer && book.chapters.allSatisfy { $0.item != nil }
                        && model.documents.canEditPronunciations(book)
                }) {
                    pronouncing = book
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // DEBUG only: `scripts/probe-change-voice.sh` opens Change Voice… for the
        // first book whose chapters are all here (`book`) or the first kept reading with words
        // (`reading`), in place of a row's context menu. By environment, never argv.
        .task {
            let which = ProcessInfo.processInfo.environment["BATON_DEBUG_OPEN_CHANGE_VOICE"]
            guard which == "book" || which == "reading" else { return }
            for _ in 0..<240 {
                if which == "book", documentsOn, let book = model.documents.shelf.first(where: { book in
                    !book.chapters.isEmpty && book.chapters.allSatisfy { $0.item != nil } && model.documents.canChangeVoice(book)
                }) {
                    changingBook = book
                    return
                }
                if which == "reading", let item = store.items.first(where: { !$0.clipping.isBookChapter && $0.clipping.text?.isEmpty == false }) {
                    changingReading = item
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        #endif
        .onChange(of: filterText, initial: true) { _, text in
            search.follow(store)
            search.setQuery(text)
        }
        .onAppear {
            store.reload()
            if documentsOn {
                model.documents.refresh()
                // The person's storage rules, then at most one suggestion a week (M6.3, M6.5).
                model.documents.applyStorageRules()
                refreshSuggestion()
                // A book made on the home server from another device appears here.
                if model.documents.homeServer.isConfigured {
                    Task { await model.documents.refreshHomeServer() }
                }
            }
            takePendingImport()
            offerNextSent()
        }
        .onChange(of: documentsOn ? model.documentInbox.nextOffer?.id : nil) { _, _ in offerNextSent() }
        .onChange(of: importing == nil && pronouncing == nil) { _, free in if free { offerNextSent() } }
        .sheet(item: $sentImport, onDismiss: offerNextSent) { item in
            if let source = item.source {
                DocumentImportSheet(url: source, library: model.documents, sentFrom: item.record.fromDevice,
                                    onImported: { model.documentInbox.finish(item.id) },
                                    onDiscard: { model.documentInbox.finish(item.id) }) {
                    // Not Now, unless it was just imported or discarded (then it is gone already).
                    model.documentInbox.notNow(item.id)
                    sentImport = nil
                }
            }
        }
        .onChange(of: documentsOn) { _, on in
            if on { model.documents.refresh(); refreshSuggestion() } else { suggestion = nil }
        }
        // A book made on the home server becomes removable when the home server first answers
        // after launch, which can be after Clippings appeared. Asking again keeps the
        // weekly limit: an open suggestion is returned as it is, and none is made within the week.
        .onChange(of: documentsOn ? model.documents.removableBookIDs : []) { _, _ in
            if documentsOn { refreshSuggestion() }
        }
        .onChange(of: router?.pendingDocumentImport) { _, _ in takePendingImport() }
        .modifier(DocumentDropTarget(enabled: documentsOn, importing: $importing))
        .sheet(isPresented: .init(get: { importing != nil }, set: { if !$0 { importing = nil } })) {
            if let importing {
                DocumentImportSheet(url: importing, library: model.documents) { self.importing = nil }
            }
        }
        .sheet(item: $readingAlong) { book in
            ReadAlongSheet(book: book) { chapter in startPlaying(book, fromChapter: chapter) }
        }
        .sheet(item: $changingBook) { book in
            if let target = ChangeVoiceSheet.Target.book(book, library: model.documents) {
                ChangeVoiceSheet(target: target) { changingBook = nil }
            }
        }
        .sheet(item: $changingReading) { item in
            ChangeVoiceSheet(target: .reading(item, store: store, revoicer: revoicer) { error in
                model.music.postToast("The reading keeps its voice: \(error)", symbol: "exclamationmark.triangle", seconds: 5)
            }) { changingReading = nil }
        }
        .sheet(isPresented: .init(get: { pronouncing != nil }, set: { if !$0 { pronouncing = nil } })) {
            if let pronouncing {
                PronunciationSheet(book: pronouncing, library: model.documents, clippings: store) { self.pronouncing = nil }
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
            Text("This removes its chapters from this Mac, and a book being made here stops. Removing it "
                 + "here leaves any copy on your Baton server and your iPhone. Deleting everywhere also "
                 + "removes it from your Baton server and your other devices. For a week you can restore it from "
                 + "Recently removed in Settings, under Storage.")
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
                 + "Baton server and from your other devices.")
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
        let isCurrent = isCurrent(item)
        let isPlaying = isCurrent && model.music.isPlaying
        return HStack(spacing: 12) {
            // Bars while it plays, as on a music row; the waveform is the clipping's resting
            // icon, not a state.
            Group {
                if isPlaying {
                    NowPlayingBars(isPlaying: true)
                } else {
                    Image(systemName: item.isPresent ? "waveform" : "exclamationmark.triangle")
                        .foregroundStyle(item.isPresent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.clipping.title).lineLimit(1)
                    .foregroundStyle(isPlaying ? Color.accentColor : .primary)
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
                if let progress = revoicer.running[item.id] {
                    Text(Self.remakingLine(progress))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: progress.fraction).controlSize(.mini).frame(maxWidth: 240)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // The current clipping keeps its tint while paused; the bars and the accent title are
        // the extra "playing now" cue and go when it pauses, the rule every music row keeps.
        .background(isCurrent ? Color.nowPlayingRowTint() : .clear)
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
            if revoicer.running[item.id] != nil {
                Button("Stop Making Again") { revoicer.cancel(item.id) }
            } else if item.clipping.text?.isEmpty == false {
                Button("Change Voice…") { changingReading = item }
            }
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
        removeSharedCopy(digest)
    }

    /// Remove the gateway's shared copy of a clipping, by its digest.
    private func removeSharedCopy(_ digest: String) {
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
                model.music.postToast("Deleted here; the shared copy is still on the Baton server",
                                      symbol: "exclamationmark.triangle", seconds: 4)
            }
        }
    }

    /// Whether this clipping is the one loaded in the player, playing or paused.
    private func isCurrent(_ item: ClippingStore.Item?) -> Bool {
        item?.isLoaded(nowPlayingID: model.music.nowPlaying?.id) == true
    }

    /// Whether one of this book's chapters is the one loaded in the player.
    private func isCurrent(_ book: BookShelf.Book) -> Bool {
        guard let id = model.music.nowPlaying?.id else { return false }
        return book.chapters.contains { $0.item?.isLoaded(nowPlayingID: id) == true }
    }

    /// Play from this clipping onwards, so the list behaves like every other list here rather
    /// than playing one item and stopping.
    /// The readings after it, never a book's chapters.
    private func play(_ item: ClippingStore.Item) {
        let songs = ClippingQueue.readings(from: item, in: filtered)
        guard !songs.isEmpty else { return }
        model.music.play(songs, source: clippingsSource)
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
                        if let origin = book.originText { Text(origin) }
                        if book.finished {
                            Text("Finished")
                            if let kept = book.keptUntilText { Text(kept) }
                        } else if book.listenedFraction > 0 {
                            Text("\(Int((book.listenedFraction * 100).rounded()))% heard")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if gettingPlace == book.documentID {
                        Text("Getting your place…").font(.caption).foregroundStyle(.secondary)
                    }
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
                // Quieter than a chapter row: only the bars, so a collapsed book still says one
                // of its chapters is playing, and the chapter row itself carries the tint.
                if isCurrent(book) && model.music.isPlaying {
                    NowPlayingBars(isPlaying: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { play(book) }
            .contextMenu {
                Button("Play") { play(book) }.disabled(book.chapters.allSatisfy { $0.item?.isPresent != true })
                Button("Read Along") { readingAlong = book }
                    .disabled(book.chapters.allSatisfy { $0.item?.isPresent != true })
                Button(expanded ? "Hide Chapters" : "Show Chapters") {
                    if expanded { expandedBooks.remove(book.documentID) } else { expandedBooks.insert(book.documentID) }
                }
                if let first = book.chapters.compactMap(\.item).first(where: \.isPresent) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([first.url]) }
                }
                Divider()
                Button("Export Audiobook…") { exportAudiobook(book) }
                    .disabled(exportLine != nil && !exportFailed || !canExport(book))
                if model.documents.canEditPronunciations(book) {
                    Button("Pronunciations…") { pronouncing = book }
                }
                if model.documents.canChangeVoice(book) {
                    Button("Change Voice…") { changingBook = book }
                }
                if book.canStopRemaking {
                    Button("Stop Making Again") { stopRemaking(book) }
                }
                storageMenu(book)
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
        let isCurrent = isCurrent(chapter.item)
        let isPlaying = isCurrent && model.music.isPlaying
        return HStack(spacing: 8) {
            // The bars take the chapter number's place while it plays, as in the queue.
            Group {
                if isPlaying {
                    NowPlayingBars(isPlaying: true)
                } else {
                    Text("\(chapter.index + 1)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, alignment: .trailing)
            Text(chapter.title).lineLimit(1)
                .foregroundStyle(isPlaying ? Color.accentColor : .primary)
            Spacer()
            Text(Self.chapterStateText(chapter)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 52)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .background(isCurrent ? Color.nowPlayingRowTint() : .clear)
        .contentShape(Rectangle())
        .opacity(chapter.item?.isPresent == true ? 1 : 0.6)
        .onTapGesture(count: 2) { play(book, fromChapter: chapter.index) }
        .contextMenu {
            Button("Play") { play(book, fromChapter: chapter.index) }.disabled(chapter.item?.isPresent != true)
            if documentsOn {
                let library = model.documents
                if chapter.state == .removed, let title = library.getBackTitle(book) {
                    Button(title) { getBack(book, chapters: [chapter.index]) }
                } else if chapter.item?.isPresent == true, library.stored(book).canGetBack {
                    Button("Remove Download") { offload(book, chapters: [chapter.index]) }
                }
            }
        }
    }

    // MARK: - Storage (M6.3, M6.5)

    /// Remove Download, Download Again or Render Again, and Keep, for a book's menu.
    @ViewBuilder
    private func storageMenu(_ book: BookShelf.Book) -> some View {
        let library = model.documents
        let stored = library.stored(book)
        Divider()
        if let title = library.getBackTitle(book) {
            Button(title) { getBack(book) }
        }
        if !stored.present.isEmpty, stored.canGetBack {
            Button("Remove Download") { offload(book) }
        }
        Toggle("Keep on This Mac", isOn: Binding(
            get: { library.cleanup.isKept(book.documentID) },
            set: { library.cleanup.setKeep($0, documentID: book.documentID) }
        ))
    }

    private func offload(_ book: BookShelf.Book, chapters: [Int]? = nil) {
        let bytes = model.documents.offload(book, chapters: chapters)
        guard bytes > 0 else { return }
        model.music.postToast("Download removed, \(BookStorage.sizeText(bytes)) freed", symbol: "internaldrive", seconds: 3)
    }

    private func getBack(_ book: BookShelf.Book, chapters: [Int]? = nil) {
        let library = model.documents
        Task {
            do { try await library.getBack(book, chapters: chapters) } catch {
                model.music.postToast("The book could not come back: \(error)", symbol: "exclamationmark.triangle", seconds: 4)
            }
        }
    }

    private func refreshSuggestion() {
        let library = model.documents
        suggestion = library.cleanup.suggestion(for: library.storedBooks,
                                                freeBytes: BookCleanup.freeBytes(at: URL(fileURLWithPath: NSHomeDirectory())))
    }

    private func suggestionTitle(_ suggestion: BookStorage.Suggestion) -> String? {
        guard suggestion.kind == .finishedBook, let id = suggestion.ids.first else { return nil }
        return model.documents.shelf.first { $0.documentID == id }?.title
    }

    /// Documents sent from the iPhone that wait here: those set aside with Not Now, and those
    /// that arrived while another sheet was open.
    private var sentBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sentItems) { item in
                HStack(spacing: 10) {
                    Image(systemName: "iphone.and.arrow.forward").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.record.title).font(.callout).lineLimit(1)
                        Text("Sent from \(item.record.fromDevice)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import…") {
                        model.documentInbox.reopen(item.id)
                        offerNextSent()
                    }
                    .disabled(sentImport != nil || importing != nil)
                    Button("Discard") { model.documentInbox.finish(item.id) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
        .accessibilityIdentifier("sent-from-iphone")
    }

    /// Open the next document sent from the iPhone, once no other sheet is open. A short pause
    /// lets a sheet that just closed finish leaving before the next one comes up.
    private func offerNextSent() {
        guard documentsOn, model.documentInbox.nextOffer != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard documentsOn, importing == nil, pronouncing == nil, sentImport == nil,
                  let next = model.documentInbox.nextOffer else { return }
            guard next.source != nil else { model.documentInbox.notNow(next.id); return }
            sentImport = next
        }
    }

    private func suggestionBanner(_ suggestion: BookStorage.Suggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            Text(BookStorage.suggestionText(suggestion, title: suggestionTitle(suggestion), device: "this Mac"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(suggestion.kind == .finishedBook ? "Keep" : "Not Now") { answer(.keep, suggestion) }
            if suggestion.kind == .finishedBook {
                Button("Always Do This") { answer(.always, suggestion) }
            }
            Button("Remove") { answer(.remove, suggestion) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
        .accessibilityIdentifier("storage-suggestion")
    }

    private func answer(_ answer: BookStorage.Answer, _ suggestion: BookStorage.Suggestion) {
        let library = model.documents
        let bytes = library.cleanup.answer(answer, to: suggestion, books: library.storedBooks)
        library.refresh()
        self.suggestion = nil
        switch answer {
        case .always:
            model.music.postToast(BookStorage.alwaysConfirmation(device: "this Mac"), symbol: "internaldrive", seconds: 6)
        case .remove where bytes > 0:
            model.music.postToast("Download removed, \(BookStorage.sizeText(bytes)) freed", symbol: "internaldrive", seconds: 3)
        default:
            break
        }
    }

    /// One line under the book: why it is waiting, or what it is making.
    static func statusLine(_ book: BookShelf.Book) -> (text: String, isProblem: Bool)? {
        if let reason = book.pauseReason {
            return ("Paused: \(reason). It carries on by itself when the voice server answers.", true)
        }
        if let failure = book.failure { return ("Stopped: \(failure)", true) }
        if let remaking = book.remaking { return (remaking, false) }
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

    /// "Making again in af_sky on Kokoro… 40%", for a kept reading read again.
    static func remakingLine(_ progress: ClippingRevoicer.Progress) -> String {
        "Making again in \(BookVoiceChanges.voiceLabel(progress.voice))… \(Int((progress.fraction * 100).rounded()))%"
    }

    private func stopRemaking(_ book: BookShelf.Book) {
        let library = model.documents
        Task {
            do { try await library.cancelVoiceChange(book) } catch {
                model.music.postToast("The book could not go back to its voice: \(error)", symbol: "exclamationmark.triangle", seconds: 4)
            }
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

    /// Play from the synced position, or from a chosen chapter. Picking a book up after a
    /// break offers "Previously…" first (M8.4); the book plays once that is answered.
    ///
    /// A Play that resumes fetches the other device's place first, for up to about two seconds,
    /// and starts from the merged ledger: a Mac that stayed in front never pulls on
    /// its own, and played from its own older place. A slow or unreachable gateway starts the
    /// book from the place here. A tap on another chapter starts that chapter at once.
    private func play(_ book: BookShelf.Book, fromChapter index: Int? = nil) {
        guard BookPlacePull.resumes(fromChapter: index, placeChapter: book.position?.chapterIndex),
              let pull = model.bookPlacePull else {
            playFromPlace(book, fromChapter: index)
            return
        }
        guard pullingPlace != book.documentID else { return }
        pullingPlace = book.documentID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if pullingPlace == book.documentID { gettingPlace = book.documentID }
        }
        Task { @MainActor in
            _ = await BookPlacePull.run(sync: pull)
            pullingPlace = nil
            gettingPlace = nil
            var fresh = book
            (fresh.position, fresh.finished) = BookPlacePull.place(of: book.documentID, in: store.ledger)
            playFromPlace(fresh, fromChapter: index)
        }
    }

    private func playFromPlace(_ book: BookShelf.Book, fromChapter index: Int? = nil) {
        if index == nil, documentsOn, !book.finished, book.position != nil {
            let prepared = BookText.preparedBook(for: book, library: model.documents)
            if recap.consider(book, prepared: prepared, lastPlayed: store.ledger.document(book.documentID)?.positionAt) { return }
        }
        startPlaying(book, fromChapter: index)
    }

    private func startPlaying(_ book: BookShelf.Book, fromChapter index: Int? = nil) {
        let (songs, start) = BookPlayback.queue(for: book, fromChapter: index)
        guard !songs.isEmpty else { return }
        model.music.play(songs, startAt: start, source: .init(label: book.title, kind: .liked, id: nil))
    }

    // MARK: - Previously… (M8.4)

    private var recapBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let offer = recap.offer {
                HStack(spacing: 10) {
                    Image(systemName: "text.book.closed").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Previously…").font(.callout.weight(.semibold))
                        switch recap.state {
                        case .offered:
                            Text(ResumeRecap.offerText(for: offer.book)).font(.callout)
                        case .writing:
                            Text("Writing the recap…").font(.callout)
                        case .speaking:
                            Text(recap.text ?? "").font(.callout).lineLimit(3)
                        case let .failed(why):
                            Text(why).font(.callout).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if recap.state == .offered {
                        Button("Just Play") { recap.dismiss(); startPlaying(offer.book) }
                        Button("Hear Recap") { hearRecap(offer.book) }.keyboardShortcut(.defaultAction)
                    } else if recap.state == .writing || recap.state == .speaking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Dismiss") { recap.dismiss() }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    private func hearRecap(_ book: BookShelf.Book) {
        Task {
            let routing = await VoiceSuggestions.liveRouting()
            await recap.hear(sources: routing.sources, executor: routing.executor,
                             speak: { text in await speakRecap(text) },
                             thenPlay: { startPlaying(book) })
        }
    }

    /// Say the recap through the app's speech path (the configured TTS host, else the built-in
    /// voice when fallback is on), and return once it has been said.
    private func speakRecap(_ text: String) async -> Bool {
        let engine = model.speech
        let voice = SpeechConfig.resolve(category: nil, explicitVoice: nil, engineOverride: nil)
        do {
            let audio = try await SpeechService.synthesize(text: text, voice: voice)
            engine.play(fileURL: try BatonMCPSpeakTools.writeTemp(audio), text: text)
        } catch {
            guard SpeechConfig.fallbackEnabled else { return false }
            engine.speakNative(text)
        }
        let started = Date()
        while !engine.isSpeaking, Date().timeIntervalSince(started) < 5 { try? await Task.sleep(for: .milliseconds(100)) }
        while engine.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
        return true
    }

    // MARK: - Export Audiobook… (M8.8)

    /// Every chapter here, or a book the home server holds whole.
    private func canExport(_ book: BookShelf.Book) -> Bool {
        if model.documents.job(forDocument: book.documentID)?.renderer == .homeServer { return !book.isRendering }
        return !book.chapters.isEmpty && book.chapters.allSatisfy { $0.item?.isPresent == true }
    }

    private func exportAudiobook(_ book: BookShelf.Book) {
        let panel = NSSavePanel()
        panel.title = "Export Audiobook"
        panel.nameFieldStringValue = AudiobookExporter.fileName(title: book.title, author: book.author)
        panel.allowedContentTypes = [UTType(filenameExtension: "m4b") ?? .mpeg4Audio]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await runExport(book, to: url) }
        }
    }

    private func runExport(_ book: BookShelf.Book, to url: URL) async {
        exportFailed = false
        exportLine = "Exporting \(book.title)…"
        do {
            let library = model.documents
            if let job = library.job(forDocument: book.documentID), job.renderer == .homeServer {
                guard let client = DocumentLibrary.configuredGateway() else { throw DocumentLibrary.HomeServerError.notConfigured }
                // Only the file named in the save panel is written (replaced if the person
                // confirmed that there); the server's own file name is never used here.
                _ = try await client.exportAudiobook(job.id, to: url)
            } else {
                let files = try AudiobookExporter.chapterFiles(book)
                let job = library.job(forDocument: book.documentID).flatMap { library.store.load($0.id) }
                guard let marks = AudiobookExporter.marks(book, job: job) else { throw AudiobookExporter.ExportError.noChapters }
                let outcome = try await AudiobookExporter.export(chapters: files, marks: marks, title: book.title, author: book.author, to: url)
                if !outcome.hasMarks {
                    exportFailed = true   // shown in orange with Dismiss; the file is there
                    exportLine = "Exported without chapter marks: they need ffmpeg on this Mac (brew install ffmpeg)."
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    return
                }
            }
            exportLine = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportFailed = true
            exportLine = "The audiobook could not be exported: \(error)."
        }
    }

    /// Stop making the book and remove its chapters, here or everywhere. The audio waits a week
    /// in Recently removed (M6.3), so a mistaken delete can be restored.
    private func deleteBook(_ book: BookShelf.Book, everywhere: Bool) {
        let library = model.documents
        let digests = everywhere ? book.chapters.compactMap { $0.item?.clipping.sha256 } : []
        Task {
            await library.deleteBook(book, everywhere: everywhere)
            for digest in digests { removeSharedCopy(digest) }
        }
        expandedBooks.remove(book.documentID)
        model.music.postToast("Moved to Recently removed. Restore it within a week from Settings, under Storage.",
                              symbol: "trash", seconds: 4)
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
