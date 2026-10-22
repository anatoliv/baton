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
    @State private var showsContact = false
    @State private var pendingDiscard: SongSharing.PendingBook?

    var body: some View {
        List {
            // Books are named only once this device has book links; otherwise the wording is as before.
            Button(sharing.hasBookLinks ? "Retry interrupted uploads" : "Retry interrupted mixtape uploads") {
                Task {
                    // Mixtapes and books recover independently: one stuck ticket never holds up the other.
                    var failed = false
                    do { try await sharing.resumeMixtapeUploads() } catch { failed = true }
                    do { try await sharing.resumeBookUploads() } catch { failed = true }
                    actionError = failed ? "Protected upload recovery is unavailable. Your drafts are kept; try again later." : nil
                    await sharing.refresh()
                }
            }
            if !sharing.pendingBooks.isEmpty {
                Section {
                    ForEach(sharing.pendingBooks) { pending in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pending.title).font(.headline).lineLimit(1)
                            Text("\(pending.noun) link not finished uploading. Its encrypted copy is kept on this device.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Retry Upload") {
                                    Task {
                                        do { _ = try await sharing.resumeBookUpload(pending.directory); actionError = nil }
                                        catch { actionError = SongShareError(error).errorDescription }
                                    }
                                }
                                Button("Discard", role: .destructive) { pendingDiscard = pending }
                            }
                            .buttonStyle(.borderless)
                        }
                        .accessibilityIdentifier("shared-links-pending-book")
                    }
                } header: {
                    // Books, albums and playlists wait here alike.
                    Text("Unfinished links")
                }
            }
            if ReactionPushNotifications.shared.available || ReactionPushNotifications.shared.optedIn
                || ReactionPushNotifications.shared.failure != nil {
                Section {
                    Toggle("Notify me about reactions", isOn: Binding(
                        get: { ReactionPushNotifications.shared.optedIn },
                        set: { value in Task { await ReactionPushNotifications.shared.setOptIn(value) } }))
                        .disabled(!ReactionPushNotifications.shared.available && !ReactionPushNotifications.shared.optedIn)
                    if let failure = ReactionPushNotifications.shared.failure {
                        Text(failure).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Apple receives a device token and a generic reaction notification. Song titles, names, replies and decryption keys are excluded.")
                }
            }
            // Private contact is dormant: its worker is not deployed and the share
            // service answers 404 until it is configured, so the entry stays hidden by default.
            if SharedContactView.enabled {
                Button { showsContact = true } label: { Label("Private Contact", systemImage: "envelope") }
            }
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
            if let error = sharing.refreshError ?? actionError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningTint)
            }
            if sharing.ledger.records.isEmpty {
                ContentUnavailableView(
                    "No shared links yet", systemImage: "square.and.arrow.up",
                    description: Text("Share a song from its menu. The links you send appear here, with who listened."))
            } else {
                ForEach(sharing.ledger.records, id: \.identity) { record in
                    row(record)
                        .contextMenu { actions(record) }
                        #if os(iOS)
                        .swipeActions { actions(record) }
                        #endif
                }
            }
        }
        .sheet(isPresented: $showsContact) { SharedContactView() }
        .navigationTitle("Shared Links")
        .task {
            sharing.loadPendingBooks()
            await ReactionPushNotifications.shared.refreshAvailability()
            await sharing.refresh()
        }
        .confirmationDialog("Discard this link?", isPresented: Binding(
            get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }), presenting: pendingDiscard
        ) { pending in
            Button("Discard", role: .destructive) { sharing.discardBookUpload(pending.directory) }
        } message: { pending in
            Text("The encrypted copy of “\(pending.title)” is deleted from this device, and its unfinished link never plays. Share the \(pending.noun.lowercased()) again to make a new one.")
        }
        .refreshable { await sharing.refresh() }
        .confirmationDialog("Revoke this link?", isPresented: Binding(
            get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }), presenting: pendingRevoke
        ) { record in
            Button("Revoke", role: .destructive) {
                Task {
                    do { try await sharing.revoke(record.id, kind: record.containerKind) } catch {
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
                if record.containerKind == .book {
                    Text(Self.bookLine(record, summary)).font(.caption)
                    if let deadline = record.bookSummary?.reviewDeadline, let date = ShareDate.date(deadline) {
                        Text("Review deadline: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    }
                    if let remaining = record.bookSummary?.pausedLifetimeSeconds {
                        Text("Paused link lifetime: \(remaining / 3600) hours remaining").font(.caption)
                    }
                } else if record.containerKind == .mixtape {
                    Text("\(record.songIDs?.count ?? record.mixtapeSummary?.trackCount ?? 0) tracks · Sessions \(summary.stats.fetches) · Played \(summary.stats.plays)").font(.caption)
                    if let deadline = record.mixtapeSummary?.reviewDeadline, let date = ShareDate.date(deadline) {
                        Text("Review deadline: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    }
                    if let remaining = record.mixtapeSummary?.pausedLifetimeSeconds {
                        Text("Paused link lifetime: \(remaining / 3600) hours remaining").font(.caption)
                    }
                } else { Text(SharePresentation.stats(summary.stats)).font(.caption) }
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
                    do { try await sharing.extend(record.id, kind: record.containerKind) } catch {
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
                sharing.forget(record.id, kind: record.containerKind)
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

    /// "30 chapters · 4 of 10 listeners · Read-along text", or "Album · 14 songs · 4 of 10 listeners".
    /// Static so a test can read the row as it is drawn (`SharedLinksRowTests`).
    static func bookLine(_ record: ShareLedger.Record, _ summary: ShareSummary) -> String {
        var parts = [String]()
        if let kind = record.collectionKind {
            parts.append(SongSharing.noun(kind))
            if let songs = record.bookSummary?.chapterCount { parts.append(songs == 1 ? "1 song" : "\(songs) songs") }
        } else if let chapters = record.bookSummary?.chapterCount { parts.append(chapters == 1 ? "1 chapter" : "\(chapters) chapters") }
        parts.append("\(summary.stats.fetches) of \(summary.playCap) listeners")
        if record.bookSummary?.hasText == true { parts.append("Read-along text") }
        return parts.joined(separator: " · ")
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

/// Contact and notice text stay in this transient sheet, outside the share ledger.
private struct SharedContactView: View {
    /// Off unless a development or acceptance instance sets this key; never on by default.
    static let enabledKey = "baton.share.privateContact"
    static var enabled: Bool {
        #if DEBUG
        // UI tests reach the sheet through launchEnvironment, never launch arguments.
        if ProcessInfo.processInfo.environment[enabledKey] == "1" { return true }
        #endif
        return BatonStorage.defaults.bool(forKey: enabledKey)
    }
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var verificationCode = ""
    @State private var noticeCode = ""
    @State private var consent = false
    @State private var includeExisting = false
    @State private var status = "disconnected"
    @State private var notice: ShareContactClient.Notice?
    @State private var busy = false
    @State private var requestTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Optional private contact") {
                    Text("Sharing stays account-free. Connect a verified email to receive private review notices. Unreachable cases need manual handling.")
                    Text("Status: \(status)")
                    if status != "verified" {
                        TextField("Email address", text: $address)
                        Toggle("I agree to use this email for private notices", isOn: $consent)
                        Toggle("Include links already shared from this device", isOn: $includeExisting)
                        Button("Connect email") {
                            run { client in
                                let result = try await client.enroll(address: address,
                                    include: includeExisting ? SongSharing.shared.ledger.records.map(\.id) : [])
                                status = result.status
                                address = ""
                            }
                        }.disabled(!consent || address.isEmpty)
                        TextField("Verification code from email", text: $verificationCode)
                        Button("Verify email") {
                            run { client in status = try await client.verify(code: verificationCode).status; verificationCode = "" }
                        }.disabled(verificationCode.isEmpty)
                    }
                    Button("Disconnect email", role: .destructive) {
                        run { client in
                            status = try await client.withdraw().status
                            verificationCode = ""; noticeCode = ""; notice = nil; consent = false
                        }
                    }
                }
                Section("Private notice") {
                    TextField("Notice code from email", text: $noticeCode)
                    Button("Open private notice") {
                        run { client in notice = try await client.access(code: noticeCode); noticeCode = "" }
                    }.disabled(noticeCode.isEmpty)
                    if let notice {
                        Text(notice.instructions)
                        Text("Action: \(notice.action)").font(.caption)
                        Text(notice.location).font(.caption)
                    }
                }
                if let error { Text(error).foregroundStyle(Color.warningTint) }
            }
            .disabled(busy)
            .navigationTitle("Private Contact")
            .toolbar { Button("Done") { dismiss() } }
            .task { run { client in status = try await client.status().status } }
            .onDisappear { requestTask?.cancel(); requestTask = nil; address = ""; verificationCode = ""; noticeCode = ""; notice = nil }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
    private func run(_ action: @escaping @MainActor (ShareContactClient) async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        requestTask = Task { @MainActor in
            defer { busy = false }
            do {
                let sharing = try SongSharing.shared.client()
                try await action(ShareContactClient(base: sharing.base, secret: sharing.secret))
            } catch { self.error = "Private contact is unavailable. Check the code or try again later." }
        }
    }
}
