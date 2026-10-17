import BatonDocuments
import BatonSubsonicKit
import BatonPlaybackKit
import SwiftUI

/// Change Voice…: the import sheet's narrator choice again, for a book already made
/// or a kept reading, each voice playable in its own words before anything is made again. The
/// same picker as the import sheet: the best voices for the language on top, every
/// voice the renderer offers under All voices.
struct ChangeVoiceSheet: View {
    /// What is being given a new voice, and how.
    struct Target {
        var title: String
        /// The voice it has now, when known.
        var current: String?
        var language: String?
        /// Said above the voices: for a book with a cast, that only the narrator changes.
        var note: String?
        /// Said beside the button: where it is made and what happens meanwhile.
        var footnote: String
        var previewText: String
        var preview: VoicePreviewPlayer
        /// The voices it can have, or why there are none.
        var loadVoices: @MainActor () async -> VoiceListing
        var apply: @MainActor (String) async throws -> Void
        /// A book's narrator is remembered for its language; a reading's voice is not.
        var remembers = false
        /// A book's cast: Voice the dialogue turned on, edited or turned off here.
        var cast: Cast?
    }

    /// The book as it is and how to make it again, for Voice the dialogue.
    struct Cast {
        var book: PreparedBook
        /// Its words, for a cast proposed now.
        var words: ImportedDocument
        var previewOnServer: Bool
        var apply: @MainActor (PreparedBook) async throws -> Void
    }

    let target: Target
    let onDone: () -> Void

    @State private var listing = VoiceListing(voices: nil)
    @State private var loaded = false
    @State private var chosen: String?
    @State private var working = false
    @State private var failure: String?
    @State private var castChange: DialogueCastFlow.Change?

    /// Whether Make Again would change anything: the narrator, or the cast.
    private var changes: Bool {
        guard let chosen else { return false }
        return castChange?.changes(narrator: chosen) ?? (chosen != target.current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.title).font(.title3.weight(.semibold)).lineLimit(2)
            if let current = target.current {
                Text("Now read by \(VoiceDirectory.entry(current).label).").font(.callout).foregroundStyle(.secondary)
            }
            if let note = target.note {
                Label(note, systemImage: "person.2").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking for the voices…").font(.callout)
                }
            } else if suggested.isEmpty {
                Label("No voice server answered, so there are no voices to choose from. Check the voice server in Settings, under Speech.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                VoicePicker(suggested: suggested, all: listing.voices, unavailable: listing.problem,
                            chosen: $chosen, playing: target.preview.playing,
                            tag: { voice in
                                if voice == target.current { return "now" }
                                return voice == remembered ? "last used" : nil
                            },
                            detail: BookVoiceChanges.suits,
                            onPreview: { target.preview.toggle($0, text: target.previewText) })
            }
            if let cast = target.cast, loaded, castChange != nil {
                ChangeVoiceCastSection(change: Binding(get: { castChange! }, set: { castChange = $0 }),
                                       words: cast.words, narrator: chosen ?? target.current ?? cast.book.voices.narrator,
                                       voices: listing.voices, previewOnServer: cast.previewOnServer,
                                       previewFallback: target.previewText)
            }
            if let failure = target.preview.failure ?? failure {
                Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(target.footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Make Again in This Voice") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !changes || castChange?.holdsTheBook == true)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            if let cast = target.cast { castChange = DialogueCastFlow.Change(cast.book) }
            if chosen == nil { chosen = target.current }
            listing = await target.loadVoices()
            loaded = true
        }
        .onDisappear { target.preview.stop() }
    }

    /// The voice it has now, then the best for its language (`BookVoiceChanges.choices`), and
    /// the one last chosen for that language; the voice it has alone when no list came.
    private var suggested: [String] {
        guard let all = listing.voices, !all.isEmpty else { return target.current.map { [$0] } ?? [] }
        let best = Array(BookVoiceChanges.choices(current: target.current, language: target.language, available: all).prefix(4))
        return VoiceDirectory.suggested(best, remembered: remembered, available: all)
    }

    private var remembered: String? {
        guard target.remembers, let last = VoiceChoiceMemory(defaults: BatonStorage.defaults).last(language: target.language),
              last != target.current, listing.voices?.contains(last) == true else { return nil }
        return last
    }

    private func apply() {
        guard let chosen else { return }
        if target.remembers { VoiceChoiceMemory(defaults: BatonStorage.defaults).remember(chosen, language: target.language) }
        working = true
        target.preview.stop()
        let remade = castChange.map { $0.book(narrator: chosen) }
        Task {
            do {
                if let remade, let cast = target.cast { try await cast.apply(remade) } else { try await target.apply(chosen) }
                onDone()
            } catch {
                failure = "It could not be made again: \(error)."
                working = false
            }
        }
    }
}

extension ChangeVoiceSheet.Target {
    /// A book on this Mac, made here or on the home server.
    @MainActor
    static func book(_ book: BookShelf.Book, library: DocumentLibrary) -> ChangeVoiceSheet.Target? {
        guard let source = library.pronunciationSource(documentID: book.documentID) else { return nil }
        let voices = (plan: source.book.voices, hasCast: source.book.hasCast, renderer: source.renderer)
        let homeServer = voices.renderer == .homeServer
        let prepared = source.book
        return .init(
            title: "Change the voice of \(book.title)",
            current: voices.plan.narrator,
            language: library.pronunciationSource(documentID: book.documentID)?.book.language,
            note: nil,
            footnote: homeServer
                ? "Your Baton server makes the whole book again. Each chapter plays in its old voice until its new one is here, and your place is kept."
                : "This Mac makes the whole book again. Each chapter plays in its old voice until its new one is here, and your place is kept.",
            previewText: library.previewText(of: book),
            preview: homeServer ? VoicePreviewPlayer.batonServer() : VoicePreviewPlayer(),
            loadVoices: {
                homeServer ? await library.homeServer.voiceListing() : await VoiceSuggestions.thisMacListing()
            },
            apply: { voice in try await library.changeVoice(book, to: voice) },
            remembers: true,
            cast: ChangeVoiceSheet.Cast(book: prepared, words: prepared.spokenDocument, previewOnServer: homeServer,
                       apply: { updated in try await library.changeVoice(book, to: updated) }))
    }

    /// A kept reading, read again by the voice server.
    @MainActor
    static func reading(_ item: ClippingStore.Item, store: ClippingStore, revoicer: ClippingRevoicer,
                        failed: @escaping @MainActor (Error) -> Void) -> ChangeVoiceSheet.Target {
        let words = item.clipping.text ?? item.clipping.title
        return .init(
            title: "Change the voice of \(item.clipping.title)",
            current: item.clipping.voice,
            language: nil,
            note: nil,
            footnote: "The voice server reads it again. It plays in its old voice until the new one is ready.",
            previewText: String(words.prefix(200)),
            preview: VoicePreviewPlayer(synthesize: { text, voice in
                guard let speech = ClippingRevoicer.speechVoice(voice) else { throw ClippingRevoicer.Problem.notAServerVoice(voice) }
                return try await SpeechService.synthesize(text: text, voice: speech)
            }),
            loadVoices: {
                let voices = await VoiceSuggestions.availableVoices(builtIn: [], engine: .server)
                return VoiceListing(voices: voices.isEmpty ? nil : voices,
                                    problem: "Only the voice it has is here, because no voice server answered. Check it in Settings, under Speech.")
            },
            apply: { voice in
                revoicer.start(item, voice: voice, in: store) { error in if let error { failed(error) } }
            })
    }
}

/// Voice the dialogue in Change Voice…. A book with a cast shows it to edit (rename,
/// merge, another voice, not a speaker) or to turn off; a book without one can be given one,
/// proposed and checked exactly as at import. A new narrator keeps the cast.
struct ChangeVoiceCastSection: View {
    @Binding var change: DialogueCastFlow.Change
    let words: ImportedDocument
    let narrator: String
    /// The renderer's voices, the same list the narrator is chosen from.
    let voices: [String]?
    let previewOnServer: Bool
    let previewFallback: String
    @State private var editing = false

    var body: some View {
        if change.hadCast {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Voice the dialogue", isOn: $change.choice.isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityIdentifier("voice-the-dialogue")
                if change.choice.isOn, let edited = change.edited {
                    HStack(alignment: .firstTextBaseline) {
                        Text(DialogueCastFlow.summary(edited, narrator: narrator, reviewed: true)
                             + (change.changesCast ? " Changed: Make Again to hear it." : ""))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Edit Cast…") { editing = true }
                            .accessibilityIdentifier("check-the-cast")
                    }
                } else {
                    Text("One narrator reads everything: Make Again to take the cast's voices away.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .sheet(isPresented: $editing) {
                if let edited = change.edited {
                    CastSheetEditor(casting: edited, narrator: narrator, voices: offered(edited),
                                    previewFallback: previewFallback,
                                    preview: previewOnServer ? .batonServer() : VoicePreviewPlayer(),
                                    intro: "The cast this book was made with. Rename, merge or remove a speaker, or give one another voice: each line keeps its speaker. ",
                                    showsPhrases: false) { done in
                        change.edited = done
                        editing = false
                    } onCancel: {
                        editing = false
                    }
                }
            }
        } else {
            let offered = voices ?? []
            DialogueCastSection(document: words, narrator: narrator, modelFree: true, choice: $change.choice,
                                rendererVoices: voices, previewOnServer: previewOnServer, remembers: false,
                                offeredVoices: voices == nil ? nil : { @Sendable in offered })
        }
    }

    /// The voices a speaker can have: the renderer's, and the ones the cast already has.
    private func offered(_ casting: DialogueCast.Casting) -> [String] {
        var list = voices ?? []
        for voice in casting.speakers.compactMap(\.voice) where !list.contains(voice) { list.append(voice) }
        return list
    }
}
