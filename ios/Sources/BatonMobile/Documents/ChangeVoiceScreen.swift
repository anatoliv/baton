import AVFoundation
import BatonDocuments
import SwiftUI

/// Change Voice… on a book: the import screen's narrator choice again, from the
/// voices the home server offers (`GET /v1/voices`), each playable in the book's own words. The
/// home server makes the whole book again; each chapter here plays in its old voice until its new
/// one comes down and takes its place, and the place in the book is kept.
struct ChangeVoiceScreen: View {
    let book: MobileBookShelf.Book
    let model: MobileModel
    let onDone: () -> Void

    @State private var voices: [String]?
    @State private var loaded = false
    @State private var chosen: String?
    @State private var working = false
    @State private var failure: String?
    @State private var preview: AVAudioPlayer?
    @State private var previewing: String?

    private var prepared: PreparedBook? { book.jobID.flatMap(model.books.preparedBook(forJob:)) }
    private var current: String? { prepared?.voices.narrator }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let current {
                        Text("Now read by \(DocumentImportScreen.voiceLabel(current)).").foregroundStyle(.secondary)
                    }
                    if prepared?.hasCast == true {
                        Label(BookVoiceChanges.castNote, systemImage: "person.2").font(.callout)
                    }
                } header: {
                    Text(book.title)
                }
                Section {
                    if !loaded {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking your Baton server…") }
                            .foregroundStyle(.secondary)
                    } else if let voices, !voices.isEmpty {
                        ForEach(voices, id: \.self) { voice in
                            NarratorOptionRow(voice: voice, chosen: $chosen, playing: previewing == voice,
                                              detail: BookVoiceChanges.description(voice),
                                              tag: voice == current ? "now" : nil) {
                                Task { await playPreview(voice) }
                            }
                        }
                    } else {
                        Label("Your Baton server did not list its voices, so there are none to choose from.",
                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } header: {
                    Text("Narrator")
                } footer: {
                    Text("Choose a voice, then Make Again. Your Baton server makes the whole book again. Each chapter plays in its old voice until its new one is here, and your place is kept.")
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Change Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                // In the bar rather than below the list: the home server can offer dozens of voices.
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Make Again") { apply() }
                            .fontWeight(.semibold)
                            .disabled(chosen == nil || chosen == current)
                            .accessibilityIdentifier("make-again")
                    }
                }
            }
        }
        .task {
            voices = await model.books.voices().map {
                BookVoiceChanges.choices(current: current, language: prepared?.language, available: $0)
            }
            loaded = true
        }
        .onDisappear { preview?.stop() }
        .interactiveDismissDisabled(working)
    }

    private func apply() {
        guard let chosen, let jobID = book.jobID else { return }
        working = true
        preview?.stop()
        Task {
            do {
                let newID = try await model.books.changeVoice(jobID: jobID, to: chosen)
                if book.finished, newID != jobID { await model.books.markFinished(jobID: newID) }
                MobileDocuments.scheduleRefresh()
                model.books.watchIfNeeded { }
                onDone()
            } catch {
                failure = "It could not be made again: \(error)."
                working = false
            }
        }
    }

    /// A few seconds of the book's opening in this voice, made by the home server, as the import
    /// screen plays one.
    private func playPreview(_ voice: String) async {
        let wasPlaying = previewing
        preview?.stop()
        previewing = nil
        if wasPlaying == voice { return }
        guard let client = model.gatewayBookClient() else { return }
        let opening = prepared?.chapters.lazy.flatMap(\.segments).first { $0.kind != .heading }
            .map { String($0.text.prefix(160)) } ?? book.title
        do {
            let wav = try await client.preview(text: opening, voice: voice)
            let player = try AVAudioPlayer(data: wav)
            preview = player
            previewing = voice
            player.play()
            try? await Task.sleep(for: .seconds(player.duration))
            if previewing == voice, preview === player { previewing = nil }
        } catch {
            if previewing == voice { previewing = nil }
        }
    }
}
