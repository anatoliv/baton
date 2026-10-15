import AVFoundation
import BatonDocuments
import SwiftUI

/// What Baton found in a file or a link, before anything is made from it (M5.2), and the one
/// button that sends it to the home server. The Mac's import sheet in a phone's idiom.
///
/// Everything the import knows is shown: title and author, the chapters, what was set aside,
/// every warning, and what the book will cost in time and space. The phone has one renderer,
/// the home server, so with none set up the screen says so plainly instead of offering a button
/// that would fail.
struct DocumentImportScreen: View {
    let url: URL
    let model: MobileModel
    let onDone: () -> Void

    private enum Phase {
        case reading
        case failed(String)
        case ready(ImportedDocument, voice: String)
    }

    @State private var phase = Phase.reading
    @State private var submitting = false
    @State private var homeServer: Bool?   // nil until asked
    /// What the home server said, for what to offer instead when it cannot make the book.
    @State private var availability: HomeServerBooks.Availability?
    @State private var preview: AVAudioPlayer?
    @State private var previewing = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .reading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading \(MobileDocuments.isWebLink(url) ? (url.host ?? url.absoluteString) : url.lastPathComponent)…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
                case let .ready(document, voice):
                    details(document, voice: voice)
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
            }
        }
        .task { await read() }
        .task {
            let answer = await model.books.availability()
            availability = answer
            homeServer = answer == .available
        }
        .onDisappear { preview?.stop() }
        .interactiveDismissDisabled(submitting)
    }

    @ViewBuilder
    private func details(_ document: ImportedDocument, voice: String) -> some View {
        let estimate = ListeningEstimate(document)
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title).font(.title3.weight(.semibold))
                    if let author = document.author { Text("by \(author)").foregroundStyle(.secondary) }
                    Text(Self.estimateLine(estimate))
                        .font(.callout).padding(.top, 4)
                }
                .accessibilityElement(children: .combine)
            }

            Section(document.chapters.count == 1 ? "1 chapter" : "\(document.chapters.count) chapters") {
                ForEach(document.chapters, id: \.index) { chapter in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(chapter.index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Text(chapter.title).lineLimit(2)
                    }
                }
            }

            if !document.frontMatter.isEmpty {
                Section("Set aside from the reading") {
                    ForEach(document.frontMatter, id: \.self) { Text($0).font(.footnote).lineLimit(3) }
                }
            }

            if !document.warnings.isEmpty {
                Section {
                    ForEach(Array(document.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(Self.text(for: warning), systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }

            Section("Narrator") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.voiceLabel(voice))
                        Text("The default voice for the book's language.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if homeServer == true {
                        Button {
                            Task { await playPreview(document, voice: voice) }
                        } label: {
                            Image(systemName: previewing ? "stop.circle" : "play.circle").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(previewing ? "Stop the preview" : "Hear this voice")
                    }
                }
            }

            Section {
                switch homeServer {
                case nil:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking your home server…") }
                        .foregroundStyle(.secondary)
                case .some(true):
                    Button {
                        submit(document, voice: voice)
                    } label: {
                        HStack {
                            Spacer()
                            if submitting { ProgressView().controlSize(.small).padding(.trailing, 6) }
                            Text("Make Audiobook").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(submitting)
                    .accessibilityIdentifier("make-audiobook")
                case .some(false):
                    // Send to my Mac, or AirDrop to it.
                    SendToMacSection(offer: ImportOffer(availability), source: url, title: document.title,
                                     problem: model.books.problem, model: model, onDone: onDone)
                }
            } footer: {
                if homeServer == true {
                    Text("Your home server makes it, so this phone can be put away. Chapter 1 is ready in a minute or two, and arrives in Clippings.")
                }
            }
        }
    }

    private func read() async {
        do {
            let document = MobileDocuments.isWebLink(url)
                ? try await MobileDocuments.importDocument(fromWeb: url)
                : try await MobileDocuments.importDocument(at: url)
            phase = .ready(document, voice: DocumentVoices.languageDefault(for: document))
        } catch let failure as DocumentImporter.Failure {
            phase = .failed(failure.description)
        } catch {
            let what = MobileDocuments.isWebLink(url) ? "link" : "file"
            phase = .failed("The \(what) could not be read: \(error.localizedDescription)")
        }
    }

    private func submit(_ document: ImportedDocument, voice: String) {
        submitting = true
        preview?.stop()
        // The phone has no voice suggestion yet, so no tone to style a Chatterbox narrator with;
        // the shared plan carries one the day it does (M8.7).
        let book = DocumentSpeech.prepare(document, voices: .forBook(narrator: voice))
        Task {
            do {
                try await model.books.submit(book)
                MobileDocuments.scheduleRefresh()
                // Asked after the book is on its way: a permission prompt must never stand
                // between Make Audiobook and the home server.
                await MobileDocuments.requestNotificationPermission()
                // Keep asking while the home server makes chapter 1, whether or not Clippings is
                // on screen: the row should move from "Waiting" to "Making" to ready by itself.
                model.books.watchIfNeeded { }
                onDone()
            } catch {
                phase = .failed("The book could not be started: \(error.localizedDescription)")
                submitting = false
            }
        }
    }

    /// A few seconds of the book's own opening in this voice, made by the home server.
    private func playPreview(_ document: ImportedDocument, voice: String) async {
        if previewing { preview?.stop(); previewing = false; return }
        guard let client = model.gatewayBookClient() else { return }
        let opening = document.chapters.first?.paragraphs.first.map { String($0.prefix(160)) } ?? document.title
        do {
            let wav = try await client.preview(text: opening, voice: voice)
            let player = try AVAudioPlayer(data: wav)
            preview = player
            previewing = true
            player.play()
            try? await Task.sleep(for: .seconds(player.duration))
            previewing = false
        } catch {
            previewing = false
        }
    }

    /// "About 1 h 11 m of audio. About 25 MB." A short text's estimate is "under a minute", which
    /// takes no "About" in front of it.
    static func estimateLine(_ estimate: ListeningEstimate) -> String {
        let length = estimate.durationText.lowercased().hasPrefix("under")
            ? estimate.durationText.prefix(1).uppercased() + estimate.durationText.dropFirst()
            : "About \(estimate.durationText)"
        return "\(length) of audio. About \(estimate.sizeText)."
    }

    /// "bf_emma on Kokoro".
    static func voiceLabel(_ spec: String) -> String {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return spec }
        return "\(parts[1]) on \(parts[0].prefix(1).uppercased() + parts[0].dropFirst())"
    }

    static func text(for warning: ImportWarning) -> String { warning.listenerText }
}
