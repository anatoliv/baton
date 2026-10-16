import BatonDocuments
import BatonPlaybackKit
import SwiftUI

/// Change Voice…: the import sheet's narrator choice again, for a book already made
/// or a kept reading, each voice playable in its own words before anything is made again.
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
        /// The voices it can have; nil when nothing answered.
        var loadVoices: @MainActor () async -> [String]?
        var apply: @MainActor (String) async throws -> Void
    }

    let target: Target
    let onDone: () -> Void

    @State private var voices: [String]?
    @State private var loaded = false
    @State private var chosen: String?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.title).font(.title3.weight(.semibold)).lineLimit(2)
            if let current = target.current {
                Text("Now read by \(DocumentImportSheet.voiceLabel(current)).").font(.callout).foregroundStyle(.secondary)
            }
            if let note = target.note {
                Label(note, systemImage: "person.2").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking for the voices…").font(.callout)
                }
            } else if let voices, !voices.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(voices, id: \.self) { voice in
                            NarratorOptionRow(voice: voice, chosen: $chosen, preview: target.preview,
                                              previewText: target.previewText,
                                              tag: voice == target.current ? "now" : nil,
                                              detail: BookVoiceChanges.description(voice))
                        }
                    }
                    .padding(.trailing, 12)
                }
                .frame(maxHeight: 300)
            } else {
                Label("No voice server answered, so there are no voices to choose from. Check the voice server in Settings, under Speech.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
                    .disabled(working || chosen == nil || chosen == target.current)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            voices = await target.loadVoices().map {
                BookVoiceChanges.choices(current: target.current, language: target.language, available: $0)
            }
            loaded = true
        }
        .onDisappear { target.preview.stop() }
    }

    private func apply() {
        guard let chosen else { return }
        working = true
        target.preview.stop()
        Task {
            do {
                try await target.apply(chosen)
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
        guard let voices = library.voices(of: book) else { return nil }
        let homeServer = voices.renderer == .homeServer
        return .init(
            title: "Change the voice of \(book.title)",
            current: voices.plan.narrator,
            language: library.pronunciationSource(documentID: book.documentID)?.book.language,
            note: voices.hasCast ? BookVoiceChanges.castNote : nil,
            footnote: homeServer
                ? "Your Baton server makes the whole book again. Each chapter plays in its old voice until its new one is here, and your place is kept."
                : "This Mac makes the whole book again. Each chapter plays in its old voice until its new one is here, and your place is kept.",
            previewText: library.previewText(of: book),
            preview: homeServer
                ? VoicePreviewPlayer(synthesize: { text, voice in
                    guard let client = await MainActor.run(body: { DocumentLibrary.configuredGateway() }) else {
                        throw SynthesisError.transient("the Baton server is not set up in Settings")
                    }
                    return try await client.preview(text: text, voice: voice)
                })
                : VoicePreviewPlayer(),
            loadVoices: {
                homeServer ? await library.homeServer.voices() : await VoiceSuggestions.availableVoices()
            },
            apply: { voice in try await library.changeVoice(book, to: voice) })
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
                return voices.isEmpty ? nil : voices
            },
            apply: { voice in
                revoicer.start(item, voice: voice, in: store) { error in if let error { failed(error) } }
            })
    }
}
