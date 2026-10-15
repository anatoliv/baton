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
                    Button("Close", action: onDone).keyboardShortcut(.cancelAction)
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
            if homeServerAvailable { renderer = .homeServer }
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

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Made on").foregroundStyle(.secondary)
                if homeServerAvailable {
                    Picker("Made on", selection: $renderer) {
                        Text("Home server").tag(DocumentLibrary.Renderer.homeServer)
                        Text("This Mac").tag(DocumentLibrary.Renderer.thisMac)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text("This Mac")
                }
            }
        }
        .font(.callout)

        HStack {
            Text(renderer == .homeServer
                 ? "Your home server makes it, so this Mac can sleep. Chapter 1 is ready in a minute or two."
                 : "Chapter 1 is ready in a minute or two, and the rest follows while you listen.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
            Button("Make Audiobook") { submit(document, voice: chosen ?? voice) }
                .keyboardShortcut(.defaultAction)
                .disabled(submitting || document.chapters.isEmpty)
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
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Choosing a voice that suits the book…").font(.callout)
                }
            }
        }
        .task(id: document.sourceSHA256) {
            guard suggestion == nil else { return }
            let found = await VoiceSuggestions.suggestLive(
                for: document, languageDefault: DocumentLibrary.languageDefaultVoice(for: document))
            suggestion = found
            chosen = found.primary
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
            phase = .failed("The file could not be read: \(error.localizedDescription)")
        }
    }

    private func submit(_ document: ImportedDocument, voice: String) {
        submitting = true
        preview.stop()
        // The suggested speed belongs to the suggested voice; another choice reads at its own pace.
        let speed = voice == suggestion?.primary && suggestion?.isFallback == false ? suggestion?.speed : nil
        let book = DocumentSpeech.prepare(document, voices: VoicePlan(narrator: voice, speed: speed))
        Task {
            do {
                try await library.submit(book, on: renderer)
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
