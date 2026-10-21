import BatonShareKit
import BatonSubsonicKit
import BatonSubsonicModels
import SwiftUI

/// What Share… on an album, a playlist or a selection of songs hands the composer
/// (specs/collection-sharing.md, "The apps"). The entry points build one and present
/// `ShareCollectionSheet(draft:)` with `.sheet(item:)`; everything else (routing to a song,
/// mixtape or collection link, the track picker, sealing) lives behind the sheet.
struct CollectionShareDraft: Identifiable {
    enum Source: Equatable {
        /// An album: its order is fixed, its cover is its own.
        case album(id: String)
        /// A playlist: reorderable, a 2×2 mosaic cover.
        case playlist(id: String)
        /// Songs picked in a list (two or more): reorderable, a mosaic cover.
        case selection
    }

    let id = UUID()
    let source: Source
    /// The album or playlist name, or empty for a selection (the sheet then suggests one).
    let title: String
    /// The album artist; empty for a playlist or a selection.
    let artist: String
    /// The songs in display order, when the caller has them. nil asks the sheet to load the
    /// album's or playlist's songs from the server.
    let songs: [NavidromeSong]?

    init(source: Source, title: String, artist: String = "", songs: [NavidromeSong]?) {
        self.source = source; self.title = title; self.artist = artist; self.songs = songs
    }

    static func album(id: String, name: String, artist: String, songs: [NavidromeSong]? = nil) -> Self {
        .init(source: .album(id: id), title: name, artist: artist, songs: songs)
    }

    static func playlist(id: String, name: String, songs: [NavidromeSong]? = nil) -> Self {
        .init(source: .playlist(id: id), title: name, songs: songs)
    }

    static func selection(_ songs: [NavidromeSong]) -> Self { .init(source: .selection, title: "", songs: songs) }
}


extension CollectionShareDraft {
    /// What the link says it holds: an album, or a playlist for a playlist or picked songs.
    var kind: ShareCollectionKind { if case .album = source { .album } else { .playlist } }
    /// An album keeps its order; a playlist or picked songs can be reordered.
    var isReorderable: Bool { kind != .album }
}

/// The album, playlist and selection composer (specs/collection-sharing.md, "The apps",
/// TBX-1000000485): a preview, the track picker (every track on by default, reorderable for a
/// playlist or picked songs), the title, note, From, expiry, listeners, previews and review
/// preservation, and a line saying which link the picked songs make. At Create Link one song goes
/// as a song link, 2 to 12 within the advertised mixtape limits as a mixtape, anything bigger as
/// one album or playlist link when the service advertises collections (`ShareCollectionPlan`).
struct ShareCollectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: CollectionShareDraft

    /// One row of the picker. Its own identity, because a playlist can hold a song twice.
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let song: NavidromeSong
        var track: ShareCollectionPlan.Track { SongSharing.collectionTrack(song) }
    }

    @AppStorage(SongSharing.fromKey) private var from = ""
    @AppStorage(SongSharing.disclosureKey) private var disclosureSeen = false
    @State private var entries: [Entry] = []
    @State private var off = Set<UUID>()
    @State private var loading = true
    @State private var loadError: String?
    @State private var service: ShareCollectionPlan.Service?
    @State private var config: ShareConfig?
    @State private var title = ""
    @State private var note = ""
    @State private var expires = ShareLimits.standard.defaultExpirySeconds
    @State private var listeners = ShareLimits.standard.defaultBookListeners
    /// The sharer's own choice, once they touch the toggle. Until then previews follow the link
    /// kind's existing default: on for a song, album or playlist, off for a mixtape (as the
    /// mixtape composer always had it, and as the privacy policy says).
    @State private var showsDetailsChoice: Bool?
    @State private var reviewPreservation = false
    @State private var cover: Data?
    @State private var coverImage: PlatformImage?
    @State private var phase: Phase = .composing
    @State private var copied = false
    @State private var backgroundUploadHandedOff = false
    /// A mixtape whose protected upload ticket exists, so Retry Upload is the same link.
    @State private var pendingJob: UUID?
    /// An album or playlist link staged on this device, so Retry Upload is the same link.
    @State private var pendingBook: URL?

    enum Phase: Equatable {
        case composing
        case working
        case done(ShareLedger.Record)
        case failed(String)
    }

    init(draft: CollectionShareDraft) { self.draft = draft }

    private var picked: [Entry] { entries.filter { !off.contains($0.id) } }
    private var tracks: [ShareCollectionPlan.Track] { picked.map(\.track) }
    private var route: Result<ShareCollectionPlan.Route, ShareCollectionPlan.Refusal>? {
        service.map { ShareCollectionPlan.route(tracks, kind: draft.kind, service: $0) }
    }

    private var hasPending: Bool { pendingJob != nil || pendingBook != nil }
    private var isWorking: Bool { if case .working = phase { true } else { false } }
    private var isDone: Bool { if case .done = phase { true } else { false } }
    private var locked: Bool { isWorking || hasPending }
    private var sendsCollection: Bool { if case .success(.collection) = route { true } else { false } }
    private var canCreate: Bool {
        if hasPending { return true }
        guard case .success = route else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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
                    trackSection
                    composer
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.kind == .album ? "Share Album" : draft.source == .selection ? "Share Songs" : "Share Playlist")
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
                            Button(hasPending ? "Retry Upload" : "Create Link") { Task { await create() } }
                                .disabled(isWorking || !canCreate)
                                .accessibilityIdentifier("collection-share-create-link")
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 540, minHeight: 640)
        #endif
        .interactiveDismissDisabled(dismissalBlocked)
        .task { await load() }
    }

    // MARK: Loading

    private func load() async {
        // The caps the service advertises, so the composer never holds a second copy of them.
        if let advertised = try? await SongSharing.shared.client().mixtapeConfiguration() {
            config = advertised
            service = ShareCollectionPlan.Service(config: advertised, kind: draft.kind)
            if let book = service?.collection {
                listeners = min(max(1, book.defaultListeners), book.maxListeners)
            }
            if advertised.expiryChoices.contains(advertised.defaultExpirySeconds) { expires = advertised.defaultExpirySeconds }
        } else {
            loadError = "Couldn't reach Baton's share service. Check your connection and try again."
        }
        var songs = draft.songs ?? []
        if draft.songs == nil {
            do { songs = try await SongSharing.shared.collectionSongs(draft.source) } catch {
                loadError = draft.kind == .album
                    ? "Couldn't get this album's songs from your music server."
                    : "Couldn't get this playlist's songs from your music server."
            }
        }
        entries = songs.map { Entry(song: $0) }
        off = Set(entries.filter { ShareCollectionPlan.unavailableReason($0.track, service: service) != nil }.map(\.id))
        if title.isEmpty {
            let own = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            title = own.isEmpty
                ? ShareCollectionPlan.suggestedTitle(albums: songs.map(\.album), artists: songs.map(\.displayArtistName))
                : own
        }
        loading = false
        cover = await SongSharing.shared.collectionCover(album: draft.kind == .album, songs: songs)
        coverImage = cover.flatMap(SongSharing.platformImage)
    }

    // MARK: Sections

    private var artistLine: String {
        if !draft.artist.isEmpty { return draft.artist }
        let artists = Set(picked.compactMap { $0.song.displayArtistName }.filter { !$0.isEmpty })
        return artists.count == 1 ? artists.first! : ""
    }

    private var preview: some View {
        HStack(spacing: 14) {
            Group {
                if let coverImage {
                    SongSharing.image(coverImage).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15).overlay(
                        Image(systemName: draft.kind == .album ? "square.stack" : "music.note.list").foregroundStyle(.secondary))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? (draft.title.isEmpty ? "Songs" : draft.title) : title).font(.headline).lineLimit(2)
                if !artistLine.isEmpty {
                    Text(artistLine).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("Your friend can listen in a browser, with no app and no account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trackSection: some View {
        Section {
            if loading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Getting the songs…").foregroundStyle(.secondary)
                }
            } else if entries.isEmpty {
                Text(loadError ?? "There are no songs to share here.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    trackRow(entry, index: index)
                }
            }
        } header: {
            HStack {
                Text(draft.isReorderable ? "Songs and order" : "Songs")
                Spacer()
                if entries.count > 1, !locked {
                    let anyOff = entries.contains { off.contains($0.id) && unavailable($0) == nil }
                    Button(anyOff ? "Include All" : "Include None") {
                        off = anyOff ? Set(entries.filter { unavailable($0) != nil }.map(\.id)) : Set(entries.map(\.id))
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier("collection-share-include-all")
                }
            }
        } footer: {
            routeLine
        }
        .disabled(locked)
    }

    private func unavailable(_ entry: Entry) -> String? {
        ShareCollectionPlan.unavailableReason(entry.track, service: service)
    }

    private func trackRow(_ entry: Entry, index: Int) -> some View {
        let reason = unavailable(entry)
        let song = entry.song
        let number = draft.kind == .album ? (song.track ?? index + 1) : index + 1
        var detail = [String]()
        if let artist = song.displayArtistName, !artist.isEmpty, artist != draft.artist { detail.append(artist) }
        if let seconds = song.duration, seconds > 0 { detail.append(String(format: "%d:%02d", seconds / 60, seconds % 60)) }
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { !off.contains(entry.id) },
                set: { on in if on { off.remove(entry.id) } else { off.insert(entry.id) } })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(number). \(song.title)").lineLimit(2)
                    if let reason {
                        Text(reason).font(.caption).foregroundStyle(Color.warningTint)
                    } else if !detail.isEmpty {
                        Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(reason != nil)
            .accessibilityIdentifier("collection-share-track-\(index)")
            if draft.isReorderable {
                Button { entries.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).accessibilityLabel("Move \(song.title) up")
                Button { entries.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == entries.count - 1).accessibilityLabel("Move \(song.title) down")
            }
        }
        .buttonStyle(.borderless)
    }

    /// "14 songs · 52 m · about 50 MB · one album link", or why the picked songs do not go.
    @ViewBuilder private var routeLine: some View {
        switch route {
        case let .success(link):
            Text(ShareCollectionPlan.line(link, tracks: tracks) + "." + why(link))
                .accessibilityIdentifier("collection-share-route")
        case let .failure(refusal):
            if !loading, !entries.isEmpty {
                Label(refusal.message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningTint)
                    .accessibilityIdentifier("collection-share-route")
            }
        case nil:
            if !loading, loadError != nil, !entries.isEmpty {
                Label("Couldn't reach Baton's share service. Check your connection and try again.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningTint)
                    .accessibilityIdentifier("collection-share-route")
            }
        }
    }

    /// Why this kind of link, in a few words.
    private func why(_ route: ShareCollectionPlan.Route) -> String {
        switch route {
        case .song: " One song goes as a song link."
        case .mixtape: " Up to \(ShareBookPlan.maxChapters) songs and \(ShareCollectionPlan.duration(service?.maxSeconds ?? 1200)) go as a mixtape."
        case .collection:
            " Your friend plays them in order or picks one, and can come back to them while the link lasts."
        }
    }

    @ViewBuilder private var composer: some View {
        Section {
            TextField(draft.kind == .album ? "Album title" : "Title", text: $title)
                .accessibilityIdentifier("collection-share-title")
                .onChange(of: title) { _, value in
                    if value.unicodeScalars.count > ShareLimits.maxTitleLength {
                        title = String(String.UnicodeScalarView(value.unicodeScalars.prefix(ShareLimits.maxTitleLength)))
                    }
                }
            TextField("Add a note (optional)", text: $note, axis: .vertical)
                .lineLimit(2 ... 5)
                .accessibilityIdentifier("collection-share-note")
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
            if sendsCollection, let book = service?.collection {
                Stepper(value: $listeners, in: 1 ... max(1, book.maxListeners)) {
                    Text(listeners == 1 ? "1 listener" : "\(listeners) listeners")
                }
                .accessibilityIdentifier("collection-share-listeners")
            }
        } footer: {
            if sendsCollection {
                Text("Each listener is one person who presses Start listening. They can pause, go back and come again without counting twice.")
            }
        }
        .disabled(locked)

        Section {
            Toggle("Show details in link previews", isOn: showsDetailsBinding)
                .accessibilityIdentifier("collection-share-public-preview")
        } footer: {
            Text(previewFooter)
        }
        .disabled(locked)

        Section {
            Toggle("Allow private preservation during review", isOn: $reviewPreservation)
                .accessibilityIdentifier("collection-share-review-preservation")
                .disabled(locked)
        } footer: {
            Text("If this link is disabled for review, Baton may keep its encrypted songs and share details privately for up to 90 days from disable. They still count toward storage quota. The remaining link lifetime pauses and resumes only after reviewed restoration. Revoke deletes the server copy; spent play limits stay spent. Leave this off to keep ordinary expiry.")
        }

        Section {
            switch phase {
            case .working:
                let stage = SongSharing.shared.stage ?? .preparing
                HStack(spacing: 10) {
                    switch stage {
                    case let .uploading(fraction):
                        ProgressView(value: fraction).frame(maxWidth: 120)
                    case let .collecting(done, total) where total > 0:
                        ProgressView(value: Double(done), total: Double(total)).frame(maxWidth: 120)
                    default:
                        ProgressView().controlSize(.small)
                    }
                    Text(stage.label).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("collection-share-progress")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.warningTint)
                    .accessibilityIdentifier("collection-share-failure")
            default:
                EmptyView()
            }
        } footer: {
            // The first-share disclosure, as for a song: nothing leaves the device until Create Link.
            if !disclosureSeen {
                Text("Sharing uploads an encrypted copy of these songs to Baton's share service. It is deleted at expiry unless you allow review preservation above. Baton can't play it: the key is in the link you send.")
                    .accessibilityIdentifier("collection-share-disclosure")
            }
        }
    }

    private var showsDetails: Bool {
        if let showsDetailsChoice { return showsDetailsChoice }
        if case .success(.mixtape) = route { return false }
        return true
    }

    private var showsDetailsBinding: Binding<Bool> {
        Binding(get: { showsDetails }, set: { showsDetailsChoice = $0 })
    }

    private var previewFooter: String {
        switch route {
        case .success(.song):
            return showsDetails ? "Messages and other apps show the title, artwork and your note in the preview."
                : "Everything is encrypted. The preview only says someone sent a song."
        case .success(.mixtape):
            return showsDetails ? "Messages and other apps show the title, your name and your note in the preview."
                : "Everything is encrypted, song names included. The preview only says someone sent you something."
        default:
            let what = draft.kind == .album ? "an album" : "a playlist"
            return showsDetails ? "Messages and other apps show the title, artist, your name and your note in the preview. Song names and the cover stay encrypted."
                : "Everything is encrypted, song names and the cover included. The preview only says someone sent you \(what)."
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
                    .accessibilityIdentifier("collection-share-result-link")
                ShareLink(item: url, subject: Text(record.title), message: Text(message)) {
                    Label("Send…", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("collection-share-send-link")
                Button {
                    SharedLinkPasteboard.copy(record.link)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("collection-share-copy-link")
            } footer: {
                Text("\(SharePresentation.expiry(record.expiresAt)). Find this link again in Settings → Shared Links.")
            }
        }
    }

    // MARK: Create Link

    private func coverArtURL(_ song: NavidromeSong) -> URL? {
        song.artworkURL ?? (try? NavidromeConfig.makeClient())?.coverArtURL(id: song.coverArtID ?? song.id, size: 600)
    }

    private func create() async {
        backgroundUploadHandedOff = false
        phase = .working
        let sharing = SongSharing.shared
        let options = SongSharing.Options(note: note, from: from, expiresInSeconds: expires, showsDetails: showsDetails,
                                          reviewPreservation: reviewPreservation, listeners: listeners)
        let songs = picked.map(\.song)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        func collection() async throws -> ShareLedger.Record {
            // A playlist's mosaic is drawn from the songs that go, in their order.
            let image = draft.kind == .album ? cover : await sharing.collectionCover(album: false, songs: songs)
            return try await sharing.shareCollection(kind: draft.kind, title: name, artist: draft.kind == .album ? draft.artist : "",
                                                     songs: songs, cover: image, options: options,
                                                     onStaged: { pendingBook = $0 })
        }
        do {
            let record: ShareLedger.Record
            if let pendingBook {
                record = try await sharing.resumeBookUpload(pendingBook)
            } else if let pendingJob {
                record = try await sharing.resumeMixtapeUpload(pendingJob, onBackgroundUploadHandOff: { backgroundUploadHandedOff = true })
            } else {
                switch route {
                case .success(.song):
                    record = try await sharing.share(songs[0], options: options, coverArtURL: coverArtURL(songs[0]),
                                                     onBackgroundUploadHandOff: { backgroundUploadHandedOff = true })
                case .success(.mixtape):
                    do {
                        record = try await sharing.shareMixtape(songs, title: name, options: options,
                                                                onBackgroundUploadHandOff: { backgroundUploadHandedOff = true },
                                                                onStaged: { pendingJob = $0 })
                    } catch SongShareError.tooLarge where service?.collection != nil && pendingJob == nil {
                        // The server's MP3s came out larger than estimated: the same songs go as one link instead.
                        record = try await collection()
                    }
                case .success(.collection):
                    record = try await collection()
                case let .failure(refusal):
                    throw SongShareError.other(refusal.message)
                case nil:
                    throw SongShareError.other("Couldn't reach Baton's share service. Check your connection and try again.")
                }
            }
            phase = .done(record)
        } catch {
            let message = SongShareError(error).errorDescription ?? "Sharing didn't work."
            if let staged = pendingBook,
               !FileManager.default.fileExists(atPath: staged.appendingPathComponent(PreparedBookShare.ticketName).path) {
                // The service ended the link, and its staged copy is gone: the next try is a new link.
                pendingBook = nil
                phase = .failed(message)
            } else if pendingBook != nil {
                phase = .failed("Upload interrupted: \(message) The encrypted copy is kept on this device. Retry Upload continues the same link, or retry it in Shared Links.")
            } else if pendingJob != nil {
                phase = .failed("Upload interrupted. Your protected draft is kept. Retry Upload continues the same link, or retry it in Shared Links.")
            } else {
                phase = .failed(message)
            }
        }
    }
}
