import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import BatonSubsonicModels
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Not private: `MobileModel.deleteClippingsEverywhere` logs a gateway failure under the same
/// category, and two loggers for one subject is how their messages drift apart.
let clippingsLog = Logger(subsystem: "io.tonebox.baton", category: "Clippings")

/// **Clippings** on the phone: audio the Mac made, collected from the home gateway.
///
/// The card this came from proposed "its own small surface". That was the wrong shape and the
/// Mac proved it: a clipping's id is its own `file://` URL, which `MediaKind` calls
/// `.localFile` and `resolveStreamURL` resolves without a server, so it plays through the
/// ordinary player with the transport, the queue and the now-playing bar already attached. A
/// bespoke surface would have meant a second player path maintained forever for content that
/// needs none.
///
/// So this file is only a list. The store, the model and the playback are all shared code that
/// already existed and is already tested.
struct ClippingsView: View {
    let model: MobileModel

    @State private var collecting = false
    @State private var status: String?
    @State private var filter = ""
    @State private var expandedBooks: Set<String> = []
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
    /// "Previously…": offered by Play on a book last heard more than a day ago.
    @State private var recap = MobileRecapOffer()
    @State private var recapSpeaker = MobileRecapSpeaker()

    private var store: ClippingStore { model.clippings }
    /// Read live through the model's switch, so turning Documents off in Settings hides the
    /// books and the import menu at once.
    private var documentsOn: Bool { model.documentsSwitch.isOn }

    /// Readings and chapters alike, filtered by what is said and what it is called. A book's
    /// chapters are grouped below; readings keep their flat rows. Through the shared search index
    /// (M8.9): case and accents are ignored, and typing is answered after a short pause.
    private var items: [ClippingStore.Item] { model.clippingSearch.filter(store.items) }

    private var readings: [ClippingStore.Item] { items.filter { !$0.clipping.isBookChapter } }

    /// Each book once, from what has landed and what the home server says (M5.3).
    private var books: [MobileBookShelf.Book] {
        guard documentsOn else { return [] }
        let search = model.clippingSearch
        let records = search.isFiltering ? model.books.records.filter { search.matches(title: $0.title) } : model.books.records
        return MobileBookShelf.books(items: items, records: records, summaries: model.books.summaries, ledger: store.ledger,
                                     changes: model.books.voiceChanges.all)
    }

    /// Only what can actually be played. A queue entry whose file has gone stalls with no
    /// explanation, which is worse than a row that visibly says it is unavailable. Readings
    /// only: a book plays as its own queue, from its row.
    private var playable: [NavidromeSong] { ClippingQueue.readings(items) }

    private var source: StreamingPlaybackController.QueueSource {
        .init(label: "Clippings", kind: .liked, id: nil)
    }

    var body: some View {
        List {
            if store.items.isEmpty && books.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No clippings yet",
                        systemImage: "waveform.circle",
                        description: Text(documentsOn
                            ? "Open a PDF, EPUB or text file in Baton from Files, or import a link, and your Baton server reads it to you here. On your Mac, a reading kept with File → Keep Reading in Clippings arrives here too."
                            : "On your Mac, read something aloud and choose "
                              + "File → Keep Reading in Clippings. It arrives here "
                              + "through your Baton server.")
                    )
                }
            } else {
                if documentsOn, recap.offer != nil {
                    Section { recapCard }
                }
                if documentsOn, let suggestion {
                    Section { suggestionCard(suggestion) }
                }
                if !books.isEmpty {
                    Section("Books") {
                        ForEach(books) { book in
                            bookRow(book)
                        }
                    }
                }
                if !readings.isEmpty {
                    Section {
                        ForEach(readings) { item in
                            row(item)
                        }
                        .onDelete { offsets in
                            // Deliberately not a swipe-to-delete with no confirmation elsewhere in
                            // this app's idiom: a clipping is the only copy, so the alert below says
                            // so before anything is removed.
                            pendingDelete = offsets.compactMap { readings[$0].id }
                        }
                    } header: {
                        if !books.isEmpty { Text("Readings") }
                    } footer: {
                        if let text = footerText { Text(text) }
                    }
                }
            }
        }
        .navigationTitle("Clippings")
        .searchable(text: $filter, prompt: "Filter clippings")
        .onChange(of: filter, initial: true) { _, text in
            model.clippingSearch.follow(store)
            model.clippingSearch.setQuery(text)
        }
        // Pulled by hand, so say what happened: a manual pull that silently achieves nothing is
        // indistinguishable from one that failed.
        .refreshable {
            await collect(announcing: true)
            await model.collectBooks()
        }
        .task {
            store.loadIfNeeded()
            // Collect on open rather than on a timer. Polling is the wrong shape for a
            // local-first app, and "when you look at the screen" is both the moment you care
            // and a moment you chose.
            await collect()
            // A book still being made is the one exception: its row says what the home server
            // is doing, and that is worth asking every few seconds while this screen is open.
            await model.collectBooks()
            model.books.watchIfNeeded { }
            // The storage rules this phone's owner chose, then at most one suggestion a week.
            if documentsOn {
                model.applyStorageRules()
                refreshSuggestion()
            }
        }
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
        .onDisappear { model.books.stopWatching() }
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
            // The sleep timer, here as well as in the full player, while something plays
            //: a run of clippings is exactly what people fall asleep to.
            if model.music.nowPlaying != nil || model.music.sleepTimerArmed {
                ToolbarItem(placement: .topBarTrailing) {
                    SleepTimerMenu(model: model) { sleepLabel }
                        .accessibilityValue(sleepValue)
                        .accessibilityIdentifier("clippings-sleep-timer")
                }
            }
            if !playable.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.music.play(playable, source: source)
                    } label: { Image(systemName: "play.fill") }
                        .accessibilityLabel("Play all clippings")
                }
            }
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
                    status = "That is not a web address"
                    Task { await clearStatus() }
                }
            }
        } message: {
            Text("The page is read as an article and made into a book on your Baton server.")
        }
        // The wording, and the choice it offers, now live in one modifier: the player's
        // long-press menu deletes a clipping too, and this dialog is the only thing telling
        // someone that one of these buttons destroys the last copy.
        .clippingDeleteConfirmation($pendingDelete, model: model) { message in
            status = message
            Task { await clearStatus() }
        }
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

    @State private var pendingDelete: [String] = []

    // MARK: - Sleep timer

    /// The moon, filled while a timer is set, with what is left beside it: the minutes counting
    /// down, or "End of chapter". Counting down by itself, so nothing here runs a clock.
    @ViewBuilder
    private var sleepLabel: some View {
        let music = model.music
        HStack(spacing: 4) {
            Image(systemName: music.sleepTimerArmed ? "moon.zzz.fill" : "moon.zzz")
            if let endsAt = music.sleepTimerEndsAt {
                let now = Date()
                Text(timerInterval: now ... max(now, endsAt), countsDown: true)
                    .monospacedDigit()
                    .font(.footnote)
            } else if music.sleepAfterCurrentTrack {
                Text(SleepTimerOptions.endLabel(for: music.nowPlaying, isSpoken: music.isSpokenNowPlaying))
                    .font(.footnote)
            }
        }
        .foregroundStyle(music.sleepTimerArmed ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    private var sleepValue: String {
        let music = model.music
        if let endsAt = music.sleepTimerEndsAt {
            let minutes = max(1, Int((endsAt.timeIntervalSinceNow / 60).rounded(.up)))
            return "Stops in \(Counted.phrase(minutes, "minute"))"
        }
        if music.sleepAfterCurrentTrack {
            return SleepTimerOptions.endLabel(for: music.nowPlaying, isSpoken: music.isSpokenNowPlaying)
        }
        return "Off"
    }

    // MARK: - Now playing

    /// Whether this clipping is the one loaded in the player, playing or paused.
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

    /// A file chosen with "Import a File…": the app's own copy goes to the import screen.
    private func importPicked(_ url: URL) {
        do { model.offerImport(try MobileDocuments.stage(url)) } catch {
            status = "The file could not be opened: \(error.localizedDescription)"
            Task { await clearStatus() }
        }
    }

    private var footerText: String? {
        guard !store.items.isEmpty else { return nil }
        let bytes = store.totalBytes
        guard bytes > 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(Counted.phrase(store.items.count, "clipping")), \(size). These play with no "
            + "server and no network."
    }

    @ViewBuilder
    private func bookRow(_ book: MobileBookShelf.Book) -> some View {
        let expanded = expandedBooks.contains(book.documentID)
        DisclosureGroup(isExpanded: Binding(
            get: { expanded },
            set: { open in if open { expandedBooks.insert(book.documentID) } else { expandedBooks.remove(book.documentID) } }
        )) {
            ForEach(book.chapters) { chapter in
                let current = isCurrent(chapter.item)
                Button {
                    play(book, fromChapter: chapter.index)
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
                    // The whole row plays: a plain button's Spacer takes no taps, so a tap between
                    // the title and the length did nothing (found by BookRowsUITests, M5.3).
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(chapter.item?.isPresent != true)
                .opacity(chapter.item?.isPresent == true ? 1 : 0.6)
                .accessibilityValue(current ? (barsArePlaying ? "Now playing" : "Paused") : "")
            }
        } label: {
            Button {
                play(book)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed").foregroundStyle(.secondary).frame(width: 22)
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
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let origin = book.originText {
                            Text(origin).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if gettingPlace == book.documentID {
                            Text("Getting your place…").font(.caption).foregroundStyle(.secondary)
                        }
                        if let line = book.statusLine {
                            Text(line.text).font(.caption)
                                .foregroundStyle(line.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .lineLimit(2)
                        }
                    }
                    // Quieter than the chapter: the bars alone, so a closed book still says one
                    // of its chapters is the one playing.
                    if isCurrent(book) {
                        Spacer(minLength: 6)
                        NowPlayingBars(isPlaying: barsArePlaying)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(book.readyChapters.isEmpty)
            .accessibilityIdentifier("book-\(book.documentID)")
        }
        .contextMenu {
            Button("Play") { play(book) }.disabled(book.readyChapters.isEmpty)
            if let title = model.getBackTitle(book) {
                Button(title) { getBack(book) }
            }
            if !book.readyChapters.isEmpty, model.stored(book).canGetBack {
                Button("Remove Download") { offload(book) }
            }
            Toggle("Keep on This iPhone", isOn: Binding(
                get: { model.bookCleanup.isKept(book.documentID) },
                set: { model.bookCleanup.setKeep($0, documentID: book.documentID) }
            ))
            // Made again in another voice by the home server, from the shaped book
            // kept beside the record.
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
    }

    // MARK: - Storage (M6.3, M6.5)

    private func offload(_ book: MobileBookShelf.Book) {
        let bytes = model.offload(book)
        guard bytes > 0 else { return }
        status = "Download removed, \(BookStorage.sizeText(bytes)) freed"
        Task { await clearStatus() }
    }

    private func getBack(_ book: MobileBookShelf.Book) {
        Task {
            do { try await model.getBack(book) } catch {
                status = "The book could not come back: \(error)"
                await clearStatus()
            }
        }
    }

    /// Stop making a book again: the chapters already in the new voice go back to the old one.
    private func stopRemaking(_ book: MobileBookShelf.Book) {
        Task {
            do { try await model.books.cancelVoiceChange(documentID: book.documentID) } catch {
                status = "The book could not go back to its voice: \(error)"
                await clearStatus()
            }
        }
    }

    private func deleteBook(everywhere: Bool) {
        guard let book = pendingBookDelete else { return }
        pendingBookDelete = nil
        expandedBooks.remove(book.documentID)
        Task {
            await model.deleteBook(book, everywhere: everywhere)
            status = "Moved to Recently removed for a week"
            await clearStatus()
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
        case .always: status = BookStorage.alwaysConfirmation(device: "this iPhone")
        case .remove where bytes > 0: status = "Download removed, \(BookStorage.sizeText(bytes)) freed"
        default: return
        }
        Task { await clearStatus() }
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
        model.music.play(songs, startAt: start, source: .init(label: book.title, kind: .song, id: book.documentID))
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

    @ViewBuilder
    private func row(_ item: ClippingStore.Item) -> some View {
        let current = isCurrent(item)
        Button {
            play(item)
        } label: {
            HStack(spacing: 12) {
                // Bars in place of the waveform while it is the one in the player, as a music
                // row marks its track.
                Group {
                    if current {
                        NowPlayingBars(isPlaying: barsArePlaying)
                    } else {
                        Image(systemName: item.isPresent ? "waveform" : "exclamationmark.triangle")
                            .foregroundStyle(item.isPresent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                }
                .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.clipping.title).lineLimit(1)
                        .foregroundStyle(current ? Color.accentColor : .primary)
                    HStack(spacing: 6) {
                        if let origin = item.clipping.source, !origin.isEmpty { Text(origin) }
                        Text(item.clipping.createdAt, style: .date)
                        if let seconds = item.clipping.durationSeconds, seconds > 0 {
                            Text(Self.durationText(seconds))
                        }
                        // Said plainly rather than discovered by pressing play.
                        if !item.isPresent {
                            Text("the audio file has gone").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.isPresent)
        .accessibilityValue(current ? (barsArePlaying ? "Now playing" : "Paused") : "")
    }

    /// Play from this clipping onwards, so the list behaves like every other list here. The
    /// readings after it, never a book's chapters.
    private func play(_ item: ClippingStore.Item) {
        let songs = ClippingQueue.readings(from: item, in: items)
        guard !songs.isEmpty else { return }
        model.music.play(songs, source: source)
    }

    /// Collect anything on the gateway this phone does not already have.
    ///
    /// Silent when no gateway is configured, which is the common case for someone who has not
    /// set one up: they should not be told about a feature they do not use. Failures say so
    /// only when the pull was asked for by hand, since an automatic collect that quietly
    /// achieves nothing is better than a banner on every visit.
    private func collect(announcing announce: Bool = false) async {
        guard !collecting else { return }
        let raw = model.agentConfig.gatewayURL.trimmingCharacters(in: .whitespaces)
        let token = model.agentConfig.gatewayToken.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !token.isEmpty, let url = URL(string: raw), url.host != nil else { return }

        collecting = true
        defer { collecting = false }

        let files = GatewayFiles(gatewayURL: url, token: token)
        do {
            let remote = try await files.list()
            // What this phone already holds, by digest. Matching on the content hash rather than
            // on the name means the same reading collected twice is one clipping, and two
            // different readings that happen to share a title are two.
            // What this phone already holds, plus what it has deliberately thrown away. Without
            // the second set a delete undoes itself: removing a clipping takes its digest out of
            // `known`, and the next refresh downloads it straight back. See
            // `ClippingStore.dismissedDigests`.
            let known = Set(store.items.compactMap(\.clipping.sha256))
            // Two different statements, deliberately kept apart: "not on this device" and
            // "gone everywhere". Collection skips the union of both.
            let dismissed = store.dismissedDigests.union(store.ledger.removedDigests)
            let wanted = remote.filter { file in
                guard let digest = file.sha256 else { return false }
                return !known.contains(digest) && !dismissed.contains(digest)
            }
            guard !wanted.isEmpty else {
                if announce { status = "Nothing new" ; await clearStatus() }
                return
            }

            var collected = 0
            for file in wanted {
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("clip-\(file.id).\(Self.extensionFor(file))")
                do {
                    // `download` verifies the digest and deletes the file on a mismatch, so a
                    // truncated transfer cannot become a silently short reading.
                    try await files.download(id: file.id, expecting: file.sha256, to: staged)
                    try store.adopt(staged, title: Self.title(for: file),
                                    sourceName: file.origin, sha256: file.sha256)
                    collected += 1
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    clippingsLog.error("could not collect \(file.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if collected > 0 {
                status = "Collected \(Counted.phrase(collected, "clipping"))"
                await clearStatus()
            } else if announce {
                status = "Nothing arrived"
                await clearStatus()
            }
        } catch {
            if announce {
                status = (error as? LocalizedError)?.errorDescription ?? "Could not reach the Baton server"
                await clearStatus()
            }
            clippingsLog.error("clipping collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove the shared copy as well as this device's.
    ///
    /// No tombstone is recorded: the point of a tombstone is to stop a file coming back, and a
    /// file that is no longer on the gateway cannot. Recording one anyway would suppress a
    /// *future* clipping that happened to hash identically, which for the same audio kept again
    /// deliberately is exactly the wrong outcome.
    ///
    /// The local copy goes first. If the gateway call fails, the clipping is still gone from this
    /// phone — which is what was asked for — and the failure says the shared copy survived rather
    /// than leaving both in place and calling it an error.
    private func clearStatus() async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        status = nil
    }

    /// A readable name. The gateway carries the Mac's filename, which is already
    /// "<app> <date> <time>", so it is used as-is minus the extension rather than reformatted
    /// into something that would disagree with what the Mac shows for the same clipping.
    private static func title(for file: GatewayFiles.RemoteFile) -> String {
        let name = file.name
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[name.startIndex ..< dot])
    }

    /// Preserve the real extension so `ClippingStore` finds the file again after a relaunch,
    /// and so an older WAV clipping still plays.
    private static func extensionFor(_ file: GatewayFiles.RemoteFile) -> String {
        if let dot = file.name.lastIndex(of: "."), dot < file.name.index(before: file.name.endIndex) {
            return String(file.name[file.name.index(after: dot)...])
        }
        return file.contentType.hasSuffix("wav") ? "wav" : "m4a"
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return minutes > 0 ? "\(minutes) min \(remainder)s" : "\(remainder)s"
    }
}
