import BatonDocuments
import BatonPlaybackKit
import Foundation
import Observation
import OSLog
import SwiftUI

private let coversLog = Logger(subsystem: "io.tonebox.baton", category: "documents")

/// Book covers on both apps: the four ways a book gets one, and how it reaches the
/// other device through the home server, the way the book itself does.
///
/// In order of preference: the book's own cover (an EPUB's, taken at import), Find Cover… on
/// Open Library (only the title and author leave the device, and only when asked), Make a Cover
/// (drawn here from the title and author, when both are known), and Choose Image… (a picture,
/// or an EPUB whose cover to use). Every picture from outside is decoded as an image and nothing
/// else and re-encoded at a bounded size before it is kept (`BookCoverImaging.sanitize`).
///
/// The home server keeps one cover per book job (`PUT/GET/DELETE /v1/books/{id}/cover`) and its
/// listing says when it last changed. Each time a device reads the listing it settles every
/// book's cover with `BookCoverStore.decide`: a change made here goes up, a change made on the
/// other device comes down.
@MainActor
@Observable
final class BookCovers {
    /// The book whose cover is being looked for, which the books screen presents as a sheet.
    struct Request: Identifiable, Equatable {
        var documentID: String
        var title: String
        var author: String?
        var id: String { documentID }
    }

    let store: BookCoverStore
    /// Find Cover… for this book, while its sheet is up.
    var finding: Request?
    /// Choose Image… for this book, while the iPhone's file picker is up (the Mac's is modal).
    var choosing: Request?
    /// Why the last cover change did not happen, in a listener's words, until it is dismissed.
    var notice: String?

    @ObservationIgnored private let gateway: @MainActor () -> GatewayBookClient?
    @ObservationIgnored let session: URLSession
    /// Settles covers with the home server, keeping a change made while a call is out
    /// (`BatonPlaybackKit.BookCoverSync`).
    @ObservationIgnored private(set) var engine: BookCoverSync
    /// Which books this device has, so a cover is only fetched for a book that is here.
    @ObservationIgnored var isKnown: @MainActor (String) -> Bool = { _ in true }

    /// Swaps the picture of queued tracks when a book's cover changes: the player's
    /// `setArtwork(_:forSongIDs:)`, set by whoever owns the player.
    @ObservationIgnored var playerArtwork: ((URL?, Set<String>) -> Void)?

    init(directory: URL, gateway: @escaping @MainActor () -> GatewayBookClient?, session: URLSession = BookCovers.session()) {
        let store = BookCoverStore(directory: directory)
        self.store = store
        self.gateway = gateway
        self.session = session
        self.engine = BookCoverSync(store: store, sanitize: { try BookCoverImaging.sanitize($0) },
                                    log: { coversLog.notice("\($0, privacy: .public)") })
    }

    /// A book gone from this device for good (its Recently removed week is over, or it was
    /// purged): its cover goes too, unless the book is back here meanwhile. The home server
    /// removed its copy with the book when it was deleted everywhere, and keeps it for the other
    /// devices when it was removed from this device only.
    func forgetIfGone(documentID: String) {
        guard !isKnown(documentID) else { return }
        store.forget(documentID: documentID)
        coversLog.notice("book \(documentID.prefix(12), privacy: .public): gone from this device, its cover too")
    }

    /// Join the covers to the books on this device: settled on every listing the home server
    /// side reads, known by its records and Clippings, and shown at once on what is queued.
    func attach(to homeServer: HomeServerBooks, clippings: ClippingStore, cleanup: BookCleanup? = nil) {
        homeServer.listed = { [weak self] listing in await self?.sync(listing) }
        cleanup?.purged = { [weak self] documentID in self?.forgetIfGone(documentID: documentID) }
        isKnown = { [weak homeServer, weak clippings] documentID in
            homeServer?.record(forDocument: documentID) != nil || homeServer?.isMadeHere(documentID) == true
                || clippings?.items.contains { $0.clipping.documentID == documentID } == true
        }
        store.onChange = { [weak self, weak clippings] documentID in
            guard let self, let clippings else { return }
            let ids = Set(clippings.items.filter { $0.clipping.documentID == documentID }.map(\.songID))
            self.playerArtwork?(self.store.url(for: documentID), ids)
        }
    }

    /// No cookies, no cache on disk, a listener's patience for a timeout.
    nonisolated static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = OpenLibraryCovers.timeout
        configuration.timeoutIntervalForResource = OpenLibraryCovers.timeout * 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Baton (book covers; https://batonmusic.app)"]
        return URLSession(configuration: configuration)
    }

    // MARK: - What the menus offer

    func url(for documentID: String) -> URL? { store.url(for: documentID) }
    func hasCover(_ documentID: String) -> Bool { store.hasCover(documentID) }

    /// Why Make a Cover is unavailable for a book, or nil when it can be made.
    func makeRefusal(title: String?, author: String?) -> String? {
        BookCoverDesign.refusal(title: title, author: author)?.description
    }

    // MARK: - 1. The book's own cover

    /// At import: an EPUB's own cover, when it has one and the book has no cover yet. Nothing
    /// is sent anywhere until the book exists on the home server.
    nonisolated static func bookCover(ofFileAt url: URL) -> Data? {
        guard url.pathExtension.lowercased() == "epub",
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= 512 * 1024 * 1024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let cover = EPUBImporter.cover(data),
              let clean = try? BookCoverImaging.sanitize(cover.data) else { return nil }
        return clean
    }

    func adoptBookCover(_ image: Data?, documentID: String) {
        guard let image, store.setIfAbsent(image, documentID: documentID, source: .book) else { return }
        coversLog.notice("book \(documentID.prefix(12), privacy: .public): kept its own cover")
        syncSoon()
    }

    // MARK: - 2. Find Cover… (Open Library)

    /// The candidates for a book. Only its title and author are sent.
    func search(title: String, author: String?) async -> Result<[OpenLibraryCovers.Candidate], OpenLibraryCovers.Failure> {
        let session = self.session
        return await OpenLibraryCovers.search(title: title, author: author, endpoint: Self.searchEndpoint) {
            try await session.data(from: $0)
        }
    }

    /// Open Library's search, or in a DEBUG build the address `BATON_DEBUG_OPEN_LIBRARY_SEARCH`
    /// names, so a probe can show the finder's offline and slow answers against a loopback port
    /// without touching the machine's network settings. By environment, never argv.
    nonisolated static var searchEndpoint: URL {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["BATON_DEBUG_OPEN_LIBRARY_SEARCH"], let url = URL(string: raw) {
            return url
        }
        #endif
        return OpenLibraryCovers.searchEndpoint
    }

    /// A candidate's picture, fetched over HTTPS from Open Library, bounded, decoded and
    /// re-encoded. `side` is how large it is kept: small for the sheet's tiles, full for a cover.
    func picture(_ url: URL, side: Int) async throws -> Data {
        let data: Data
        do {
            let (bytes, response) = try await session.bytes(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Host, scheme and status before a byte is read; a declared length past the cap too.
            let declared = response.expectedContentLength
            guard OpenLibraryCovers.acceptsDownload(from: response.url ?? url, status: status,
                                                    bytes: declared > 0 ? Int(declared) : 1) else {
                bytes.task.cancel()
                throw status == 404 || !(200..<300).contains(status) ? OpenLibraryCovers.Failure.http(status) : .notAnImage
            }
            // The cap holds while the bytes arrive, whatever the length said.
            let task = bytes.task
            data = try await OpenLibraryCovers.collect(bytes, limit: BookCoverImage.maximumSourceBytes) { task.cancel() }
        } catch let failure as OpenLibraryCovers.Failure {
            throw failure
        } catch {
            throw OpenLibraryCovers.failure(for: error)
        }
        do { return try BookCoverImaging.sanitize(data, maximumSide: side) } catch { throw OpenLibraryCovers.Failure.notAnImage }
    }

    /// The listener picked this one.
    func use(_ candidate: OpenLibraryCovers.Candidate, documentID: String) async throws {
        let image = try await picture(candidate.imageURL(.large), side: BookCoverImage.maximumSide)
        try store.set(image, documentID: documentID, source: .openLibrary)
        coversLog.notice("book \(documentID.prefix(12), privacy: .public): cover from Open Library \(candidate.coverID, privacy: .public)")
        syncSoon()
    }


    // MARK: - 3. Make a Cover

    func make(documentID: String, title: String, author: String?) throws {
        let design = try BookCoverDesign.make(title: title, author: author)
        try store.set(try BookCoverImaging.render(design), documentID: documentID, source: .made)
        coversLog.notice("book \(documentID.prefix(12), privacy: .public): made a cover (\(design.palette.name, privacy: .public), \(design.motif.rawValue, privacy: .public))")
        syncSoon()
    }

    // MARK: - 4. Choose Image… and Remove Cover

    /// A picture file, or an EPUB whose own cover to use.
    func choose(fileAt url: URL, documentID: String) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let image: Data
        if url.pathExtension.lowercased() == "epub" {
            guard let cover = Self.bookCover(ofFileAt: url) else { throw ChooseFailure.noCoverInBook }
            image = cover
        } else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= BookCoverImage.maximumSourceBytes else { throw BookCoverImaging.Failure.tooLarge }
            image = try BookCoverImaging.sanitize(try Data(contentsOf: url))
        }
        try store.set(image, documentID: documentID, source: .file)
        coversLog.notice("book \(documentID.prefix(12), privacy: .public): cover chosen from a file")
        syncSoon()
    }

    enum ChooseFailure: Error, CustomStringConvertible {
        case noCoverInBook
        var description: String { "That book file has no cover picture." }
    }

    func remove(documentID: String) {
        store.remove(documentID: documentID)
        coversLog.notice("book \(documentID.prefix(12), privacy: .public): cover removed")
        syncSoon()
    }

    // MARK: - The home server

    /// Settle every book's cover against a listing the device just read.
    func sync(_ listing: GatewayBookClient.Listing) async {
        guard let client = gateway() else { return }
        await engine.sync(books(in: listing), remote: remote(client))
    }

    /// The listing's newest job for each book this device has (newest first, as the home server
    /// lists them), with that job's cover.
    private func books(in listing: GatewayBookClient.Listing) -> [BookCoverSync.Book] {
        var seen = Set<String>()
        var books: [BookCoverSync.Book] = []
        for summary in listing.books where summary.status != .failed {
            guard let documentID = summary.documentID, seen.insert(documentID).inserted,
                  isKnown(documentID) || store.entry(documentID) != nil else { continue }
            books.append(BookCoverSync.Book(documentID: documentID, jobID: summary.id, server: summary.cover.map(Self.stamp)))
        }
        return books
    }

    private static func stamp(_ cover: BookJob.Cover) -> BookCoverStore.ServerCover {
        BookCoverStore.ServerCover(sha256: cover.sha256, changedAt: cover.changedAt, revision: cover.revision)
    }

    /// The gateway client as the engine calls it. A 404 is a home server from before covers.
    private func remote(_ client: GatewayBookClient) -> BookCoverSync.Remote {
        func mapping<T>(_ call: () async throws -> T) async throws -> T {
            do { return try await call() } catch GatewayBookError.http(404, _) { throw BookCoverSync.Unsupported() }
        }
        return BookCoverSync.Remote(
            upload: { jobID, image in try await mapping { Self.stamp(try await client.uploadCover(jobID, image: image)) } },
            remove: { jobID in try await mapping { Self.stamp(try await client.removeCover(jobID)) } },
            fetch: { jobID in try await mapping { try await client.cover(jobID) } },
            relist: { [weak self] in
                guard let self, let listing = try? await client.list() else { return nil }
                return self.books(in: listing)
            })
    }

    /// After a change here: read the listing and settle at once, so the other device has it on
    /// its next look rather than after this one's next.
    func syncSoon() {
        guard let client = gateway() else { return }
        Task {
            guard let listing = try? await client.list() else { return }
            await sync(listing)
        }
    }
}

// MARK: - The cover, wherever a book is shown

/// A book's cover, or the closed-book mark when it has none, at any size: the row, the open
/// book's header. The cover is a 2:3 picture shown whole inside the square the row reserves.
struct BookCoverArt: View {
    let covers: BookCovers?
    let documentID: String
    var side: CGFloat
    var cornerRadius: CGFloat = 6
    var glyphSize: CGFloat? = nil

    var body: some View {
        let url = covers?.url(for: documentID)
        ZStack {
            if let url {
                CachedArtwork(url: url, side: side * 2) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius * 0.6))
                        .shadow(color: .black.opacity(0.18), radius: side > 60 ? 4 : 1, y: 1)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        // Decorative: the title beside it says which book it is. The iPhone's cover menu carries
        // its own label.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var placeholder: some View {
        if let glyphSize {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary)
                Image(systemName: "book.closed").font(.system(size: glyphSize)).foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "book.closed").font(.title3).foregroundStyle(.secondary)
        }
    }
}

/// The cover items for a book's menus, the same on both apps. `choose` presents the platform's
/// own file picker.
struct BookCoverMenuItems: View {
    let covers: BookCovers
    let documentID: String
    let title: String
    let author: String?
    let choose: () -> Void
    var report: (String) -> Void = { _ in }

    var body: some View {
        Button("Find Cover…") {
            covers.finding = BookCovers.Request(documentID: documentID, title: title, author: author)
        }
        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        if let reason = covers.makeRefusal(title: title, author: author) {
            Button("Make a Cover (\(reason))") {}.disabled(true)
        } else {
            Button(covers.store.source(of: documentID) == .made ? "Make the Cover Again" : "Make a Cover") {
                do { try covers.make(documentID: documentID, title: title, author: author) } catch {
                    report(String(describing: error))
                }
            }
        }
        Button("Choose Image…", action: choose)
        if covers.hasCover(documentID) {
            Button("Remove Cover", role: .destructive) { covers.remove(documentID: documentID) }
        }
    }
}

// MARK: - Find Cover…

/// The candidates Open Library has for a book; the listener picks one.
struct BookCoverFinder: View {
    let covers: BookCovers
    let request: BookCovers.Request
    let done: () -> Void

    private enum Phase: Equatable {
        case searching
        case failed(String)
        case found([OpenLibraryCovers.Candidate])
    }

    @State private var phase = Phase.searching
    @State private var picked: Int?
    @State private var saving = false
    @State private var saveProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find a Cover").font(.title3.weight(.semibold))
                Text(lookingFor).font(.callout).foregroundStyle(.secondary)
                Text("Only the title and author are sent to Open Library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let saveProblem {
                Text(saveProblem).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Use Cover") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(picked == nil || saving)
                    .accessibilityIdentifier("cover-use")
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 520, idealHeight: 600)
        #endif
        .task { await search() }
    }

    private var lookingFor: String {
        if let author = request.author, !author.isEmpty { return "“\(request.title)” by \(author)" }
        return "“\(request.title)”"
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .searching:
            VStack(spacing: 10) {
                ProgressView()
                Text("Searching Open Library…").foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(spacing: 10) {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try Again") { Task { await search() } }
            }
            .padding()
        case let .found(candidates) where candidates.isEmpty:
            Text("Open Library has no cover for this book. You can make one or choose a picture instead.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
        case let .found(candidates):
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 14)], spacing: 16) {
                    ForEach(candidates) { candidate in
                        CoverCandidateTile(covers: covers, candidate: candidate, selected: picked == candidate.coverID)
                            .onTapGesture { picked = candidate.coverID }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(picked == candidate.coverID ? .isSelected : [])
                    }
                }
                .padding(4)
            }
        }
    }

    private func search() async {
        phase = .searching
        switch await covers.search(title: request.title, author: request.author) {
        case let .success(candidates):
            phase = .found(candidates)
            picked = candidates.first?.coverID
        case let .failure(failure):
            phase = .failed(failure.description)
        }
    }

    private func save() {
        guard case let .found(candidates) = phase, let candidate = candidates.first(where: { $0.coverID == picked }) else { return }
        saving = true
        saveProblem = nil
        Task {
            do {
                try await covers.use(candidate, documentID: request.documentID)
                saving = false
                done()
            } catch {
                saving = false
                saveProblem = (error as? OpenLibraryCovers.Failure)?.description ?? String(describing: error)
            }
        }
    }
}

/// One candidate: its picture, fetched and re-encoded small, and who and when.
private struct CoverCandidateTile: View {
    let covers: BookCovers
    let candidate: OpenLibraryCovers.Candidate
    let selected: Bool

    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let image {
                    Image(platformImage: image).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text(candidate.caption.isEmpty ? candidate.title : candidate.caption)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cover: \(candidate.title), \(candidate.caption)")
        .task(id: candidate.coverID) {
            do {
                let data = try await covers.picture(candidate.imageURL(.medium), side: 360)
                #if canImport(AppKit)
                image = NSImage(data: data)
                #else
                image = UIImage(data: data)
                #endif
            } catch {
                failed = true
            }
        }
    }
}
