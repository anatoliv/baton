import AppKit
import BatonDocuments
import BatonPlaybackKit
import SwiftUI

/// The pronunciation lexicon on the Mac (M8.6): what a book carries (`PreparedBook.lexicon`),
/// each word's phonemes in a field the person can correct, and the chapters that change
/// re-made. The proposing, the IPA conversion and the Kokoro markup are `PronunciationLexicon`
/// in BatonDocuments; this is the editing and the re-render.
enum PronunciationEditing {
    struct Row: Identifiable, Equatable {
        var word: String
        /// Phonemes as Kokoro reads them, which is what the field shows and takes (IPA goes in
        /// and is converted on the way).
        var phonemes: String
        /// "model" until a person has looked, "person" once corrected or confirmed.
        var source: String
        var id: String { word }

        var sourceText: String { source == "model" ? "proposed by a model" : "yours" }
    }

    /// The proposal's task (`ModelTask.pronunciations`), which Apple's on-device model answers
    /// with a typed reply.
    static let modelTask = ModelTask.pronunciations

    /// Why no names were proposed when no source may run the proposal: nothing set up, or a
    /// cloud source the person has not allowed excerpts.
    static func noModelLine(router: ModelRouter) -> String {
        guard let cloud = router.awaitingConsent(for: modelTask).first else {
            return "No model on this Mac or the Baton server, so names are read as written. Add any below."
        }
        return "No model on this Mac or the Baton server, and \(CloudModelConsent.notAllowedClause(cloud, modelTask.content)), so names are read as written. Add any below."
    }

    /// The rows show what is sent (`PronunciationLexicon.validated`): a stored lexicon from
    /// before TBX-10947 may hold two model words with one sound, which no renderer sends.
    static func rows(_ lexicon: PronunciationLexicon?) -> [Row] {
        (lexicon?.validated().entries ?? []).map { Row(word: $0.word, phonemes: $0.phonemes, source: $0.source) }
    }

    /// The lexicon after editing: a changed field is the person's word, an emptied field drops
    /// the entry, an unchanged one is kept as it was. Nil when nothing is left.
    static func lexicon(from rows: [Row], original: PronunciationLexicon?) -> PronunciationLexicon? {
        var lexicon = PronunciationLexicon()
        let before = Dictionary((original?.entries ?? []).map { ($0.word, $0) }, uniquingKeysWith: { a, _ in a })
        for row in rows {
            let word = row.word.trimmingCharacters(in: .whitespaces)
            let phonemes = row.phonemes.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !phonemes.isEmpty else { continue }
            if let kept = before[word], kept.phonemes == phonemes {
                lexicon.entries.removeAll { $0.word == word }
                lexicon.entries.append(kept)
            } else {
                lexicon.set(word, ipa: phonemes)
            }
        }
        lexicon.entries.sort { $0.word < $1.word }
        return lexicon.isEmpty ? nil : lexicon
    }

    /// Whether `phonemes` is something Kokoro can read, for the field's warning.
    static func isValid(_ phonemes: String) -> Bool {
        PronunciationLexicon.isValid(PronunciationLexicon.kokoroPhonemes(fromIPA: phonemes))
    }

    /// The chapters whose rendered text differs between two versions of a book: the ones a
    /// lexicon change re-makes. A word that no chapter says changes nothing.
    static func affectedChapters(from old: PreparedBook, to new: PreparedBook) -> [Int] {
        zip(old.chapters, new.chapters).compactMap { before, after in
            let changed = zip(before.segments, after.segments).contains { old.request(for: $0).text != new.request(for: $1).text }
            return changed || before.segments.count != after.segments.count ? after.index : nil
        }
    }

    /// The spell checker as `PronunciationLexicon.candidates` wants it: a word it knows is not
    /// a name to ask about. A lower-case word any installed dialect of the checker's language
    /// knows counts: the default "en" dictionary does not know the British "neighbourhood",
    /// which put it beside "Netherfield" in the TBX-10886 walk's proposal. Names
    /// keep the default dictionary alone, since the other dialects know names a voice may still
    /// get wrong ("Vashti" in en_GB, "Kuno" in en_JP). `NSSpellChecker` is main-actor, so it is
    /// reached by a hop.
    nonisolated static func isWord(_ word: String) -> Bool? {
        let check = {
            let checker = NSSpellChecker.shared
            if checker.checkSpelling(of: word, startingAt: 0).location == NSNotFound { return true }
            guard word.first?.isLowercase == true else { return false }
            let base = checker.language().split(separator: "_").first.map(String.init) ?? checker.language()
            return checker.availableLanguages.contains { language in
                language.hasPrefix(base + "_") && checker.checkSpelling(
                    of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
                ).location == NSNotFound
            }
        }
        return Thread.isMainThread ? MainActor.assumeIsolated(check) : DispatchQueue.main.sync(execute: check)
    }
}

extension DocumentLibrary {
    /// The shaped book whose pronunciations can be corrected: the render job's for a book made
    /// on this Mac, or the copy saved beside the record of a book made on the home server
    /// (every submission since M6.3). Nil for a book with neither, which has no lexicon here.
    func pronunciationSource(documentID: String) -> (book: PreparedBook, renderer: Renderer, jobID: String)? {
        if let job = job(forDocument: documentID), job.renderer == .thisMac {
            return store.load(job.id).map { ($0.book, .thisMac, job.id) }
        }
        guard let record = homeServer.record(forDocument: documentID),
              let book = homeServer.preparedBook(forJob: record.jobID) else { return nil }
        return (book, .homeServer, record.jobID)
    }

    /// Whether Pronunciations… is offered: a job made here, or a home-server book whose shaped
    /// book was saved. Reads no book, since the menu is drawn with every row.
    func canEditPronunciations(_ book: BookShelf.Book) -> Bool {
        if let job = job(forDocument: book.documentID), job.renderer == .thisMac { return true }
        return homeServer.record(forDocument: book.documentID).map { homeServer.hasPreparedBook(forJob: $0.jobID) } ?? false
    }

    /// Give a book a corrected lexicon, wherever it was made. What is kept is what renderers
    /// send (`PronunciationLexicon.validated`), so the job id follows the lexicon actually used.
    ///
    /// The same lexicon is no change at all: nothing is written, the job keeps its id. When no
    /// chapter's text changes (a word the book never says, a proposal confirmed as it was) the
    /// book is rewritten in place and nothing is re-made. Otherwise the book is submitted under
    /// its new id with everything else as it was (narrator, cast, settings) and the chapters
    /// whose text changes leave Clippings, so only their chunks are synthesized (the rest come
    /// from the chunk cache, here or on the home server) and only they land again, in their
    /// places; the listening position is the book's, so it stays. Returns the chapters re-made.
    @discardableResult
    func applyLexicon(_ lexicon: PronunciationLexicon?, to book: BookShelf.Book, clippings: ClippingStore) async throws -> [Int] {
        guard let source = pronunciationSource(documentID: book.documentID) else { throw PronunciationError.noPreparedBook }
        let validated = lexicon.map { $0.validated() }.flatMap { $0.isEmpty ? nil : $0 }
        let before = source.book.lexicon.flatMap { $0.isEmpty ? nil : $0 }
        guard validated != before else { return [] }
        var updated = source.book
        updated.lexicon = validated
        let affected = PronunciationEditing.affectedChapters(from: source.book, to: updated)
        switch (source.renderer, affected.isEmpty) {
        case (.thisMac, true):
            guard var stored = store.load(source.jobID) else { throw PronunciationError.noPreparedBook }
            stored.book = updated
            try store.save(stored)
        case (.homeServer, true):
            homeServer.replacePreparedBook(updated, jobID: source.jobID)
        case (.thisMac, false):
            removeChapters(affected, of: book.documentID, clippings: clippings)
            await cancel(source.jobID)
            try await submit(updated)
        case (.homeServer, false):
            // Sent first: a home server that is away leaves the book as it was.
            let newID = try await homeServer.resubmit(jobID: source.jobID, as: updated)
            removeChapters(affected, of: book.documentID, clippings: clippings)
            // A finished book stays finished on the home server too, so its keep date holds.
            if clippings.ledger.document(book.documentID)?.finished == true {
                await homeServer.markFinished(jobID: newID)
            }
        }
        refresh()
        if !affected.isEmpty {
            documentsLog.notice("book \"\(updated.title, privacy: .private)\": lexicon changed, re-making \(affected.count) chapters")
        }
        return affected
    }

    private func removeChapters(_ indexes: [Int], of documentID: String, clippings: ClippingStore) {
        for index in indexes {
            if let item = clippings.item(documentID: documentID, chapterIndex: index) {
                clippings.remove(id: item.id, dismissing: false)
            }
        }
    }

    enum PronunciationError: Error, CustomStringConvertible {
        case noPreparedBook
        var description: String { "This Mac has no copy of the book's text to correct its pronunciations." }
    }
}

/// The list: one row per word with its phonemes in a field, and a line to add a word.
struct PronunciationListView: View {
    @Binding var rows: [PronunciationEditing.Row]
    @State private var newWord = ""
    @State private var newPhonemes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("No words have a pronunciation yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    Text(row.word).frame(width: 140, alignment: .leading).lineLimit(1)
                    TextField("IPA", text: $row.phonemes)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .accessibilityLabel("Pronunciation of \(row.word)")
                    Text(row.sourceText).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                    if !row.phonemes.isEmpty && !PronunciationEditing.isValid(row.phonemes) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            .help("Kokoro cannot read these phonemes; use IPA letters, with ˈ for stress.")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Word", text: $newWord).textFieldStyle(.roundedBorder).frame(width: 140)
                TextField("IPA, like kˈuːnoʊ", text: $newPhonemes).textFieldStyle(.roundedBorder).font(.body.monospaced())
                Button("Add") {
                    let word = newWord.trimmingCharacters(in: .whitespaces)
                    guard !word.isEmpty, PronunciationEditing.isValid(newPhonemes) else { return }
                    rows.removeAll { $0.word == word }
                    rows.append(.init(word: word, phonemes: PronunciationLexicon.kokoroPhonemes(fromIPA: newPhonemes), source: "person"))
                    rows.sort { $0.word < $1.word }
                    newWord = ""
                    newPhonemes = ""
                }
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty || !PronunciationEditing.isValid(newPhonemes))
            }
            Text("Empty a field to drop a word. Only Kokoro voices read these; a corrected word re-makes the chapters that say it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Pronunciations… on a book's row: the lexicon it carries, corrected and applied.
struct PronunciationSheet: View {
    let book: BookShelf.Book
    let library: DocumentLibrary
    let clippings: ClippingStore
    let onDone: () -> Void

    @State private var original: PronunciationLexicon?
    @State private var rows: [PronunciationEditing.Row] = []
    @State private var loaded = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pronunciations in \(book.title)").font(.title3.weight(.semibold)).lineLimit(2)
            if loaded {
                ScrollView { PronunciationListView(rows: $rows).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 320)
            } else {
                ProgressView().controlSize(.small)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!loaded || saving)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            if let source = library.pronunciationSource(documentID: book.documentID) {
                original = source.book.lexicon
                rows = PronunciationEditing.rows(original)
            } else {
                failure = DocumentLibrary.PronunciationError.noPreparedBook.description
            }
            loaded = true
        }
    }

    private func save() {
        saving = true
        let lexicon = PronunciationEditing.lexicon(from: rows, original: original)
        Task {
            do {
                try await library.applyLexicon(lexicon, to: book, clippings: clippings)
                onDone()
            } catch {
                failure = "\(error)"
                saving = false
            }
        }
    }
}
