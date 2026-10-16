import AVFoundation
import BatonDocuments
import BatonSubsonicKit
import SwiftUI

/// Change Voice… on a book: the import screen's narrator choice again, from the
/// voices the home server offers (`GET /v1/voices`), each playable in the book's own words. The
/// home server makes the whole book again; each chapter here plays in its old voice until its new
/// one comes down and takes its place, and the place in the book is kept. The same picker as the
/// import screen: the best voices for the language on top, every voice under All
/// voices.
struct ChangeVoiceScreen: View {
    let book: MobileBookShelf.Book
    let model: MobileModel
    let onDone: () -> Void

    @State private var listing = VoiceListing(voices: nil)
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
                        Text("Now read by \(VoiceDirectory.entry(current).label).").foregroundStyle(.secondary)
                    }
                    if prepared?.hasCast == true {
                        Label(BookVoiceChanges.castNote, systemImage: "person.2").font(.callout)
                    }
                } header: {
                    Text(book.title)
                }
                if !loaded {
                    Section("Narrator") {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking your Baton server…") }
                            .foregroundStyle(.secondary)
                    }
                } else if suggested.isEmpty {
                    Section("Narrator") {
                        Label("Your Baton server did not list its voices, so there are none to choose from.",
                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } else {
                    VoicePicker(suggested: suggested, all: listing.voices, unavailable: listing.problem,
                                chosen: $chosen, playing: previewing, title: "Narrator",
                                footer: "Choose a voice, then Make Again. Your Baton server makes the whole book again. Each chapter plays in its old voice until its new one is here, and your place is kept.",
                                tag: { voice in
                                    if voice == current { return "now" }
                                    return voice == remembered ? "last used" : nil
                                },
                                detail: BookVoiceChanges.suits,
                                onPreview: { voice in Task { await playPreview(voice) } })
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
            listing = await model.books.voiceListing()
            loaded = true
        }
        .onDisappear { preview?.stop() }
        .interactiveDismissDisabled(working)
    }

    /// The voice it has now, then the best for its language (`BookVoiceChanges.choices`), and
    /// the one last chosen for that language; the voice it has alone when no list came.
    private var suggested: [String] {
        guard let all = listing.voices, !all.isEmpty else { return current.map { [$0] } ?? [] }
        let best = Array(BookVoiceChanges.choices(current: current, language: prepared?.language, available: all).prefix(4))
        return VoiceDirectory.suggested(best, remembered: remembered, available: all)
    }

    private var remembered: String? {
        guard let last = VoiceChoiceMemory(defaults: BatonStorage.defaults).last(language: prepared?.language),
              last != current, listing.voices?.contains(last) == true else { return nil }
        return last
    }

    private func apply() {
        guard let chosen, let jobID = book.jobID else { return }
        VoiceChoiceMemory(defaults: BatonStorage.defaults).remember(chosen, language: prepared?.language)
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
