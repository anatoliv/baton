import BatonPlaybackKit
import BatonShareKit
import SwiftUI

/// A book as Share… sees it (`specs/book-sharing.md`, Phase 1, TBX-1000000132): its name, and
/// the chapters whose audio is on this device, in order. Built by each app from its own shelf
/// (`BookShelf.Book` on the Mac, `MobileBookShelf.Book` on the iPhone).
struct BookShareDraft: Identifiable, Equatable {
    struct Chapter: Identifiable, Equatable {
        /// The chapter's position in the book, 0-based.
        let index: Int
        let title: String
        let url: URL
        let durationSeconds: Double
        let bytes: Int

        var id: Int { index }
        /// The id the player and the upload ticket know this chapter by (`ClippingStore.Item.songID`).
        var songID: String { url.absoluteString }
        var plan: ShareBookPlan.Chapter { .init(index: index, title: title, durationSeconds: durationSeconds, bytes: bytes) }
    }

    let id = UUID()
    let documentID: String
    let title: String
    let author: String?
    /// Every chapter the book has, here or not, so a link of some of them says which.
    let chapterCount: Int
    let chapters: [Chapter]
    let coverURL: URL?

    /// The chapters that can go: their audio is on this device and has a known length.
    init(documentID: String, title: String, author: String?, chapters: [(index: Int, title: String, item: ClippingStore.Item?)],
         coverURL: URL?) {
        self.documentID = documentID
        self.title = title
        self.author = author
        self.chapterCount = chapters.count
        self.coverURL = coverURL
        self.chapters = chapters.compactMap { chapter in
            guard let item = chapter.item, let seconds = item.clipping.durationSeconds, seconds > 0,
                  let bytes = (try? FileManager.default.attributesOfItem(atPath: item.url.path))?[.size] as? Int, bytes > 0
            else { return nil }
            return Chapter(index: chapter.index, title: chapter.title, url: item.url, durationSeconds: seconds, bytes: bytes)
        }.sorted { $0.index < $1.index }
    }

    static func == (lhs: BookShareDraft, rhs: BookShareDraft) -> Bool { lhs.id == rhs.id }
}

/// The book composer: the song composer's preview, note, From, expiry, previews toggle and
/// disclosure, with a run of chapters to send. One chapter becomes a song link and two to twelve
/// a mixtape, within the limits the service advertises (`ShareBookPlan`).
struct ShareBookSheet: View {
    let book: BookShareDraft

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SongSharing.fromKey) private var from = ""
    @AppStorage(SongSharing.disclosureKey) private var disclosureSeen = false
    @State private var first = 0
    @State private var last = 0
    @State private var limits = ShareBookPlan.Limits.standard
    @State private var note = ""
    @State private var expires = ShareLimits.standard.defaultExpirySeconds
    @State private var showsDetails = true
    @State private var reviewPreservation = false
    @State private var phase: Phase = .composing
    @State private var cover: PlatformImage?
    @State private var copied = false
    @State private var backgroundUploadHandedOff = false
    /// A two-or-more chapter link whose protected upload ticket exists, so a failure retries the
    /// same link rather than making another.
    @State private var pendingJob: UUID?

    enum Phase: Equatable {
        case composing
        case working
        case done(ShareLedger.Record)
        case failed(String)
    }

    init(book: BookShareDraft) {
        self.book = book
        let range = ShareBookPlan.defaultRange(book.chapters.map(\.plan)) ?? 0 ... 0
        _first = State(initialValue: range.lowerBound)
        _last = State(initialValue: range.upperBound)
    }

    private var selected: [BookShareDraft.Chapter] {
        guard !book.chapters.isEmpty, first <= last, book.chapters.indices.contains(first), book.chapters.indices.contains(last)
        else { return [] }
        return Array(book.chapters[first ... last])
    }

    private var check: Result<ShareBookPlan.Container, ShareBookPlan.Refusal> {
        ShareBookPlan.check(selected.map(\.plan), limits: limits)
    }

    private var isWorking: Bool { if case .working = phase { true } else { false } }
    private var isDone: Bool { if case .done = phase { true } else { false } }
    private var dismissalBlocked: Bool {
        #if os(iOS)
        isWorking && !backgroundUploadHandedOff
        #else
        isWorking
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { preview }
                switch phase {
                case let .done(record):
                    doneSection(record)
                default:
                    chapterSection
                    composer
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share Book")
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
                            Button(pendingJob == nil ? "Create Link" : "Retry Upload") { Task { await create() } }
                                .disabled(isWorking || (pendingJob == nil && (try? check.get()) == nil))
                                .accessibilityIdentifier("book-share-create-link")
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 600)
        #endif
        .interactiveDismissDisabled(dismissalBlocked)
        .task {
            if let url = book.coverURL, let data = try? Data(contentsOf: url) { cover = SongSharing.platformImage(data) }
            // The caps the service advertises, so the composer never holds a second copy of them.
            if let config = try? await SongSharing.shared.client().mixtapeConfiguration() {
                limits = ShareBookPlan.Limits(config: config)
                if (try? check.get()) == nil, let range = ShareBookPlan.defaultRange(book.chapters.map(\.plan), limits: limits) {
                    first = range.lowerBound
                    last = range.upperBound
                }
            }
        }
    }

    private var preview: some View {
        HStack(spacing: 14) {
            Group {
                if let cover {
                    SongSharing.image(cover).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.15).overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.headline).lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("Your friend can listen in a browser, with no app and no account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var chapterSection: some View {
        Section {
            if book.chapters.isEmpty {
                Text("No chapter of this book is on this device yet. Share it once its chapters are here.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("From", selection: $first) {
                    ForEach(Array(book.chapters.enumerated()), id: \.offset) { position, chapter in
                        Text(label(chapter)).tag(position)
                    }
                }
                .accessibilityIdentifier("book-share-from-chapter")
                .onChange(of: first) { _, value in if last < value { last = value } }
                Picker("Through", selection: $last) {
                    ForEach(Array(book.chapters.enumerated()), id: \.offset) { position, chapter in
                        Text(label(chapter)).tag(position)
                    }
                }
                .accessibilityIdentifier("book-share-through-chapter")
                .onChange(of: last) { _, value in if first > value { first = value } }
            }
        } header: {
            Text("Chapters")
        } footer: {
            switch check {
            case .success:
                Text(summary)
            case let .failure(refusal):
                if !book.chapters.isEmpty {
                    Label(refusal.message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningTint)
                }
            }
        }
        .disabled(isWorking || pendingJob != nil)
    }

    private func label(_ chapter: BookShareDraft.Chapter) -> String {
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Chapter \(chapter.index + 1)" : "\(chapter.index + 1). \(title)"
    }

    /// "4 chapters · 18 m. One link holds up to 12 chapters and 20 minutes."
    private var summary: String {
        let count = selected.count == 1 ? "1 chapter" : "\(selected.count) chapters"
        let minutes = max(1, Int((Double(selected.reduce(0) { $0 + $1.plan.wireSeconds }) / 60).rounded()))
        let most = limits.mixtapes ? ShareBookPlan.maxChapters : 1
        let cap = max(1, limits.maxDurationSeconds / 60)
        return "\(count) · \(minutes) m. One link holds up to \(most == 1 ? "1 chapter" : "\(most) chapters") and \(cap) minutes."
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
        .disabled(isWorking || pendingJob != nil)

        Section {
            Toggle("Show book details in link previews", isOn: $showsDetails)
                .accessibilityIdentifier("book-share-public-preview")
        } footer: {
            Text(showsDetails
                ? "Messages and other apps show the title, author, cover and your note in the preview."
                : "Everything is encrypted, chapter names included. The preview only says someone sent you something.")
        }
        .disabled(isWorking || pendingJob != nil)

        Section {
            Toggle("Allow private preservation during review", isOn: $reviewPreservation)
                .accessibilityIdentifier("book-share-review-preservation")
                .disabled(isWorking || pendingJob != nil)
        } footer: {
            Text("If this link is disabled for review, Baton may keep its encrypted chapters and share details privately for up to 90 days from disable. They still count toward storage quota. The remaining link lifetime pauses and resumes only after reviewed restoration. Revoke deletes the server copy; spent play limits stay spent. Leave this off to keep ordinary expiry.")
        }

        Section {
            switch phase {
            case .working:
                let stage = SongSharing.shared.stage ?? .preparing
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
            // The first-share disclosure, as for a song: nothing leaves the device until Create Link.
            if !disclosureSeen {
                Text("Sharing uploads an encrypted copy of these chapters' audio to Baton's share service. The book's text stays on this device. It is deleted at expiry unless you allow review preservation above. Baton can't play it: the key is in the link you send.")
            }
        }
    }

    @ViewBuilder private func doneSection(_ record: ShareLedger.Record) -> some View {
        if let url = URL(string: record.link) {
            let message = SharePresentation.message(title: record.title, artist: book.author ?? "", note: note, link: url)
            Section {
                Text(record.link)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .accessibilityIdentifier("book-share-result-link")
                ShareLink(item: url, subject: Text(record.title), message: Text(message)) {
                    Label("Send…", systemImage: "square.and.arrow.up")
                }
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
        backgroundUploadHandedOff = false
        phase = .working
        do {
            let record: ShareLedger.Record
            if let pendingJob {
                record = try await SongSharing.shared.resumeMixtapeUpload(
                    pendingJob, onBackgroundUploadHandOff: { backgroundUploadHandedOff = true })
            } else {
                let options = SongSharing.Options(note: note, from: from, expiresInSeconds: expires,
                                                  showsDetails: showsDetails, reviewPreservation: reviewPreservation)
                record = try await SongSharing.shared.shareBook(
                    book, chapters: selected, options: options,
                    onBackgroundUploadHandOff: { backgroundUploadHandedOff = true },
                    onStaged: { pendingJob = $0 })
            }
            phase = .done(record)
        } catch {
            let message = SongShareError(error).errorDescription ?? "Sharing didn't work."
            phase = .failed(pendingJob == nil ? message
                : "Upload interrupted. Your protected draft is kept. Retry Upload continues the same link, or retry it in Shared Links.")
        }
    }
}
