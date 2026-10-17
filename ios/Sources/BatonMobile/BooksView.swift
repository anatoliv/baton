import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import BatonSubsonicModels
import SwiftUI
import UniformTypeIdentifiers

/// **Books** on the phone: narrated books made from documents, in a Library section
/// of their own, next to Clippings.
///
/// Books and kept readings used to share the Clippings list, a book being a disclosure row over
/// its chapters. The owner gave books their own place on 2026-10-16: a book behaves like a
/// library item, with chapters, progress, a narrator, read-along, Change Voice and storage rules,
/// while Clippings keeps the short saved readings.
///
/// One view in two modes, so the rows, the chapter rows and every action are the ones Clippings
/// had, moved rather than copied: with no `openBook` it is the list (a row per book, the import
/// menu, the weekly storage suggestion); with one it is that book (its chapters, Play or Resume,
/// Read Along, Change Voice and the storage actions), pushed from the list's row.
///
/// A chapter plays through the ordinary player, as a clipping does, so the now-playing bar, the
/// queue and the sleep timer need no second path.
struct BooksView: View {
    let model: MobileModel
    /// The book this screen shows, by document id; nil for the list.
    var openBook: String?

    @State private var status: String?
    @State private var filter = ""
    /// The book whose Play is fetching the Mac's place first, and the one showing
    /// "Getting your place…" once that wait is long enough to notice.
    @State private var pullingPlace: String?
    @State private var gettingPlace: String?
    @State private var choosingFile = false
    @State private var askingForLink = false
    @State private var linkText = ""
    /// The weekly storage suggestion, while it is on offer (M6.5).
    @State private var suggestion: BookStorage.Suggestion?
    /// A book waiting for "Delete this book?" (M6.3: it goes to Recently removed for a week).
    @State private var pendingBookDelete: MobileBookShelf.Book?
    /// The book whose voice is being changed.
    @State private var changingVoice: MobileBookShelf.Book?
    @State private var showsReadAlong = false
    /// "Previously…": offered by Play on a book last heard more than a day ago.
    @State private var recap = MobileRecapOffer()
    @State private var recapSpeaker = MobileRecapSpeaker()
    @Environment(\.dismiss) private var dismiss

    private var store: ClippingStore { model.clippings }
    /// Book covers, while Documents is on.
    private var covers: BookCovers? { documentsOn ? model.covers : nil }
    /// Read live through the model's switch, so turning Documents off in Settings hides the
    /// books and the import menu at once.
    private var documentsOn: Bool { model.documentsSwitch.isOn }

    /// Each book once, from what has landed and what the home server says (M5.3). While
    /// filtering, a book is matched by its title or author, or by what its chapters say, through
    /// the shared search index (M8.9): case and accents are ignored.
    private var books: [MobileBookShelf.Book] {
        guard documentsOn else { return [] }
        let all = model.shelfBooks
        let search = model.clippingSearch
        guard openBook == nil, search.isFiltering else { return all }
        let heard = Set(search.filter(store.items).filter(\.clipping.isBookChapter).compactMap(\.clipping.documentID))
        return all.filter { book in
            heard.contains(book.documentID) || search.matches(title: book.title)
                || (book.author.map { search.matches(title: $0) } ?? false)
        }
    }

    /// The open book, unfiltered.
    private var book: MobileBookShelf.Book? {
        guard let openBook, documentsOn else { return nil }
        return model.shelfBooks.first { $0.documentID == openBook }
    }

    var body: some View {
        Group {
            if openBook != nil {
                detailScreen
            } else {
                listScreen
            }
        }
        .task {
            BooksWatch.appeared()
            store.loadIfNeeded()
            // Collect on open rather than on a timer, as Clippings does: kept chapters the Mac
            // made, and the home server's books.
            if let message = await ClippingCollection.collect(model: model) { show(message) }
            await model.collectBooks()
            // A book still being made is worth asking about every few seconds while it is on
            // screen: its row says what the home server is doing.
            model.books.watchIfNeeded { }
            if documentsOn, openBook == nil {
                model.applyStorageRules()
                refreshSuggestion()
            }
        }
        .onDisappear { BooksWatch.disappeared(model: model) }
        .onChange(of: documentsOn) { _, on in
            if on { refreshSuggestion() } else { suggestion = nil }
        }
        .confirmationDialog("Delete this book?", isPresented: .init(
            get: { pendingBookDelete != nil },
            set: { if !$0 { pendingBookDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Remove from this iPhone", role: .destructive) { deleteBook(everywhere: false) }
            Button("Delete Everywhere", role: .destructive) { deleteBook(everywhere: true) }
            Button("Cancel", role: .cancel) { pendingBookDelete = nil }
        } message: {
            Text("Its chapters leave this iPhone, and the Baton server keeps it for your other devices. "
                 + "Deleting everywhere also removes it from the Baton server and your other devices. For a week you can restore it from Recently "
                 + "removed in Settings, under Storage.")
        }
        .sheet(item: $changingVoice) { book in
            ChangeVoiceScreen(book: book, model: model) { changingVoice = nil }
        }
        .sheet(isPresented: $showsReadAlong) {
            MobileReadAlongSheet(model: model)
        }
        .bookCoverSheets(covers)
        .overlay(alignment: .bottom) {
            if let status {
                Text(status)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: status)
    }

    // MARK: - The list

    private var listScreen: some View {
        List {
            if books.isEmpty {
                Section {
                    if model.clippingSearch.isFiltering && documentsOn && !model.shelfBooks.isEmpty {
                        ContentUnavailableView.search(text: filter)
                    } else {
                        ContentUnavailableView(
                            "No books yet",
                            systemImage: "books.vertical",
                            description: Text(documentsOn
                                ? "Open a PDF, EPUB or text file in Baton from Files or the share sheet, or tap + to import a file or a link, and your Baton server reads it to you here."
                                : "Turn on Documents in Settings to make narrated books from PDFs, EPUBs, web pages and text files.")
                        )
                    }
                }
            } else {
                if recap.offer != nil {
                    Section { recapCard }
                }
                if let suggestion {
                    Section { suggestionCard(suggestion) }
                }
                Section {
                    ForEach(books) { book in
                        NavigationLink {
                            BooksView(model: model, openBook: book.documentID)
                        } label: {
                            bookRow(book)
                        }
                        .accessibilityIdentifier("book-\(book.documentID)")
                        .contextMenu { bookMenu(book) }
                    }
                }
            }
        }
        .navigationTitle("Books")
        .searchable(text: $filter, prompt: "Filter books")
        .onChange(of: filter, initial: true) { _, text in
            model.clippingSearch.follow(store)
            model.clippingSearch.setQuery(text)
        }
        // Pulled by hand, so say what happened.
        .refreshable {
            if let message = await ClippingCollection.collect(model: model, announcing: true) { show(message) }
            await model.collectBooks()
        }
        .toolbar {
            if documentsOn {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            #if DEBUG
                            if let picked = MobileDocuments.uitestPickedFile() { importPicked(picked); return }
                            #endif
                            choosingFile = true
                        } label: { Label("Import a File…", systemImage: "doc") }
                        Button { linkText = ""; askingForLink = true } label: { Label("Import a Link…", systemImage: "link") }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Import a document")
                        .accessibilityIdentifier("import-document")
                }
            }
            sleepTimerItem
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: MobileDocuments.importableTypes) { result in
            switch result {
            case let .success(url): importPicked(url)
            case .failure: break
            }
        }
        .alert("Import a Link", isPresented: $askingForLink) {
            TextField("https://", text: $linkText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {}
            Button("Import") {
                let raw = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
                let withScheme = raw.contains("://") ? raw : "https://\(raw)"
                if let url = URL(string: withScheme), MobileDocuments.isWebLink(url) {
                    model.offerImport(url)
                } else {
                    show("That is not a web address")
                }
            }
        } message: {
            Text("The page is read as an article and made into a book on your Baton server.")
        }
    }

    /// One book: its mark, title, author, how far along it is and where it was made.
    private func bookRow(_ book: MobileBookShelf.Book) -> some View {
        HStack(spacing: 12) {
            BookCoverArt(covers: covers, documentID: book.documentID, side: 44, cornerRadius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).lineLimit(1)
                HStack(spacing: 6) {
                    if let author = book.author, !author.isEmpty { Text(author) }
                    Text(book.summaryText)
                    Text(book.storedText)
                    MobileBookHeard(model: model, book: book, part: .words)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let origin = book.originText {
                    Text(origin).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                statusLines(book)
                MobileBookHeard(model: model, book: book, part: .bar(maxWidth: 200))
            }
            // The bars alone, so the list still says one of this book's chapters is the one
            // playing; the chapter row inside the book carries the accent.
            if isCurrent(book) {
                Spacer(minLength: 6)
                NowPlayingBars(isPlaying: barsArePlaying)
            }
        }
        .accessibilityValue(isCurrent(book) ? (barsArePlaying ? "Now playing" : "Paused") : "")
    }

    @ViewBuilder
    private func statusLines(_ book: MobileBookShelf.Book) -> some View {
        if gettingPlace == book.documentID {
            Text("Getting your place…").font(.caption).foregroundStyle(.secondary)
        }
        if let line = book.statusLine {
            Text(line.text).font(.caption)
                .foregroundStyle(line.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(2)
        }
    }

    /// The row's long-press menu: what the open book offers, without opening it.
    @ViewBuilder
    private func bookMenu(_ book: MobileBookShelf.Book) -> some View {
        Button(mainAction(book).title) { performMain(book) }.disabled(book.readyChapters.isEmpty)
        storageActions(book)
        Toggle("Keep on This iPhone", isOn: keepBinding(book))
        changeVoiceActions(book)
        // Wake to the book, from where it was left.
        if let choice = alarmChoice(book) {
            Section { AlarmMenuItems(choice: choice) }
        }
        if let covers {
            Section("Cover") { BookCoverMenu(covers: covers, book: book) }
        }
    }

    /// The book as an alarm plays it: its chapters from the synced place. At the time the
    /// alarm re-reads the place, so it resumes where the book was left by then.
    private func alarmChoice(_ book: MobileBookShelf.Book) -> AlarmChoice? {
        let (songs, start) = MobileBookShelf.queue(for: book)
        guard !songs.isEmpty else { return nil }
        return AlarmChoice(title: book.title, subtitle: book.author, kind: .book, songs: songs, startIndex: start,
                           source: Self.source(book))
    }

    // MARK: - An open book

    @ViewBuilder
    private var detailScreen: some View {
        if let book {
            List {
                Section { detailHeader(book) }
                if recap.offer != nil {
                    Section { recapCard }
                }
                Section {
                    ForEach(book.chapters) { chapter in
                        chapterRow(book, chapter)
                    }
                } header: {
                    Text("Chapters")
                }
                Section {
                    HStack {
                        Label(book.storedText, systemImage: "internaldrive")
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    storageActions(book)
                    Toggle("Keep on This iPhone", isOn: keepBinding(book))
                } header: {
                    Text("Storage")
                }
                Section {
                    changeVoiceActions(book)
                }
            }
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(SolidTopEdge())
            .toolbar { sleepTimerItem }
        } else {
            // Deleted, or Documents turned off, while it was open.
            ContentUnavailableView("This book is gone", systemImage: "books.vertical",
                                   description: Text("It was deleted or removed from this iPhone."))
                .navigationTitle("Books")
        }
    }

    private func detailHeader(_ book: MobileBookShelf.Book) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Menu {
                    if let covers { BookCoverMenu(covers: covers, book: book) }
                } label: {
                    BookCoverArt(covers: covers, documentID: book.documentID, side: 76, cornerRadius: 10, glyphSize: 32)
                }
                .disabled(covers == nil)
                .accessibilityLabel("Cover")
                .accessibilityHint("Find, make, choose or remove this book's cover")
                .accessibilityIdentifier("cover-menu")
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent(book) { NowPlayingBars(isPlaying: barsArePlaying).padding(6) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title).font(.headline).lineLimit(3)
                    if let author = book.author, !author.isEmpty {
                        Text(author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(book.summaryText)
                        MobileBookHeard(model: model, book: book, part: .words)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let origin = book.originText {
                        Text(origin).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            MobileBookHeard(model: model, book: book, part: .bar(maxWidth: nil))
            statusLines(book)
            // Side by side, one line each and the same size, while both fit; stacked, full width,
            // when the text is too large for that or the screen too narrow (TBX-11063: "Read
            // Along" wrapped to two lines beside a one-line "Resume").
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { mainButton(book); readAlongButton(book) }
                VStack(spacing: 10) { mainButton(book); readAlongButton(book) }
            }
            .controlSize(.large)
        }
        .padding(.vertical, 4)
    }

    /// Pause or Resume while this book is in the player, else Play or Resume from its place
    ///, with the play/pause morph the player's own button has.
    private func mainButton(_ book: MobileBookShelf.Book) -> some View {
        let action = mainAction(book)
        return Button { performMain(book) } label: {
            BookActionLabel(title: action.title, symbol: action.symbol)
        }
        .buttonStyle(.borderedProminent)
        .disabled(book.readyChapters.isEmpty)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("book-play")
    }

    private func readAlongButton(_ book: MobileBookShelf.Book) -> some View {
        Button { readAlong(book) } label: {
            BookActionLabel(title: "Read Along", symbol: "text.book.closed")
        }
        .buttonStyle(.bordered)
        .disabled(book.readyChapters.isEmpty)
        .accessibilityLabel("Read Along")
        .accessibilityIdentifier("book-read-along")
    }

    private func chapterRow(_ book: MobileBookShelf.Book, _ chapter: MobileBookShelf.Book.Chapter) -> some View {
        let current = isCurrent(chapter.item)
        return Button {
            // The chapter in the player pauses or carries on, as a playing music row does;
            // queuing it again jumped it back to its last saved place.
            // Only while the book is the collection in the player (the shared rule); run to
            // its end, it plays again.
            let toggles = current && model.music.collectionState(Self.source(book)).isLoaded
            switch BookTransport.chapterTap(isCurrentChapter: toggles, isPlaying: model.music.isPlaying) {
            case .pause?: model.music.pause()
            case .resumePlayer?: model.music.resume()
            default: play(book, fromChapter: chapter.index)
            }
        } label: {
            HStack(spacing: 8) {
                // The bars take the chapter number's place, as in the queue.
                Group {
                    if current {
                        NowPlayingBars(isPlaying: barsArePlaying)
                    } else {
                        Text("\(chapter.index + 1)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24, alignment: .trailing)
                Text(chapter.title).lineLimit(1)
                    .foregroundStyle(current ? Color.accentColor : .primary)
                Spacer()
                Text(chapter.stateText).font(.caption).foregroundStyle(.secondary)
            }
            // The whole row plays: a plain button's Spacer takes no taps, so a tap between the
            // title and the length did nothing (found by BookRowsUITests, M5.3).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(chapter.item?.isPresent != true)
        .opacity(chapter.item?.isPresent == true ? 1 : 0.6)
        .accessibilityValue(current ? (barsArePlaying ? "Now playing" : "Paused") : "")
    }

    // MARK: - Actions shared by the row's menu and the open book

    @ViewBuilder
    private func storageActions(_ book: MobileBookShelf.Book) -> some View {
        if let title = model.getBackTitle(book) {
            Button(title) { getBack(book) }
        }
        if !book.readyChapters.isEmpty, model.stored(book).canGetBack {
            Button("Remove Download") { offload(book) }
        }
    }

    private func keepBinding(_ book: MobileBookShelf.Book) -> Binding<Bool> {
        Binding(get: { model.bookCleanup.isKept(book.documentID) },
                set: { model.bookCleanup.setKeep($0, documentID: book.documentID) })
    }

    /// Change Voice…, Stop Making Again or Stop Making This Book, and Delete Book….
    @ViewBuilder
    private func changeVoiceActions(_ book: MobileBookShelf.Book) -> some View {
        // Made again in another voice by the home server, from the shaped book kept
        // beside the record.
        if let jobID = book.jobID, model.books.hasPreparedBook(forJob: jobID) {
            Button("Change Voice…") { changingVoice = book }
        }
        if book.canStopRemaking {
            Button("Stop Making Again") { stopRemaking(book) }
        } else if let jobID = book.jobID, book.isRendering, book.remaking == nil {
            Button("Stop Making This Book", role: .destructive) {
                Task { await model.books.cancel(jobID: jobID) }
            }
        } else if !book.readyChapters.isEmpty || !book.missing.isEmpty {
            // Delete Everywhere deletes the home server's copy; removing it from this phone
            // leaves it there for the other devices.
            Button("Delete Book…", role: .destructive) { pendingBookDelete = book }
        }
    }

    /// The sleep timer, here as in Clippings and the full player, while something plays
    ///: a book is exactly what people fall asleep to.
    @ToolbarContentBuilder
    private var sleepTimerItem: some ToolbarContent {
        if model.music.nowPlaying != nil || model.music.sleepTimerArmed {
            ToolbarItem(placement: .topBarTrailing) {
                SleepTimerMenu(model: model) { SleepTimerLabel(model: model) }
                    .accessibilityValue(SleepTimerLabel.value(model))
                    .accessibilityIdentifier("books-sleep-timer")
            }
        }
    }

    // MARK: - Now playing

    /// Whether this chapter is the one loaded in the player, playing or paused.
    private func isCurrent(_ item: ClippingStore.Item?) -> Bool {
        item?.isLoaded(nowPlayingID: model.music.nowPlaying?.id) == true
    }

    /// Whether one of this book's chapters is the one loaded in the player.
    private func isCurrent(_ book: MobileBookShelf.Book) -> Bool {
        guard let id = model.music.nowPlaying?.id else { return false }
        return book.chapters.contains { $0.item?.isLoaded(nowPlayingID: id) == true }
    }

    /// Animated while it plays and still while paused, the way a music row's bars are.
    private var barsArePlaying: Bool { model.music.state == .playing }

    // MARK: - Importing

    /// A file chosen with "Import a File…": the app's own copy goes to the import screen.
    private func importPicked(_ url: URL) {
        do { model.offerImport(try MobileDocuments.stage(url)) } catch {
            show("The file could not be opened: \(error.localizedDescription)")
        }
    }

    // MARK: - Storage (M6.3, M6.5)

    private func offload(_ book: MobileBookShelf.Book) {
        let bytes = model.offload(book)
        guard bytes > 0 else { return }
        show("Download removed, \(BookStorage.sizeText(bytes)) freed")
    }

    private func getBack(_ book: MobileBookShelf.Book) {
        Task {
            do { try await model.getBack(book) } catch {
                show("The book could not come back: \(error)")
            }
        }
    }

    /// Stop making a book again: the chapters already in the new voice go back to the old one.
    private func stopRemaking(_ book: MobileBookShelf.Book) {
        Task {
            do { try await model.books.cancelVoiceChange(documentID: book.documentID) } catch {
                show("The book could not go back to its voice: \(error)")
            }
        }
    }

    private func deleteBook(everywhere: Bool) {
        guard let book = pendingBookDelete else { return }
        pendingBookDelete = nil
        Task {
            await model.deleteBook(book, everywhere: everywhere)
            show("Moved to Recently removed for a week")
            // The open book is gone; go back to the list.
            if openBook == book.documentID { dismiss() }
        }
    }

    private func refreshSuggestion() {
        suggestion = model.bookCleanup.suggestion(for: model.storedBooks, freeBytes: model.freeBytes)
    }

    private func suggestionCard(_ suggestion: BookStorage.Suggestion) -> some View {
        let title = suggestion.kind == .finishedBook
            ? suggestion.ids.first.flatMap { id in model.shelfBooks.first { $0.documentID == id }?.title } : nil
        return VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(BookStorage.suggestionText(suggestion, title: title, device: "this iPhone"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Remove") { answer(.remove, suggestion) }
                    .buttonStyle(.borderedProminent)
                if suggestion.kind == .finishedBook {
                    Button("Always Do This") { answer(.always, suggestion) }
                        .buttonStyle(.bordered)
                }
                Button(suggestion.kind == .finishedBook ? "Keep" : "Not Now") { answer(.keep, suggestion) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("storage-suggestion")
    }

    private func answer(_ answer: BookStorage.Answer, _ suggestion: BookStorage.Suggestion) {
        let bytes = model.bookCleanup.answer(answer, to: suggestion, books: model.storedBooks)
        self.suggestion = nil
        switch answer {
        case .always: show(BookStorage.alwaysConfirmation(device: "this iPhone"))
        case .remove where bytes > 0: show("Download removed, \(BookStorage.sizeText(bytes)) freed")
        default: return
        }
    }

    // MARK: - Playing

    /// The source this book plays under, so the shared collection rule knows it.
    static func source(_ book: MobileBookShelf.Book) -> StreamingPlaybackController.QueueSource {
        BookTransport.source(documentID: book.documentID, title: book.title)
    }

    /// The main button, from the shared collection rule: the player's
    /// Pause or Resume while this book is the collection in it, else Resume from the book's
    /// place, or Play.
    private func mainAction(_ book: MobileBookShelf.Book) -> BookTransport.Action {
        BookTransport.action(model.music.collectionState(Self.source(book)),
                             finished: book.finished, hasPosition: book.position != nil)
    }

    /// Toggle the player for the book in it; queue any other book from its place. A book in the
    /// player is never queued again: its saved place trails the playhead by up to five seconds,
    /// so that jumped it back, and it offered "Previously…" in the middle of listening.
    private func performMain(_ book: MobileBookShelf.Book) {
        if !model.music.toggleIfLoaded(Self.source(book)) { play(book) }
    }

    /// Read Along follows the chapter in the player, so a book that is not playing starts from
    /// its place first, without the "Previously…" offer: the text on screen is the reminder.
    private func readAlong(_ book: MobileBookShelf.Book) {
        if !isCurrent(book) { startPlaying(book) }
        showsReadAlong = true
    }

    /// Play a book from the chosen chapter, or with none chosen from the synced position: the
    /// synced chapter here, and the player resumes inside it. The whole book is the
    /// queue, so Previous reaches the chapters before.
    /// Picking a book up after a break offers "Previously…" first; the book plays once
    /// that is answered. A chosen chapter plays at once.
    ///
    /// A Play that resumes fetches the Mac's place first, for up to about two seconds, and starts
    /// from the merged ledger: a phone kept on screen never pulls on its own. A slow
    /// or unreachable gateway starts the book from the place here; a tap on another chapter
    /// starts that chapter at once.
    private func play(_ book: MobileBookShelf.Book, fromChapter index: Int? = nil) {
        guard BookPlacePull.resumes(fromChapter: index, placeChapter: book.position?.chapterIndex),
              let pull = model.bookPlacePull() else {
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

    private func playFromPlace(_ book: MobileBookShelf.Book, fromChapter index: Int? = nil) {
        if index == nil, documentsOn, !book.finished, book.position != nil {
            let prepared = MobileRecap.preparedBook(for: book, homeServer: model.books)
            if recap.consider(book, prepared: prepared, lastPlayed: store.ledger.document(book.documentID)?.positionAt) { return }
        }
        startPlaying(book, fromChapter: index)
    }

    private func startPlaying(_ book: MobileBookShelf.Book, fromChapter index: Int? = nil) {
        let (songs, start) = MobileBookShelf.queue(for: book, fromChapter: index)
        guard !songs.isEmpty else { return }
        model.music.play(songs, startAt: start, source: Self.source(book))
    }

    // MARK: - Previously…

    private var recapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let offer = recap.offer {
                Label("Previously…", systemImage: "text.book.closed").font(.headline)
                switch recap.state {
                case .offered:
                    Text(Recap.offerText(title: offer.book.title)).font(.callout)
                    HStack {
                        Button("Just Play") { recap.dismiss(); startPlaying(offer.book) }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Hear Recap") { hearRecap(offer.book) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("hear-recap")
                    }
                case .writing:
                    HStack(spacing: 8) { ProgressView(); Text("Writing the recap…").font(.callout) }
                case let .askingConsent(source):
                    // The Mac's first-use question (M4.6), for chapters.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ModelConsentWording.recapQuestion(source)).font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("recap-consent-ask")
                        Text(ModelConsentWording.recapQuestionDetail(source, device: "iPhone", settings: "Settings, Documents"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Not Now") { answerConsent(.notNow, offer.book) }
                                .accessibilityIdentifier("recap-consent-not-now")
                            Spacer()
                            Button("Allow Once") { answerConsent(.once, offer.book) }
                                .accessibilityIdentifier("recap-consent-once")
                            Button("Always") { answerConsent(.always, offer.book) }
                                .accessibilityIdentifier("recap-consent-always")
                        }
                        .buttonStyle(.bordered)
                    }
                case .speaking:
                    Text(recap.text ?? "").font(.callout)
                    if let writtenBy = recap.writtenBy {
                        Text("Written by \(writtenBy)").font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("recap-written-by")
                    }
                case let .failed(why):
                    Text(why).font(.callout).foregroundStyle(.orange)
                    Button("Dismiss") { recap.dismiss() }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func hearRecap(_ book: MobileBookShelf.Book) {
        if model.music.isPlaying { model.music.pause() }
        let routing = MobileRecap.liveRouting(model.agentConfig)
        let ledger = ModelConsentLedger(defaults: BatonStorage.defaults)
        let speak = recapSpeech(for: book)
        Task {
            await recap.hear(sources: routing.sources, consent: routing.consent,
                             isAnswered: { ledger.hasAnswered($0, ModelTask.recap.content) }, executor: routing.executor,
                             speak: speak, thenPlay: { startPlaying(book) })
        }
    }

    private func answerConsent(_ answer: MobileRecapOffer.ConsentAnswer, _ book: MobileBookShelf.Book) {
        let routing = MobileRecap.liveRouting(model.agentConfig)
        let speak = recapSpeech(for: book)
        Task {
            await recap.answerConsent(answer, ledger: ModelConsentLedger(defaults: BatonStorage.defaults),
                                      executor: routing.executor, speak: speak, thenPlay: { startPlaying(book) })
        }
    }

    /// Says a recap in a voice other than the book's narrator.
    private func recapSpeech(for book: MobileBookShelf.Book) -> (String) async -> Bool {
        let narrator = model.books.record(forDocument: book.documentID)
            .flatMap { model.books.preparedBook(forJob: $0.jobID)?.voices.narrator } ?? ""
        let client = model.gatewayBookClient()
        let speaker = recapSpeaker
        return { text in await speaker.speak(text, narrator: narrator, client: client) }
    }

    private func show(_ message: String) {
        status = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if status == message { status = nil }
        }
    }
}

/// A book button's icon and words on one line, centred, as wide as the widest of the book
/// buttons' labels, so the two buttons side by side are the same size whatever they
/// say and `ViewThatFits` stacks them when that width does not fit twice.
private struct BookActionLabel: View {
    let title: String
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let widest: [(title: String, symbol: String)] = [
        ("Read Along", "text.book.closed"), ("Resume", "play.fill"), ("Pause", "pause.fill"),
    ]

    var body: some View {
        ZStack {
            ForEach(Self.widest, id: \.title) { label(title: $0.title, symbol: $0.symbol).hidden() }
            label(title: title, symbol: symbol)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
                .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: symbol)
        }
        .frame(maxWidth: .infinity)
    }

    private func label(title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The open book scrolls under a navigation bar that hides it. iOS 26's soft edge
/// let the header's own title, cover and progress bar show faintly behind the bar's title, and
/// the "Making again…" line sit legible under the bar, which read as two headers over each other.
/// iOS 18 draws the bar's material once content is under it, as before.
private struct SolidTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

/// How far through a book the listener is: "12% heard" or "Finished", and the bar.
/// From the live playhead while one of the book's chapters is in the player, else from the saved
/// place, which the shared ledger keeps in UserDefaults where observation does not see it: read
/// alone it never redrew while the book played. A view of its own, so only this redraws with the
/// playhead, and only for the book in the player.
private struct MobileBookHeard: View {
    enum Part { case words, bar(maxWidth: CGFloat?) }

    let model: MobileModel
    let book: MobileBookShelf.Book
    let part: Part

    var body: some View {
        let loaded = model.music.collectionState(BooksView.source(book)).isLoaded
            ? book.loadedChapter(nowPlayingID: model.music.nowPlaying?.id) : nil
        let place = BookTransport.place(loadedChapter: loaded, playhead: loaded == nil ? 0 : model.music.currentTime,
                                        saved: book.position)
        let fraction = book.listenedFraction(at: place, live: loaded != nil)
        let finished = book.finished && loaded == nil
        switch part {
        case .words:
            if finished {
                Text("Finished")
            } else if fraction > 0 {
                Text(BookTransport.heardText(fraction))
            }
        case let .bar(maxWidth):
            if fraction > 0 && !finished {
                ProgressView(value: fraction)
                    .frame(maxWidth: maxWidth)
                    .accessibilityLabel("Heard")
                    .accessibilityValue(BookTransport.heardText(fraction))
                    .accessibilityIdentifier("book-heard-bar")
            }
        }
    }
}

/// The five-second watch on a book being made runs while a Books screen is on the screen
/// (M5.3). The list and an open book each appear and disappear, and a push from one to the
/// other does both in an order SwiftUI does not promise, so the watch stops only once neither
/// is back a moment later.
@MainActor
enum BooksWatch {
    private static var onScreen = 0

    static func appeared() { onScreen += 1 }

    static func disappeared(model: MobileModel) {
        onScreen = max(0, onScreen - 1)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if onScreen == 0 { model.books.stopWatching() }
        }
    }
}
