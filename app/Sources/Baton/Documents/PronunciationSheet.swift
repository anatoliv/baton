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
            return "No model on this Mac or the home server, so names are read as written. Add any below."
        }
        return "No model on this Mac or the home server, and \(CloudModelConsent.notAllowedClause(cloud, modelTask.content)), so names are read as written. Add any below."
    }

    static func rows(_ lexicon: PronunciationLexicon?) -> [Row] {
        (lexicon?.entries ?? []).map { Row(word: $0.word, phonemes: $0.phonemes, source: $0.source) }
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
    /// a name to ask about. `NSSpellChecker` is main-actor, so it is reached by a hop.
    nonisolated static func isWord(_ word: String) -> Bool? {
        let check = { NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound }
        return Thread.isMainThread ? MainActor.assumeIsolated(check) : DispatchQueue.main.sync(execute: check)
    }
}

extension DocumentLibrary {
    /// Give a book made on this Mac a corrected lexicon. The chapters whose text changes are
    /// taken out of Clippings and the book is submitted again under its new id, so only those
    /// chapters' chunks are synthesized (the rest come from the chunk cache) and only they land
    /// again. When no chapter changes (a word the book never says, a proposal confirmed as it
    /// was) the job is rewritten in place and nothing is re-made. Returns the chapters re-made.
    @discardableResult
    func applyLexicon(_ lexicon: PronunciationLexicon?, to book: BookShelf.Book, clippings: ClippingStore) async throws -> [Int] {
        guard let job = job(forDocument: book.documentID), job.renderer == .thisMac,
              var stored = store.load(job.id) else { throw PronunciationError.notOnThisMac }
        var updated = stored.book
        updated.lexicon = lexicon
        let affected = PronunciationEditing.affectedChapters(from: stored.book, to: updated)
        if affected.isEmpty {
            stored.book = updated
            try store.save(stored)
            refresh()
            return []
        }
        for index in affected {
            if let item = clippings.item(documentID: book.documentID, chapterIndex: index) {
                clippings.remove(id: item.id, dismissing: false)
            }
        }
        await cancel(job.id)
        try await submit(updated)
        documentsLog.notice("book \"\(updated.title, privacy: .public)\": lexicon changed, re-making \(affected.count) chapters")
        return affected
    }

    enum PronunciationError: Error, CustomStringConvertible {
        case notOnThisMac
        var description: String { "Pronunciations can be corrected for books made on this Mac." }
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
            if let job = library.job(forDocument: book.documentID), job.renderer == .thisMac {
                original = library.store.load(job.id)?.book.lexicon
                rows = PronunciationEditing.rows(original)
            } else {
                failure = DocumentLibrary.PronunciationError.notOnThisMac.description
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
