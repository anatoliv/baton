import BatonDocuments
import BatonPlaybackKit
import BatonSpeech
import BatonSubsonicKit
import BatonSubsonicModels
import SwiftUI
import UniformTypeIdentifiers

/// **Books**: narrated books made from documents, in a section of their own.
///
/// Books and kept readings used to share one Clippings list, a book being one row that opened
/// into its chapters. The owner gave books their own place on 2026-10-16: a book behaves like a
/// library item, with chapters, progress, a narrator, read-along, Change Voice and storage
/// rules, while Clippings keeps the short saved readings that play one after another.
///
/// The list shows one row per book; opening a row shows the book: its chapters, Play or Resume,
/// Read Along, Change Voice and the storage actions. The rows, the chapter rows and every action
/// are the ones Clippings had, moved here rather than copied. Imports (File, Import Document;
/// a drop; Open With; the Services item; a document sent from the iPhone) land here.
///
/// A chapter plays through the ordinary player, as a clipping does: its id is its file URL, so
/// the transport, the now-playing bar, the queue and the scrubber need no second path.
struct MusicBooksView: View {
    @Environment(MusicModel.self) private var model
    @Environment(BatonCommandRouter.self) private var router: BatonCommandRouter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var filterText = ""
    @FocusState private var filterFocused: Bool
    /// The book shown in full, by document id. Opened from a row, closed with the back button.
    @State private var openBookID: String?
    /// A file to import, from Import Document… or a drop (document clippings, M3.4).
    @State private var importing: URL?
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
    /// The book whose voice is being changed.
    @State private var changingBook: BookShelf.Book?
    /// An export in progress, or why the last one failed (M8.8).
    @State private var exportLine: String?
    @State private var exportFailed = false
    /// The weekly storage suggestion, while it is on offer (M6.5).
    @State private var suggestion: BookStorage.Suggestion?
    /// A document sent from the iPhone, open in the import sheet.
    @State private var sentImport: DocumentInbox.Item?

    private var store: ClippingStore { model.clippings }

    /// `baton.documents.enabled`, read live, so the rows, the drop target and the import line
    /// follow the Settings switch at once.
    private var documentsOn: Bool { model.documentsSwitch.isOn }

    private var search: ClippingSearch { model.clippingSearch }

    /// Book covers, while Documents is on.
    private var covers: BookCovers? { documentsOn ? model.documents.covers : nil }

    /// Render jobs, so a book shows from the moment it is submitted, while Documents is on.
    private var jobs: [DocumentLibrary.Job] { documentsOn ? model.documents.jobs : [] }

    /// Every book: those whose chapters are here, and those still being made.
    private var allBooks: [BookShelf.Book] {
        Self.books(BookShelf.entries(items: store.items.filter(\.clipping.isBookChapter), jobs: jobs,
                                     ledger: store.ledger,
                                     changes: documentsOn ? model.documents.voiceChanges.all : []))
    }

    /// The books the list shows. While filtering, a book is matched by its title or author, or
    /// by what is said in any of its chapters, through the shared search index (M8.9), which
    /// ignores case and accents.
    private var books: [BookShelf.Book] {
        let all = allBooks
        guard search.isFiltering else { return all }
        let heard = Set(search.filter(store.items).filter(\.clipping.isBookChapter).compactMap(\.clipping.documentID))
        return all.filter { book in
            heard.contains(book.documentID) || search.matches(title: book.title)
                || (book.author.map { search.matches(title: $0) } ?? false)
        }
    }

    /// The open book, unfiltered, so a filter never hides a chapter of the book in front of you.
    private var openBook: BookShelf.Book? {
        guard let openBookID else { return nil }
        let chapters = store.items.filter { $0.clipping.documentID == openBookID && $0.clipping.isBookChapter }
        return Self.books(BookShelf.entries(items: chapters, jobs: jobs.filter { $0.documentID == openBookID },
                                            ledger: store.ledger,
                                            changes: documentsOn ? model.documents.voiceChanges.all : [])).first
    }

    static func books(_ entries: [BookShelf.Entry]) -> [BookShelf.Book] {
        entries.compactMap { if case let .book(book) = $0 { book } else { nil } }
    }

    /// Documents sent from the iPhone and waiting here, while Documents is on.
    private var sentItems: [DocumentInbox.Item] { documentsOn ? model.documentInbox.items : [] }

    var body: some View {
        Group {
            if let book = openBook {
                detail(book)
            } else if books.isEmpty && !search.isFiltering && sentItems.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    MusicBrowseHeader(
                        title: "Books",
                        count: books.count,
                        filter: $filterText,
                        filterPrompt: "Filter books",
                        filterFocused: $filterFocused,
                        filterHistoryKey: "books",
                        layout: .constant(.list),
                        showsLayoutPicker: false,
                        accessory: { EmptyView() },
                        leading: { MusicMiniTransport() },
                        sortMenu: { EmptyView() }
                    )
                    banners
                    list
                }
            }
        }
        .task { store.loadIfNeeded() }
        .bookCoverFinder(covers)
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
        // DEBUG only: `scripts/probe-books-section.sh` opens the first book, in place
        // of clicking its row in an app that shares its bundle id with the owner's. By
        // environment, never argv.
        .task {
            guard ProcessInfo.processInfo.environment["BATON_DEBUG_OPEN_BOOK"] == "1" else { return }
            for _ in 0..<240 {
                if let first = books.first {
                    openBookID = first.documentID
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // DEBUG only: `scripts/probe-change-voice.sh` opens Change Voice… for the
        // first book whose chapters are all here, in place of a row's context menu. By
        // environment, never argv. A kept reading's Change Voice is in Clippings.
        .task {
            guard ProcessInfo.processInfo.environment["BATON_DEBUG_OPEN_CHANGE_VOICE"] == "book" else { return }
            for _ in 0..<240 {
                if documentsOn, let book = model.documents.shelf.first(where: { book in
                    !book.chapters.isEmpty && book.chapters.allSatisfy { $0.item != nil } && model.documents.canChangeVoice(book)
                }) {
                    changingBook = book
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
        // A deleted book closes rather than leaving an empty page behind.
        .onChange(of: openBookID != nil && openBook == nil) { _, gone in if gone { openBookID = nil } }
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
        // after launch, which can be after Books appeared. Asking again keeps the
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
    }

    // MARK: - The list

    @ViewBuilder
    private var banners: some View {
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
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(books) { book in
                    bookRow(book)
                    Divider().padding(.leading, 52)
                }
                if books.isEmpty {
                    Text("No books match “\(filterText)”.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// One book: its cover mark, title, author, how far along it is and where it was made.
    /// A click opens it; the menu holds everything the open book offers.
    private func bookRow(_ book: BookShelf.Book) -> some View {
        Button { openBookID = book.documentID } label: { bookRowLabel(book) }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the book")
            .contextMenu {
                Button("Open") { openBookID = book.documentID }
                Button(mainAction(book).title) { performMain(book) }.disabled(!canPlay(book))
                Button("Read Along") { readingAlong = book }.disabled(!canPlay(book))
                bookMenu(book)
            }
    }

    private func bookRowLabel(_ book: BookShelf.Book) -> some View {
        HStack(spacing: 12) {
            BookCoverArt(covers: covers, documentID: book.documentID, side: 40, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).lineLimit(1)
                HStack(spacing: 6) {
                    if let author = book.author, !author.isEmpty { Text(author) }
                    Text(book.summaryText)
                    Text(book.storedText)
                    if let origin = book.originText { Text(origin) }
                    BookHeard(book: book, part: .words)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                statusLines(book)
                BookHeard(book: book, part: .bar(maxWidth: 240, mini: true))
            }
            Spacer()
            // The bars alone, so the list still says one of this book's chapters is playing;
            // the chapter row inside the book carries the tint.
            if isCurrent(book) && model.music.isPlaying {
                NowPlayingBars(isPlaying: true)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusLines(_ book: BookShelf.Book) -> some View {
        if gettingPlace == book.documentID {
            Text("Getting your place…").font(.caption).foregroundStyle(.secondary)
        }
        if let status = Self.statusLine(book) {
            Text(status.text)
                .font(.caption)
                .foregroundStyle(status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(2)
        }
    }

    /// The actions a book offers beyond Play and Read Along, the same in its row's menu and
    /// in the open book's More menu.
    @ViewBuilder
    private func bookMenu(_ book: BookShelf.Book) -> some View {
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
        if let covers {
            Divider()
            BookCoverMenu(covers: covers, book: book)
        }
        Divider()
        Button("Delete Book…", role: .destructive) { pendingBookDelete = book }
    }

    // MARK: - An open book

    /// The book in full: what it is and how far along, Play or Resume, Read Along, Change Voice,
    /// its storage, and its chapters.
    private func detail(_ book: BookShelf.Book) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { openBookID = nil } label: {
                    Label("Books", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Books (⌘[)")
                .accessibilityIdentifier("books-back")
                Spacer()
                MusicMiniTransport()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            banners
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader(book)
                        .padding(.horizontal, 18).padding(.vertical, 16)
                    Divider()
                    Text("Chapters")
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                    LazyVStack(spacing: 0) {
                        ForEach(book.chapters) { chapter in
                            chapterRow(book, chapter)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func detailHeader(_ book: BookShelf.Book) -> some View {
        HStack(alignment: .top, spacing: 18) {
            BookCoverArt(covers: covers, documentID: book.documentID, side: 104, cornerRadius: 10, glyphSize: 40)
            .overlay(alignment: .bottomTrailing) {
                if isCurrent(book) && model.music.isPlaying {
                    NowPlayingBars(isPlaying: true).padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.title2.weight(.semibold)).lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(book.summaryText)
                    if let origin = book.originText { Text(origin) }
                    BookHeard(book: book, part: .words)
                }
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                BookHeard(book: book, part: .bar(maxWidth: 280, mini: false))
                statusLines(book)

                HStack(spacing: 8) {
                    // Pause or Resume while this book is in the player, else Play or Resume from
                    // its place, with the transports' play/pause morph.
                    let action = mainAction(book)
                    Button { performMain(book) } label: {
                        Label {
                            Text(action.title)
                        } icon: {
                            Image(systemName: action.symbol)
                                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: action)
                    .disabled(!canPlay(book))
                    .accessibilityIdentifier("book-play")
                    Button { readingAlong = book } label: {
                        Label("Read Along", systemImage: "text.book.closed")
                    }
                    .disabled(!canPlay(book))
                    if model.documents.canChangeVoice(book) {
                        Button { changingBook = book } label: {
                            Label("Change Voice…", systemImage: "person.wave.2")
                        }
                    }
                    Menu {
                        bookMenu(book)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .fixedSize()
                    .accessibilityIdentifier("book-more")
                }
                .padding(.top, 6)

                storageLine(book).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    /// Where the book's audio is, and the storage actions right beside it (M6.3).
    private func storageLine(_ book: BookShelf.Book) -> some View {
        let library = model.documents
        let stored = library.stored(book)
        return HStack(spacing: 10) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            Text(book.storedText).font(.callout).foregroundStyle(.secondary)
            if documentsOn {
                if let title = library.getBackTitle(book) {
                    Button(title) { getBack(book) }.controlSize(.small)
                }
                if !stored.present.isEmpty, stored.canGetBack {
                    Button("Remove Download") { offload(book) }.controlSize(.small)
                }
                Toggle("Keep on This Mac", isOn: Binding(
                    get: { library.cleanup.isKept(book.documentID) },
                    set: { library.cleanup.setKeep($0, documentID: book.documentID) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
        }
    }

    private func chapterRow(_ book: BookShelf.Book, _ chapter: BookShelf.Chapter) -> some View {
        let isCurrent = isCurrent(chapter.item)
        let isPlaying = isCurrent && model.music.isPlaying
        // Toggled only while the book is the collection in the player (the shared rule); run
        // to its end, it plays again.
        let toggles = isCurrent && model.music.collectionState(Self.source(book)).isLoaded
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
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(isCurrent ? Color.nowPlayingRowTint() : .clear)
        .contentShape(Rectangle())
        .opacity(chapter.item?.isPresent == true ? 1 : 0.6)
        .onTapGesture(count: 2) { tapChapter(book, chapter, isCurrent: toggles) }
        .contextMenu {
            Button(BookTransport.chapterTap(isCurrentChapter: toggles, isPlaying: model.music.isPlaying)?.title ?? "Play") {
                tapChapter(book, chapter, isCurrent: toggles)
            }
            .disabled(chapter.item?.isPresent != true)
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

    // MARK: - Playing

    /// Whether this chapter is the one loaded in the player, playing or paused.
    private func isCurrent(_ item: ClippingStore.Item?) -> Bool {
        item?.isLoaded(nowPlayingID: model.music.nowPlaying?.id) == true
    }

    /// Whether one of this book's chapters is the one loaded in the player.
    private func isCurrent(_ book: BookShelf.Book) -> Bool {
        guard let id = model.music.nowPlaying?.id else { return false }
        return book.chapters.contains { $0.item?.isLoaded(nowPlayingID: id) == true }
    }

    private func canPlay(_ book: BookShelf.Book) -> Bool {
        book.chapters.contains { $0.item?.isPresent == true }
    }

    /// The source this book plays under, so the shared collection rule knows it.
    static func source(_ book: BookShelf.Book) -> StreamingPlaybackController.QueueSource {
        BookTransport.source(documentID: book.documentID, title: book.title)
    }

    /// The main button, from the shared collection rule: the player's
    /// Pause or Resume while this book is the collection in it, else Resume from the book's
    /// place, or Play.
    private func mainAction(_ book: BookShelf.Book) -> BookTransport.Action {
        BookTransport.action(model.music.collectionState(Self.source(book)),
                             finished: book.finished, hasPosition: book.position != nil)
    }

    /// Toggle the player for the book in it; queue any other book from its place. A book in the
    /// player is never queued again: its saved place trails the playhead by up to five seconds,
    /// so that jumped it back, and it offered "Previously…" in the middle of listening.
    private func performMain(_ book: BookShelf.Book) {
        if !model.music.toggleIfLoaded(Self.source(book)) { play(book) }
    }

    /// A double-click (or the menu's first item) on a chapter row: the chapter in the player
    /// pauses or carries on; any other plays the book from there.
    private func tapChapter(_ book: BookShelf.Book, _ chapter: BookShelf.Chapter, isCurrent: Bool) {
        switch BookTransport.chapterTap(isCurrentChapter: isCurrent, isPlaying: model.music.isPlaying) {
        case .pause?: model.music.pause()
        case .resumePlayer?: model.music.resume()
        default: play(book, fromChapter: chapter.index)
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
        model.music.play(songs, startAt: start, source: Self.source(book))
    }

    // MARK: - Imports

    private func takePendingImport() {
        guard documentsOn, let url = router?.pendingDocumentImport else { return }
        router?.pendingDocumentImport = nil
        openBookID = nil
        importing = url
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
        let music = model.music
        Task {
            await library.deleteBook(book, everywhere: everywhere)
            for digest in digests { ClippingSharedCopy.remove(digest, music: music) }
        }
        if openBookID == book.documentID { openBookID = nil }
        model.music.postToast("Moved to Recently removed. Restore it within a week from Settings, under Storage.",
                              symbol: "trash", seconds: 4)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No books yet").font(.headline)
            Text(documentsOn
                 ? "Choose File → Import Document to hear a PDF, EPUB, web page or text file as a "
                    + "narrated book, or drop one here. Each book keeps its chapters, your place and "
                    + "its narrator, and plays with no server and no network once it is made."
                 : "Turn on Documents in Settings, under Speech, to make narrated books from PDFs, "
                    + "EPUBs, web pages and text files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// How far through a book the listener is: "12% heard" or "Finished", and the bar.
///
/// From the live playhead while one of the book's chapters is in the player, else from the
/// saved place. The saved place lives in the shared ledger, which `ClippingStore` keeps in
/// UserDefaults behind a computed property that observation does not see, so a view reading it
/// alone never redrew while the book played: the owner saw "0% heard" ten minutes in. A view of
/// its own, so only this redraws with the playhead, four times a second, and only for the book
/// in the player.
private struct BookHeard: View {
    enum Part { case words, bar(maxWidth: CGFloat, mini: Bool) }

    @Environment(MusicModel.self) private var model
    let book: BookShelf.Book
    let part: Part

    var body: some View {
        let loaded = model.music.collectionState(MusicBooksView.source(book)).isLoaded
            ? book.loadedChapter(nowPlayingID: model.music.nowPlaying?.id) : nil
        let place = BookTransport.place(loadedChapter: loaded, playhead: loaded == nil ? 0 : model.music.currentTime,
                                        saved: book.position)
        let fraction = book.listenedFraction(at: place, live: loaded != nil)
        let finished = book.finished && loaded == nil
        switch part {
        case .words:
            if finished {
                Text("Finished")
                if let kept = book.keptUntilText { Text(kept) }
            } else if fraction > 0 {
                Text(BookTransport.heardText(fraction))
            }
        case let .bar(maxWidth, mini):
            if fraction > 0 && !finished {
                ProgressView(value: fraction)
                    .controlSize(mini ? .mini : .regular)
                    .frame(maxWidth: maxWidth)
                    .accessibilityLabel("Heard")
                    .accessibilityIdentifier("book-heard-bar")
            }
        }
    }
}

/// Drop a PDF, text or Markdown file onto Books to import it. Only while the feature flag is
/// on, so nothing changes for anyone else.
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
