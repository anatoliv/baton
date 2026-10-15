import BatonShareKit
import BatonSubsonicKit
import BatonSubsonicModels
import SwiftUI
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// The composer (plan §1): a preview of what the friend will see, a note, who it is from, how
/// long it lasts, whether the details show in link previews, then the system share sheet.
/// One view for both apps; the only platform difference is the pasteboard.
struct ShareSongSheet: View {
    let song: NavidromeSong
    let coverArtURL: URL?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SongSharing.fromKey) private var from = ""
    @AppStorage(SongSharing.disclosureKey) private var disclosureSeen = false
    @State private var note = ""
    @State private var expires = ShareLimits.standard.defaultExpirySeconds
    @State private var showsDetails = true
    @State private var reviewPreservation = false
    @State private var phase: Phase = .composing
    @State private var cover: PlatformImage?
    @State private var copied = false
    @State private var backgroundUploadHandedOff = false
    #if DEBUG
    @State private var draftIdentity = UUID()
    #endif

    enum Phase: Equatable {
        case composing
        case working
        case done(ShareLedger.Record)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { preview }

                switch phase {
                case let .done(record):
                    doneSection(record)
                default:
                    composer
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share Song")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isDone || backgroundUploadHandedOff ? "Done" : "Cancel") { dismiss() }
                            .disabled(dismissalBlocked)
                    }
                    if !isDone {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create Link") { Task { await create() } }
                                .disabled(isWorking)
                                .accessibilityIdentifier("share-create-link")
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 520)
        #endif
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
            if BatonStorage.isProbe {
                Text("draft=\(draftIdentity.uuidString) noteCount=\(note.count) expiry=\(expires)")
                    .font(.system(size: 1)).foregroundStyle(.clear)
                    .accessibilityIdentifier("debug.shareDraft").allowsHitTesting(false)
            }
        }
        #endif
        .interactiveDismissDisabled(dismissalBlocked)
        .task {
            if let coverArtURL { cover = await ArtworkCache.shared.image(for: coverArtURL, side: 160) }
        }
    }

    private var isWorking: Bool { if case .working = phase { true } else { false } }
    private var dismissalBlocked: Bool {
        #if os(iOS)
        isWorking && !backgroundUploadHandedOff
        #else
        isWorking
        #endif
    }
    private var isDone: Bool { if case .done = phase { true } else { false } }

    private var preview: some View {
        HStack(spacing: 14) {
            Group {
                if let cover {
                    SongSharing.image(cover).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.headline).lineLimit(2)
                if let artist = song.displayArtistName, !artist.isEmpty {
                    Text(artist).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("Your friend can listen in a browser, with no app and no account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var composer: some View {
        Section {
            TextField("Add a note (optional)", text: $note, axis: .vertical)
                .lineLimit(2 ... 5)
                .onChange(of: note) { _, value in
                    if value.unicodeScalars.count > ShareLimits.maxNoteLength {
                        note = String(String.UnicodeScalarView(value.unicodeScalars.prefix(ShareLimits.maxNoteLength)))
                    }
                }
            TextField("From", text: $from, prompt: Text("Your name"))
                .onChange(of: from) { _, value in
                    if value.count > ShareLimits.maxFromLength { from = String(value.prefix(ShareLimits.maxFromLength)) }
                }
            Picker("Link lasts", selection: $expires) {
                Text("1 day").tag(86400)
                Text("7 days").tag(604_800)
                Text("30 days").tag(2_592_000)
            }
        }

        Section {
            Toggle("Show song details in link previews", isOn: $showsDetails)
        } footer: {
            Text(showsDetails
                ? "Messages and other apps show the title, artwork and your note in the preview."
                : "Everything is encrypted. The preview only says someone sent a song.")
        }

        Section {
            Toggle("Allow private preservation during review", isOn: $reviewPreservation)
                .accessibilityIdentifier("share-review-preservation")
        } footer: {
            Text("If this link is disabled for review, Baton may keep its encrypted song and share details privately for up to 90 days from disable. They still count toward storage quota. The remaining link lifetime pauses and resumes only after reviewed restoration. Revoke deletes the server copy; spent play limits stay spent. Leave this off to keep ordinary expiry.")
        }

        Section {
            switch phase {
            case .working:
                let stage = SongSharing.shared.stage ?? .fetching
                HStack(spacing: 10) {
                    if case let .uploading(fraction) = stage {
                        ProgressView(value: fraction).frame(maxWidth: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(stage.label).foregroundStyle(.secondary)
                }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.warningTint)
            default:
                EmptyView()
            }
        } footer: {
            // The first-share disclosure (plan §1). Shown until a share has been sent, and it is
            // the consent: nothing leaves the device until Create Link is pressed.
            if !disclosureSeen {
                Text("Sharing uploads an encrypted copy of this song to Baton's share service. It is deleted at expiry unless you allow review preservation above. Baton can't play it: the key is in the link you send.")
            }
        }
    }

    @ViewBuilder private func doneSection(_ record: ShareLedger.Record) -> some View {
        if let url = URL(string: record.link) {
            let message = SharePresentation.message(title: record.title, artist: record.artist, note: note, link: url)
            Section {
                Text(record.link)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                ShareLink(item: url, subject: Text(record.title), message: Text(message)) {
                    Label("Send…", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("share-send-link")
                Button {
                    SharedLinkPasteboard.copy(record.link)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            } footer: {
                Text("\(SharePresentation.expiry(record.expiresAt)). Find it again, see who listened, or revoke it in Settings → Shared Links.")
            }
        }
    }

    private func create() async {
        let options = SongSharing.Options(note: note, from: from,
                                          expiresInSeconds: expires, showsDetails: showsDetails,
                                          reviewPreservation: reviewPreservation)
        backgroundUploadHandedOff = false
        phase = .working
        do {
            let record = try await SongSharing.shared.share(song, options: options, coverArtURL: coverArtURL,
                onBackgroundUploadHandOff: { backgroundUploadHandedOff = true })
            phase = .done(record)
        } catch {
            phase = .failed(SongShareError(error).errorDescription ?? "Sharing didn't work.")
        }
    }
}

/// The links this device sent (plan §5): who listened, and revoke, extend, copy again.
struct SharedLinksView: View {
    private var sharing: SongSharing { SongSharing.shared }
    @State private var pendingRevoke: ShareLedger.Record?
    @State private var actionError: String?

    var body: some View {
        List {
            #if os(iOS)
            if !sharing.ledger.pendingFailures.isEmpty {
                let count = sharing.ledger.pendingFailures.count
                Label("\(count) song\(count == 1 ? "" : "s") could not be shared", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.warningTint)
                Text("Try sharing it again from its song menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if sharing.pendingUploadCount > 0 {
                Label("Uploading \(sharing.pendingUploadCount) shared song\(sharing.pendingUploadCount == 1 ? "" : "s")…", systemImage: "arrow.up.circle")
                Text("Your links will appear here when the upload finishes. You can leave the app while they upload.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
            if sharing.ledger.records.isEmpty {
                ContentUnavailableView(
                    "No shared links yet", systemImage: "square.and.arrow.up",
                    description: Text("Share a song from its menu. The links you send appear here, with who listened."))
            } else {
                if let error = sharing.refreshError ?? actionError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningTint)
                }
                ForEach(sharing.ledger.records) { record in
                    row(record)
                        .contextMenu { actions(record) }
                        #if os(iOS)
                        .swipeActions { actions(record) }
                        #endif
                }
            }
        }
        .navigationTitle("Shared Links")
        .task { await sharing.refresh() }
        .refreshable { await sharing.refresh() }
        .confirmationDialog("Revoke this link?", isPresented: Binding(
            get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }), presenting: pendingRevoke
        ) { record in
            Button("Revoke", role: .destructive) {
                Task {
                    do { try await sharing.revoke(record.id) } catch {
                        actionError = SongShareError(error).errorDescription
                    }
                }
            }
        } message: { record in
            Text("“\(record.title)” stops playing for everyone who has the link, and its copy is deleted now.")
        }
    }

    private func row(_ record: ShareLedger.Record) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title).font(.headline).lineLimit(1)
                if record.isPrivate {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Details hidden from previews")
                }
            }
            if !record.artist.isEmpty {
                Text(record.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(statusLine(record)).font(.caption).foregroundStyle(.secondary)
            if let summary = record.summary {
                if let notice = summary.actionRequired {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
                Text(SharePresentation.stats(summary.stats)).font(.caption)
                ForEach(Array(summary.reactions.enumerated()), id: \.offset) { _, reaction in
                    Text(reactionLine(reaction)).font(.callout)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func actions(_ record: ShareLedger.Record) -> some View {
        if record.isLive() || record.isHeldForReview {
            Button {
                SharedLinkPasteboard.copy(record.link)
            } label: { Label("Copy Link", systemImage: "doc.on.doc") }
            Button {
                Task {
                    do { try await sharing.extend(record.id) } catch {
                        actionError = SongShareError(error).errorDescription
                    }
                }
            } label: { Label("Extend 7 Days", systemImage: "clock.arrow.circlepath") }
            .disabled(record.summary?.actionRequired != nil)
            Button(role: .destructive) {
                pendingRevoke = record
            } label: { Label("Revoke", systemImage: "xmark.circle") }
        } else {
            Button(role: .destructive) {
                sharing.forget(record.id)
            } label: { Label("Remove from List", systemImage: "trash") }
        }
    }

    private func statusLine(_ record: ShareLedger.Record) -> String {
        if record.isHeldForReview { return "Disabled for review" }
        return switch record.status {
        case .revoked: "Revoked"
        case .expired: "Expired"
        case .pending: "Still uploading"
        case .ready: SharePresentation.expiry(record.expiresAt)
        }
    }

    private func reactionLine(_ reaction: ShareReaction) -> String {
        let who = reaction.name.isEmpty ? "Someone" : reaction.name
        return reaction.reply.isEmpty ? "\(reaction.emoji) \(who)" : "\(reaction.emoji) \(who): \(reaction.reply)"
    }
}

/// The one platform difference in this feature.
enum SharedLinkPasteboard {
    @MainActor static func copy(_ text: String) {
        #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}
