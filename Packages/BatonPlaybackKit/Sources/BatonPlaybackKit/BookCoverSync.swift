import Foundation

/// Settles book covers with the home server: what each listing says against what
/// this device has, one book at a time, by `BookCoverStore.decide`.
///
/// Every call to the home server is awaited, and the listener can change a cover while one is on
/// its way. Two rules keep that change (the acceptance review's two races):
///
/// - **Upload.** What is recorded as sent is the digest that went, not whatever the entry holds
///   when the answer comes back (`BookCoverStore.markSynced(pushed:)`). A cover chosen while
///   another was uploading still needs sending, and goes on the next pass.
/// - **Download.** A fetched cover is applied only if this device's entry is still the one the
///   decision was made on. A pick made while the fetch was out wins, and goes up on the next pass.
///
/// A `sync` asked for while one runs does not run beside it: it asks the running one for one more
/// pass, over a fresh listing.
///
/// The home server is reached through `Remote`, three closures, so the app hands in its gateway
/// client and a test hands in one that pauses mid-call.
@MainActor
public final class BookCoverSync {
    /// One book in a listing: its document, the job the home server lists for it now, and that
    /// job's cover (nil: never set there).
    public struct Book: Equatable, Sendable {
        public var documentID: String
        public var jobID: String
        public var server: BookCoverStore.ServerCover?

        public init(documentID: String, jobID: String, server: BookCoverStore.ServerCover?) {
            self.documentID = documentID
            self.jobID = jobID
            self.server = server
        }
    }

    public struct Remote {
        /// Send a cover; answers with what the home server now keeps.
        public var upload: (_ jobID: String, _ image: Data) async throws -> BookCoverStore.ServerCover
        /// Remove it there; answers with the removal's stamp.
        public var remove: (_ jobID: String) async throws -> BookCoverStore.ServerCover
        /// Its bytes, or nil when the home server has none.
        public var fetch: (_ jobID: String) async throws -> Data?
        /// The listing again, for one more pass; nil when it cannot be read.
        public var relist: () async -> [Book]?

        public init(upload: @escaping (String, Data) async throws -> BookCoverStore.ServerCover,
                    remove: @escaping (String) async throws -> BookCoverStore.ServerCover,
                    fetch: @escaping (String) async throws -> Data?,
                    relist: @escaping () async -> [Book]?) {
            self.upload = upload
            self.remove = remove
            self.fetch = fetch
            self.relist = relist
        }
    }

    /// Thrown by a `Remote` call for a job whose home server does not keep covers (a gateway from
    /// before them answers 404): that job is not asked again this run.
    public struct Unsupported: Error {
        public init() {}
    }

    public let store: BookCoverStore
    /// Decodes a fetched picture as an image and re-encodes it (`BookCoverImaging.sanitize`).
    public var sanitize: (Data) throws -> Data
    public var log: (String) -> Void

    private var syncing = false
    private var again = false
    private var unsupported: Set<String> = []

    public init(store: BookCoverStore, sanitize: @escaping (Data) throws -> Data, log: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.sanitize = sanitize
        self.log = log
    }

    /// Whether a pass is running, for tests.
    public var isSyncing: Bool { syncing }

    /// Settle every book's cover against `books`, and again over a fresh listing for as long as
    /// a pass leaves something to do or another sync was asked for meanwhile.
    public func sync(_ books: [Book], remote: Remote) async {
        guard !syncing else {
            again = true
            return
        }
        syncing = true
        defer { syncing = false }
        var current = books
        var passes = 0
        repeat {
            again = false
            passes += 1
            for book in current where !unsupported.contains(book.jobID) {
                await settle(book, remote: remote)
            }
            guard again, passes < 5, let fresh = await remote.relist() else { break }
            current = fresh
        } while true
    }

    private func settle(_ book: Book, remote: Remote) async {
        let documentID = book.documentID, jobID = book.jobID, server = book.server
        let decidedOn = store.entry(documentID)
        let name = "book \(documentID.prefix(12))"
        do {
            switch BookCoverStore.decide(local: decidedOn, jobID: jobID, server: server) {
            case .nothing:
                return
            case .settled:
                store.markSynced(documentID: documentID, jobID: jobID, serverChangedAt: server?.changedAt,
                                 serverRevision: server?.revision)
            case .push:
                guard let entry = decidedOn, entry.hasCover, let sha = entry.sha256,
                      let image = store.imageData(documentID) else { return }
                let kept = try await remote.upload(jobID, image)
                store.markSynced(documentID: documentID, jobID: jobID, serverChangedAt: kept.changedAt,
                                 serverRevision: kept.revision, pushed: .cover(sha))
                if store.entry(documentID)?.needsPush == true { again = true }
                log("\(name): cover sent to the Baton server")
            case .pushRemoval:
                let kept = try await remote.remove(jobID)
                store.markSynced(documentID: documentID, jobID: jobID, serverChangedAt: kept.changedAt,
                                 serverRevision: kept.revision, pushed: .removal)
                if store.entry(documentID)?.needsPush == true { again = true }
                log("\(name): cover removal sent to the Baton server")
            case .pull:
                guard let data = try await remote.fetch(jobID) else { return }
                // Changed here while the picture was on its way: this device's pick wins.
                guard store.entry(documentID) == decidedOn else {
                    again = true
                    log("\(name): cover changed here during a fetch; keeping this device's")
                    return
                }
                try store.set(try sanitize(data), documentID: documentID, source: .homeServer, push: false,
                              syncedJobID: jobID, serverChangedAt: server?.changedAt, serverRevision: server?.revision)
                log("\(name): cover fetched from the Baton server")
            case .removeLocal:
                guard store.entry(documentID) == decidedOn else { again = true; return }
                store.remove(documentID: documentID, push: false, syncedJobID: jobID, serverChangedAt: server?.changedAt,
                             serverRevision: server?.revision)
                log("\(name): cover removed on another device")
            }
        } catch is Unsupported {
            unsupported.insert(jobID)
        } catch {
            log("\(name): cover not settled with the Baton server: \(error)")
        }
    }
}
