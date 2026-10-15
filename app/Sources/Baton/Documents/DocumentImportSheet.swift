import BatonDocuments
import SwiftUI

/// What Baton found in a file, before anything is made from it (M3.4).
///
/// Everything the import knows is shown: the title and author it took from the first page, the
/// chapters, the front matter it set aside, every warning, and what the book will cost in time
/// and space. "Degrade honestly" (`specs/document-clippings.md`, *Goals*): a page with no text
/// is named here, not discovered at minute 40.
///
/// The narrator is suggested by a model when one answers (M4.4, `VoiceSuggestions`): three voices
/// with the reason and who suggested it, each playable in the book's own words. Rendering is on
/// this Mac; the home server joins with the gateway client (M5.1).
struct DocumentImportSheet: View {
    let url: URL
    let library: DocumentLibrary
    /// The device a document came from with "Send to my Mac", or nil for one opened
    /// here. A sent one offers Not Now (keep it for later) and Discard instead of Cancel.
    var sentFrom: String? = nil
    /// Made into a book, for a sent document: it is then removed from the gateway.
    var onImported: () -> Void = {}
    /// Discarded, for a sent document.
    var onDiscard: () -> Void = {}
    let onDone: () -> Void

    private enum Phase {
        case reading
        case failed(String)
        case ready(ImportedDocument, voice: String)
    }

    @State private var phase = Phase.reading
    @State private var submitting = false
    @State private var suggestion: VoiceSuggestion?
    @State private var chosen: String?
    @State private var preview = VoicePreviewPlayer()
    /// Where the book is made: the home server when it answers with books on (the spec's default
    /// at home), otherwise this Mac.
    @State private var renderer: DocumentLibrary.Renderer = .thisMac
    @State private var homeServerAvailable = false
    /// Settings → Speech → Make books on: Ask each time offers the choice below;
    /// This Mac or Home server makes it without asking.
    private let makeBooksOn = BookVoiceSettings.makeBooksOn
    /// Names a voice might stumble on, as a model proposed them (M8.6), each in a field the
    /// person can correct before the book is made.
    @State private var proposedLexicon: PronunciationLexicon?
    @State private var lexiconRows: [PronunciationEditing.Row] = []
    @State private var lexiconLine: String?
    /// The cloud source to ask about, when nothing local suggested a narrator (M4.6).
    @State private var consentAsk: ModelSource?
    /// "Allow once": this sheet's narrator suggestion may use it; nothing is recorded.
    @State private var allowedOnce: ModelSource?
    /// "Voice the dialogue" (G4): as the person last left it on this Mac (off the first time),
    /// and the cast checked before use.
    @State private var cast = DialogueCastChoice.remembered()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .reading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(DocumentLibrary.isWebLink(url) ? (url.host ?? url.absoluteString) : url.lastPathComponent)…")
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                HStack {
                    Spacer()
                    if sentFrom != nil {
                        Button("Discard") { onDiscard(); onDone() }
                        Button("Not Now", action: onDone).keyboardShortcut(.cancelAction)
                    } else {
                        Button("Close", action: onDone).keyboardShortcut(.cancelAction)
                    }
                }
            case let .ready(document, voice):
                details(document, voice: voice)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await read() }
        .task {
            homeServerAvailable = await library.homeServerAvailable()
            renderer = BookVoiceSettings.initialRenderer(makeBooksOn, homeServerAvailable: homeServerAvailable)
        }
        .onDisappear { preview.stop() }
    }

    @ViewBuilder
    private func details(_ document: ImportedDocument, voice: String) -> some View {
        let estimate = ListeningEstimate(document)
        VStack(alignment: .leading, spacing: 2) {
            Text(document.title).font(.title3.weight(.semibold)).lineLimit(2)
            if let author = document.author {
                Text("by \(author)").foregroundStyle(.secondary)
            }
            if let sentFrom {
                Text("Sent from \(sentFrom).").font(.caption).foregroundStyle(.secondary)
            }
        }
        Text("About \(estimate.durationText) of audio. About \(estimate.sizeText) on this Mac.")
            .font(.callout)

        GroupBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(document.chapters, id: \.index) { chapter in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(chapter.index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            Text(chapter.title).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        } label: {
            Text(document.chapters.count == 1 ? "1 chapter" : "\(document.chapters.count) chapters")
        }

        if !document.frontMatter.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Set aside from the reading").font(.caption).foregroundStyle(.secondary)
                ForEach(document.frontMatter, id: \.self) { Text($0).font(.caption).lineLimit(2) }
            }
        }

        if !document.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(document.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(Self.text(for: warning), systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }

        narrator(document)
        pronunciations(document)
        DialogueCastSection(document: document, narrator: chosen ?? voice, modelFree: lexiconLine != nil, choice: $cast)

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Made on").foregroundStyle(.secondary)
                if BookVoiceSettings.sheetAsks(makeBooksOn, homeServerAvailable: homeServerAvailable) {
                    Picker("Made on", selection: $renderer) {
                        Text("Home server").tag(DocumentLibrary.Renderer.homeServer)
                        Text("This Mac").tag(DocumentLibrary.Renderer.thisMac)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    HStack(spacing: 6) {
                        Text(renderer == .homeServer ? "Home server" : "This Mac")
                        if let note = BookVoiceSettings.sheetNote(makeBooksOn, homeServerAvailable: homeServerAvailable) {
                            Text(note).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .font(.callout)

        HStack {
            Text(cast.holdsTheBook
                 ? "Check the cast before the book is made."
                 : renderer == .homeServer
                 ? "Your home server makes it, so this Mac can sleep. Chapter 1 is ready in a minute or two."
                 : "Chapter 1 is ready in a minute or two, and the rest follows while you listen.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if sentFrom != nil {
                Button("Discard") { onDiscard(); onDone() }
                Button("Not Now", action: onDone).keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
            }
            Button("Make Audiobook") { submit(document, voice: chosen ?? voice) }
                .keyboardShortcut(.defaultAction)
                .disabled(submitting || document.chapters.isEmpty || cast.holdsTheBook)
        }
    }

    /// The suggested narrator and two alternates, each one click to choose and one to hear.
    @ViewBuilder
    private func narrator(_ document: ImportedDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Narrator").font(.callout).foregroundStyle(.secondary)
            if let suggestion {
                Text(Self.suggestionLine(suggestion))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach([suggestion.primary] + suggestion.alternates, id: \.self) { voice in
                    HStack(spacing: 8) {
                        Button {
                            chosen = voice
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: chosen == voice ? "largecircle.fill.circle" : "circle")
                                Text(Self.voiceLabel(voice))
                                if voice == suggestion.primary && !suggestion.isFallback {
                                    Text("suggested").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            preview.toggle(voice, text: VoiceSuggestions.previewText(for: document))
                        } label: {
                            Image(systemName: preview.playing == voice ? "stop.circle" : "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(preview.playing == voice ? "Stop" : "Hear \(Self.voiceLabel(voice))")
                    }
                    .font(.callout)
                }
                if let failure = preview.failure {
                    Text(failure).font(.caption).foregroundStyle(.orange)
                }
                if let consentAsk {
                    CloudModelConsentAsk(source: consentAsk) { answer($0, for: consentAsk, document: document) }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Choosing a voice that suits the book…").font(.callout)
                }
            }
        }
        .task(id: document.sourceSHA256) {
            guard suggestion == nil else { return }
            await suggestNarrator(document)
        }
    }

    private func suggestNarrator(_ document: ImportedDocument) async {
        let found = await VoiceSuggestions.suggestLive(
            for: document, languageDefault: DocumentLibrary.languageDefaultVoice(for: document), allowingOnce: allowedOnce)
        suggestion = found.suggestion
        chosen = found.suggestion.primary
        let ledger = CloudModelConsent.ledger()
        consentAsk = VoiceSuggestions.sourceToAsk(fellBack: found.suggestion.isFallback, routing: found.routing,
                                                  hasAnswered: { ledger.hasAnswered($0, ModelTask.voiceSuggestion.content) })
    }

    /// The person's answer to the first-use ask. "Not now" is recorded and the default stays;
    /// "Always" and "Allow once" ask again with that source allowed, and the pronunciation
    /// proposal follows the new suggestion as it always does.
    private func answer(_ answer: CloudModelConsentAsk.Answer, for source: ModelSource, document: ImportedDocument) {
        consentAsk = nil
        guard CloudModelConsent.record(answer, for: source, in: CloudModelConsent.ledger()) else { return }
        if answer == .once { allowedOnce = source }
        suggestion = nil
        chosen = nil
        proposedLexicon = nil
        lexiconRows = []
        lexiconLine = nil
        Task { await suggestNarrator(document) }
    }

    /// The words a model thinks the voice would get wrong, proposed after the narrator is, each
    /// correctable here; what is left when the book is made goes with it as its lexicon.
    @ViewBuilder
    private func pronunciations(_ document: ImportedDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pronunciations").font(.callout).foregroundStyle(.secondary)
            if let lexiconLine {
                Text(lexiconLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if lexiconLine == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for names a voice might stumble on…").font(.callout)
                }
            } else if lexiconRows.count > 6 {
                // A novel's list (24 words for Pride and Prejudice) ran the sheet past the bottom
                // of the window, taking "Voice the dialogue" and Make Audiobook with it.
                ScrollView { PronunciationListView(rows: $lexiconRows).padding(.trailing, 12) }
                    .frame(height: 240)
            } else if !lexiconRows.isEmpty || suggestion != nil {
                PronunciationListView(rows: $lexiconRows)
            }
        }
        .task(id: suggestion == nil ? "" : document.sourceSHA256) {
            // After the narrator, so the two do not queue on one small model at once.
            guard suggestion != nil, lexiconLine == nil else { return }
            await proposeLexicon(document)
        }
    }

    private func proposeLexicon(_ document: ImportedDocument) async {
        let routing = await VoiceSuggestions.liveRouting()
        guard !Task.isCancelled else { return }
        let router = routing.router()
        guard !router.plan(for: PronunciationEditing.modelTask).usable.isEmpty else {
            lexiconLine = PronunciationEditing.noModelLine(router: router)
            return
        }
        let executor = routing.executor
        let proposal = await PronunciationLexicon.propose(for: document, isWord: PronunciationEditing.isWord) { system, user in
            try await router.complete(PronunciationEditing.modelTask, system: system, user: user, executor: executor)
        }
        // Superseded: the person answered the cloud ask and a new suggestion is on its way, with
        // its own proposal after it.
        guard !Task.isCancelled else { return }
        proposedLexicon = proposal.lexicon.isEmpty ? nil : proposal.lexicon
        lexiconRows = PronunciationEditing.rows(proposedLexicon)
        if let source = proposal.source {
            lexiconLine = lexiconRows.isEmpty
                ? "\(source) found no names the voice would get wrong. Add any below."
                : "Proposed by \(source). Correct any that are wrong; Kokoro reads these as written."
        } else {
            lexiconLine = "No model answered, so names are read as written. Add any below."
        }
    }

    /// One line above the three voices: who suggested it and why, or why it is the default.
    static func suggestionLine(_ suggestion: VoiceSuggestion) -> String {
        if let reason = suggestion.fallbackReason {
            return "The default voice for the book's language, because \(reason)."
        }
        let source = suggestion.source ?? "a model"
        return suggestion.rationale.isEmpty ? "Suggested by \(source)." : "Suggested by \(source): \(suggestion.rationale)"
    }

    private func read() async {
        do {
            let document = DocumentLibrary.isWebLink(url)
                ? try await DocumentLibrary.importDocument(fromWeb: url)
                : try await DocumentLibrary.importDocument(at: url)
            phase = .ready(document, voice: DocumentLibrary.languageDefaultVoice(for: document))
        } catch let failure as DocumentImporter.Failure {
            phase = .failed(failure.description)
        } catch {
            let what = DocumentLibrary.isWebLink(url) ? "link" : "file"
            phase = .failed("The \(what) could not be read: \(error.localizedDescription)")
        }
    }

    private func submit(_ document: ImportedDocument, voice: String) {
        submitting = true
        preview.stop()
        // The suggested speed goes with the suggested voice; the suggestion's tone is the book's,
        // and styles a Chatterbox narrator whichever one is chosen (M8.7).
        // With a checked cast, each attributed quote in its speaker's voice (G4); otherwise the
        // narrator-only book, unchanged. The rules read the whole book for a cast (seconds for a
        // novel), so the book is shaped off the main thread.
        let plan = VoicePlan.forBook(narrator: voice, suggestion: suggestion)
        let choice = cast
        let lexicon = PronunciationEditing.lexicon(from: lexiconRows, original: proposedLexicon)
        Task {
            var book = await Task.detached(priority: .userInitiated) {
                DialogueCastEditing.book(document, plan: plan, choice: choice)
            }.value
            book.lexicon = lexicon
            do {
                try await library.submit(book, on: renderer)
                onImported()
                onDone()
            } catch {
                phase = .failed("The book could not be started: \(error.localizedDescription)")
                submitting = false
            }
        }
    }

    // MARK: - Words

    /// "bf_emma on Kokoro".
    static func voiceLabel(_ spec: String) -> String {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return spec }
        return "\(parts[1]) on \(parts[0].prefix(1).uppercased() + parts[0].dropFirst())"
    }

    /// A warning in plain words: one wording for both apps (`Shared/HomeServerBooks.swift`).
    static func text(for warning: ImportWarning) -> String { warning.listenerText }

    static func pageList(_ pages: [Int]) -> String { ImportWarning.pageList(pages) }
}
