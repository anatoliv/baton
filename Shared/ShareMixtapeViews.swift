import BatonShareKit
import BatonSubsonicModels
import SwiftUI

struct MixtapeSelectionDraft: Identifiable {
    let id = UUID()
    let songs: [NavidromeSong]
}

/// The screen freezes the selected display order. Editing this draft has no
/// network/upload effect until its explicit Create Link action.
struct ShareMixtapeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SongSharing.fromKey) private var from = ""
    @AppStorage(SongSharing.disclosureKey) private var disclosureSeen = false
    @State private var songs: [NavidromeSong]
    @State private var title = "Mixtape"
    @State private var note = ""
    @State private var expiry = ShareLimits.standard.defaultExpirySeconds
    @State private var showsDetails = false
    @State private var reviewPreservation = false
    @State private var working = false
    @State private var handedOff = false
    @State private var error: String?
    @State private var result: ShareLedger.Record?
    @State private var supported = false
    @State private var pendingJob: UUID?
    init(songs: [NavidromeSong]) { _songs = State(initialValue: songs) }

    var body: some View {
        NavigationStack {
            Form {
                if let result, let url = URL(string: result.link) {
                    Section {
                        Text(result.link).font(.callout.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("mixtape.result-link")
                        ShareLink(item: url, subject: Text(result.title)) { Label("Send…", systemImage: "square.and.arrow.up") }
                        Button("Copy Link") { SharedLinkPasteboard.copy(result.link) }
                    } footer: { Text("Find this mixtape again in Settings → Shared Links.") }
                } else {
                    Section {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(index + 1). \(song.title)")
                                    Text(song.displayArtistName ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { songs.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                    .disabled(index == 0 || working || pendingJob != nil).accessibilityLabel("Move \(song.title) up")
                                Button { songs.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                    .disabled(index == songs.count - 1 || working || pendingJob != nil).accessibilityLabel("Move \(song.title) down")
                                Button(role: .destructive) { songs.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                    .disabled(working || pendingJob != nil).accessibilityLabel("Remove \(song.title)")
                            }
                            .buttonStyle(.borderless)
                        }
                    } header: { Text("Track order") } footer: { Text("Choose 2 to 12 tracks, up to 20 minutes and 25 MiB of encrypted audio in total. Track titles stay encrypted.") }
                    Section {
                        TextField("Mixtape title", text: $title).accessibilityIdentifier("mixtape.title")
                        TextField("From", text: $from).accessibilityIdentifier("mixtape.from")
                        TextField("Note (optional)", text: $note, axis: .vertical).accessibilityIdentifier("mixtape.note")
                        Picker("Link lasts", selection: $expiry) {
                            Text("1 day").tag(86400); Text("7 days").tag(604800); Text("30 days").tag(2592000)
                        }
                        Toggle("Show mixtape title and note in link previews", isOn: $showsDetails).accessibilityIdentifier("mixtape.public-preview")
                    }.disabled(working || pendingJob != nil)
                    Section {
                        Toggle("Allow private preservation during review", isOn: $reviewPreservation)
                            .accessibilityIdentifier("mixtape-review-preservation")
                            .disabled(working || pendingJob != nil)
                    } footer: {
                        Text("If disabled for review, the encrypted mixtape may be kept privately for up to 90 days from disable. It counts toward quota while its remaining link lifetime pauses. Reviewed restoration keeps spent plays spent. Revoke deletes the server copy. Leave this off for ordinary expiry.")
                    }
                    if !disclosureSeen {
                        Section { Text("Create Link uploads an encrypted copy of these tracks to Baton's share service. It is deleted at expiry unless you allow review preservation above. The service cannot play it; the key is in the link you send.") }
                    }
                    if working { Section { ProgressView(SongSharing.shared.stage?.label ?? "Preparing…") } }
                    if let error { Section { Text(error).foregroundStyle(.secondary) } }
                    if !supported { Section { Text("Mixtape sharing is unavailable until the service supports it.") } }
                }
            }
            .formStyle(.grouped).navigationTitle("Share Mixtape")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result != nil || handedOff ? "Done" : "Cancel") { dismiss() }.disabled(working && !handedOff)
                }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(pendingJob == nil ? "Create Link" : "Retry Upload") { Task { await create() } }
                            .disabled((!supported && pendingJob == nil) || working || !(2...12).contains(songs.count) || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("mixtape-create-link")
                    }
                }
            }
        }
        .interactiveDismissDisabled(working && !handedOff)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
        .task { supported = (try? await SongSharing.shared.client().mixtapeConfiguration().mixtapes) == 1 }
    }
    private func create() async {
        working = true; error = nil; handedOff = false
        defer { working = false }
        do {
            if let pendingJob {
                result = try await SongSharing.shared.resumeMixtapeUpload(pendingJob, onBackgroundUploadHandOff: { handedOff = true })
                return
            }
            result = try await SongSharing.shared.shareMixtape(songs, title: title,
                options: .init(note: note, from: from, expiresInSeconds: expiry, showsDetails: showsDetails, reviewPreservation: reviewPreservation),
                onBackgroundUploadHandOff: { handedOff = true }, onStaged: { pendingJob = $0 })
        } catch { self.error = pendingJob == nil ? "Sharing did not finish. Check the selected tracks and try again." : "Upload interrupted. Your protected draft is kept. Retry Upload continues the same link, or retry it in Shared Links." }
    }
}
