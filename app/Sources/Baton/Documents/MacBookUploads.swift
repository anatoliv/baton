import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import OSLog

/// Books this Mac makes with its own voices, sent to the Baton server so the iPhone has them too
///. Before this, a book made on This Mac never left it: the iPhone adopts books from
/// the Baton server's listing, and a book made here was never on it.
///
/// Each book goes up as it is made: its shaped book first, then each chapter's read-along timing
/// and audio as the chapter is finished, checked by digest at the other end. The Baton server
/// keeps it as a job it never makes itself, listed with its document like any other, so the
/// iPhone adopts it through the same path, with the same place in the book and the same
/// "finished", which travel by document id. A book made here before this existed is sent once.
///
/// What is sent is remembered (`mac-book-uploads.json` beside the books), so nothing goes twice:
/// a chapter the Baton server already has is never sent again, and a book it no longer has
/// (deleted from the iPhone, or past its keep date) is never sent again either. One book at a
/// time, newest first; a Baton server that is away is asked again later, a little less often
/// each time, and at once when Baton comes to the front.
///
/// Sending is not "sent from this device" in `HomeServerBooks`' sense: no record is kept there,
/// and the Mac's own renderer keeps the book (`isMadeHere`), so the Mac never adopts its own book
/// a second time from the listing.
@MainActor
final class MacBookUploads {
    /// One book this Mac made, and how far it has gone up.
    struct Entry: Codable, Equatable, Sendable {
        var jobID: String
        var documentID: String
        /// When the book was made here, so the newest goes first.
        var createdAt: Date
        /// The Baton server holds the shaped book.
        var accepted = false
        /// Chapters the Baton server has (0-based).
        var sent: [Int] = []
        /// Nothing more is sent: every chapter is there, or the book went from one end or the
        /// other, or the Baton server refused it for good.
        var done = false
        /// Why it stopped before every chapter was there, for the log.
        var stopped: String? = nil
    }

    /// How long to wait before asking a Baton server that is away again.
    struct Retry: Sendable {
        var initial: Duration = .seconds(30)
        var maximum: Duration = .seconds(15 * 60)
    }

    private enum Step { case carryOn, retryLater }

    private let store: VersionedStore<[Entry]>
    private let books: BookStore
    private let clippings: ClippingStore
    private let homeServer: HomeServerBooks
    private let gateway: @MainActor () -> GatewayBookClient?
    private let log: Logger
    private let retry: Retry

    /// Told a book's job id once the Baton server has taken its shaped book, so whatever else
    /// belongs to the book (its cover, TBX-11064) can follow it there at once.
    var onAccepted: ((String) -> Void)?

    private var running = false
    private var again = false
    private var notBefore: Date?
    private var delay: Duration
    private var retryTask: Task<Void, Never>?
    /// Books asked about once this process, so a restart learns what the Baton server already has.
    private var checked: Set<String> = []
    /// What the local jobs looked like at the last nudge: nothing changed, nothing to do.
    private var lastSignature: String?

    init(directory: URL, books: BookStore, clippings: ClippingStore, homeServer: HomeServerBooks,
         gateway: @escaping @MainActor () -> GatewayBookClient?, log: Logger, retry: Retry = Retry()) {
        self.store = VersionedStore<[Entry]>(fileURL: directory.appendingPathComponent("mac-book-uploads.json"),
                                             currentVersion: 1, keepBackup: true, log: log)
        self.books = books
        self.clippings = clippings
        self.homeServer = homeServer
        self.gateway = gateway
        self.log = log
        self.retry = retry
        self.delay = retry.initial
    }

    var entries: [Entry] { store.load() ?? [] }

    func entry(forJob jobID: String) -> Entry? { entries.first { $0.jobID == jobID } }

    /// Whether a sending round is under way or waiting to retry, for tests.
    var isBusy: Bool { running }

    // MARK: - When to send

    /// The local jobs changed (a chapter finished, a book was made): send what is new. Cheap
    /// when nothing changed, since `refresh` calls it every second while a book is made.
    func jobsChanged(_ jobs: [BookJob]) {
        let signature = jobs.map { "\($0.id):\($0.status.rawValue):\($0.readyChapters)" }.joined(separator: ",")
        guard signature != lastSignature else { return }
        lastSignature = signature
        kick()
    }

    /// Send now, unless a round is running (it goes round again) or the Baton server was away a
    /// moment ago. `force` asks at once all the same: Baton came to the front, or a test.
    func kick(force: Bool = false) {
        if force {
            notBefore = nil
            delay = retry.initial
        }
        if running { again = true; return }
        if let notBefore, notBefore > Date() { return }
        guard gateway() != nil else { return }
        running = true
        Task { [weak self] in
            guard let self else { return }
            var step = Step.carryOn
            repeat {
                self.again = false
                step = await self.sendRound()
            } while self.again && step == .carryOn
            self.running = false
            self.scheduleRetry(after: step)
        }
    }

    /// Run rounds until there is nothing to send now, for tests: the same work `kick` does.
    @discardableResult
    func sendNow() async -> Bool {
        await sendRound() == .carryOn
    }

    private func scheduleRetry(after step: Step) {
        retryTask?.cancel()
        retryTask = nil
        guard step == .retryLater else {
            notBefore = nil
            delay = retry.initial
            return
        }
        let wait = delay
        notBefore = Date().addingTimeInterval(Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18)
        delay = min(delay * 2, retry.maximum)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            self.notBefore = nil
            self.kick()
        }
    }

    // MARK: - Delete rules (TBX-10985's, applied to a book made here)

    /// Remove from This Mac: the Baton server keeps its copy for the other devices, nothing more
    /// of the book is sent, and this Mac does not adopt that copy back from the listing.
    func keepOnServerOnly(documentID: String) {
        guard entries.contains(where: { $0.documentID == documentID }) else { return }
        change { all in
            for i in all.indices where all[i].documentID == documentID && !all[i].done {
                all[i].done = true
                all[i].stopped = Self.removedHere
            }
        }
        homeServer.hide(documentID: documentID)
    }

    static let removedHere = "removed from this Mac"
    static let deletedEverywhere = "deleted everywhere"

    /// Delete Everywhere: the Baton server's copy goes too, through `HomeServerBooks`' pending
    /// deletes, so a Baton server that is away is asked again until it answers.
    func deleteEverywhere(documentID: String) async {
        let held = entries.filter { $0.documentID == documentID && $0.accepted }.map(\.jobID)
        change { all in
            for i in all.indices where all[i].documentID == documentID {
                all[i].done = true
                all[i].stopped = Self.deletedEverywhere
            }
        }
        for jobID in held { await homeServer.cancelRemote(jobID: jobID) }
    }

    /// A book brought back from Recently removed is this Mac's to send again, as if it had never
    /// gone: what the Baton server still has is found there, and only what it lacks goes up.
    func forget(jobID: String) {
        change { $0.removeAll { $0.jobID == jobID } }
        checked.remove(jobID)
        lastSignature = nil
    }

    /// The listener reached the end of a book made here: the Baton server's copy starts its
    /// keep date too, as a book made there does.
    func markFinished(jobID: String) async {
        guard entry(forJob: jobID)?.accepted == true, let client = gateway() else { return }
        try? await client.markFinished(jobID)
    }

    // MARK: - Sending

    /// Books made here that are not on the list yet join it: every book this Mac has made that
    /// did not fail, except one removed from this Mac and a job kept only so a voice change can
    /// be stopped (it goes when the change ends).
    private func enroll() {
        let known = Set(entries.map(\.jobID))
        let hidden = Set(homeServer.hiddenDocumentIDs)
        let keptForStop = Set(homeServer.voiceChanges.all.compactMap(\.previousJobID))
        let local = books.list().filter { $0.status != .failed && !keptForStop.contains($0.id) }
        // This Mac's book for each document now: the newest job it has for it.
        var current: [String: String] = [:]
        for job in local where current[job.book.documentID] == nil { current[job.book.documentID] = job.id }
        let new = local.filter { !known.contains($0.id) && !hidden.contains($0.book.documentID) }
        change { all in
            all += new.map { Entry(jobID: $0.id, documentID: $0.book.documentID, createdAt: $0.createdAt) }
            // A job replaced by a newer one that is this Mac's book again (Stop on a voice
            // change goes back to it) goes up again, and replaces the newer copy in turn.
            for i in all.indices where all[i].stopped?.hasPrefix(Self.madeAgain) == true
                && current[all[i].documentID] == all[i].jobID {
                all[i] = Entry(jobID: all[i].jobID, documentID: all[i].documentID, createdAt: all[i].createdAt)
                checked.remove(all[i].jobID)
            }
        }
        if !new.isEmpty { log.notice("\(new.count) books made on this Mac to send to the Baton server") }
        reopenFinishedTooEarly()
    }

    /// A book a build before TBX-11088 marked done with chapters still to send (the round ran
    /// before its chapters reached Clippings) goes up again: the Baton server kept it with those
    /// chapters queued and the iPhone waited for them for ever. Only a book finished
    /// without a reason, still made here, and with a chapter on this Mac that never went up; a
    /// chapter removed from this Mac on purpose does not count. The next round asks the Baton
    /// server what it has and sends only the rest.
    private func reopenFinishedTooEarly() {
        let reopen = entries.filter { entry in
            guard entry.done, entry.stopped == nil, entry.accepted, let job = books.load(entry.jobID) else { return false }
            return !isAllSent(job, sent: entry.sent)
        }.map(\.jobID)
        guard !reopen.isEmpty else { return }
        change { all in
            for i in all.indices where reopen.contains(all[i].jobID) { all[i].done = false }
        }
        for jobID in reopen {
            checked.remove(jobID)
            log.notice("book \(jobID.prefix(12), privacy: .public): marked sent with chapters missing on the Baton server; sending them")
        }
    }

    static let madeAgain = "made again as"

    private func sendRound() async -> Step {
        guard let client = gateway() else { return .carryOn }
        enroll()
        for entry in entries.filter({ !$0.done }).sorted(by: { $0.createdAt > $1.createdAt }) {
            if await send(entry.jobID, client) == .retryLater { return .retryLater }
        }
        return .carryOn
    }

    /// The chapters of `job` that are on this Mac as that job made them: in Clippings with the
    /// audio the job finished. A chapter removed from this Mac, or still in an older voice while
    /// the book is made again, is not.
    private func present(_ job: BookJob) -> [(index: Int, item: ClippingStore.Item, sha: String, seconds: Double, file: String)] {
        job.chapters.enumerated().compactMap { index, state in
            guard case let .ready(file, _, seconds, sha) = state,
                  let item = clippings.item(documentID: job.book.documentID, chapterIndex: index),
                  item.isPresent, item.clipping.sha256 == sha else { return nil }
            return (index, item, sha, item.clipping.durationSeconds ?? seconds, file)
        }
    }

    /// Whether nothing of `job` is left to send: it is made, and every chapter it made is either
    /// on this Mac and sent, or was removed from this Mac on purpose (Remove Download). A chapter
    /// made but not yet moved into Clippings still has its audio in the job's folder, which
    /// adoption empties; it is still to send, not removed (TBX-11088: a round between the job
    /// becoming ready and `DocumentLibrary.refresh` adopting its chapters saw none of them
    /// present, and finished the book with no chapter sent).
    private func isAllSent(_ job: BookJob, sent: [Int]) -> Bool {
        guard job.status == .ready else { return false }
        let here = Set(present(job).map(\.index))
        return job.chapters.enumerated().allSatisfy { index, state in
            if here.contains(index) { return sent.contains(index) }
            guard case let .ready(file, _, _, _) = state else { return false }
            return books.chapterURL(job.id, file: file) == nil
        }
    }

    private func send(_ jobID: String, _ client: GatewayBookClient) async -> Step {
        guard let entry = entry(forJob: jobID) else { return .carryOn }
        guard let job = books.load(jobID) else {
            stop(jobID, "gone from this Mac")
            return .carryOn
        }
        if job.status == .failed {
            // A book that failed here is not left half there.
            stop(jobID, "failed on this Mac")
            if entry.accepted { await homeServer.cancelRemote(jobID: jobID) }
            return .carryOn
        }
        var waiting = present(job).filter { !entry.sent.contains($0.index) }
        // Nothing new since the last round: no need to ask the Baton server anything.
        if entry.accepted, checked.contains(jobID), waiting.isEmpty {
            if isAllSent(job, sent: entry.sent) { finish(jobID) }
            return .carryOn
        }
        // The shaped book first, or, after a restart, what the Baton server already has.
        do {
            let summary: BookJob.Summary
            if entry.accepted {
                summary = try await client.status(jobID)
            } else {
                summary = try await client.upload(job.book)
                log.notice("book \(jobID.prefix(12), privacy: .public): sent \"\(job.book.title, privacy: .private)\" to the Baton server")
                onAccepted?(jobID)
            }
            checked.insert(jobID)
            let there = summary.chapters.filter { $0.state == "ready" }.map(\.index)
            change { all in
                guard let i = all.firstIndex(where: { $0.jobID == jobID }) else { return }
                all[i].accepted = true
                all[i].sent = Array(Set(all[i].sent).union(there)).sorted()
            }
        } catch {
            return failed(jobID, error, accepted: entry.accepted)
        }
        // Deleted while the shaped book was on its way: it goes from there too. Removed from
        // this Mac meanwhile, it stays there for the other devices, as it would have anyway.
        if self.entry(forJob: jobID)?.done != false {
            if self.entry(forJob: jobID)?.stopped == Self.deletedEverywhere { await homeServer.cancelRemote(jobID: jobID) }
            return .carryOn
        }
        if !entry.accepted { await retireOlder(than: jobID, documentID: job.book.documentID) }
        if job.finishedAt != nil, !entry.accepted { try? await client.markFinished(jobID) }

        let sent = Set(self.entry(forJob: jobID)?.sent ?? [])
        waiting = present(job).filter { !sent.contains($0.index) }
        for chapter in waiting {
            guard self.entry(forJob: jobID)?.done == false else { return .carryOn }
            do {
                let timing = homeServer.readAlong.load(forAudio: chapter.sha) ?? books.chapterTiming(jobID, file: chapter.file)
                if let timing { try await client.uploadTiming(jobID, number: chapter.index + 1, timing: timing) }
                let audio = try Data(contentsOf: chapter.item.url)
                // The file changed under it (made again since): the next round sends the new one.
                guard SHA256Digest.hex(of: audio) == chapter.sha else { continue }
                _ = try await client.uploadChapter(jobID, number: chapter.index + 1, audio: audio, seconds: chapter.seconds)
            } catch {
                return failed(jobID, error, accepted: true)
            }
            change { all in
                guard let i = all.firstIndex(where: { $0.jobID == jobID }) else { return }
                all[i].sent = Array(Set(all[i].sent).union([chapter.index])).sorted()
            }
            log.notice("book \(jobID.prefix(12), privacy: .public): chapter \(chapter.index + 1) sent to the Baton server")
        }
        if isAllSent(job, sent: self.entry(forJob: jobID)?.sent ?? []) { finish(jobID) }
        return .carryOn
    }

    /// A book made here again (another voice, a corrected pronunciation) replaces the copy sent
    /// before, once the new one is there, so the iPhone follows it to the new job
    /// rather than keeping two.
    private func retireOlder(than jobID: String, documentID: String) async {
        let older = entries.filter { $0.documentID == documentID && $0.jobID != jobID && $0.accepted }.map(\.jobID)
        guard !older.isEmpty else { return }
        change { all in
            for i in all.indices where older.contains(all[i].jobID) {
                all[i].done = true
                all[i].stopped = all[i].stopped ?? "\(Self.madeAgain) \(jobID.prefix(12))"
            }
        }
        for old in older {
            await homeServer.cancelRemote(jobID: old)
            log.notice("book \(old.prefix(12), privacy: .public): replaced on the Baton server by \(jobID.prefix(12), privacy: .public)")
        }
    }

    /// What a refusal means for the book: try later (away, full, an older gateway without the
    /// route), or never (it makes this book itself, the chapter is too large, it has gone there).
    private func failed(_ jobID: String, _ error: Error, accepted: Bool) -> Step {
        guard case let .http(status, message)? = error as? GatewayBookError else {
            log.error("book \(jobID.prefix(12), privacy: .public): the Baton server is away, will send it later: \(String(describing: error), privacy: .public)")
            return .retryLater
        }
        switch status {
        case 404 where accepted:
            stop(jobID, "no longer on the Baton server")
            return .carryOn
        case 409:
            stop(jobID, "the Baton server makes this book itself")
            return .carryOn
        case 413:
            stop(jobID, "too large for the Baton server: \(message)")
            return .carryOn
        default:
            log.error("book \(jobID.prefix(12), privacy: .public): the Baton server answered \(status), will send it later: \(message, privacy: .public)")
            return .retryLater
        }
    }

    private func finish(_ jobID: String) {
        change { all in
            guard let i = all.firstIndex(where: { $0.jobID == jobID }), !all[i].done else { return }
            all[i].done = true
        }
        log.notice("book \(jobID.prefix(12), privacy: .public): every chapter is on the Baton server")
    }

    private func stop(_ jobID: String, _ why: String) {
        change { all in
            guard let i = all.firstIndex(where: { $0.jobID == jobID }), !all[i].done else { return }
            all[i].done = true
            all[i].stopped = why
        }
        log.notice("book \(jobID.prefix(12), privacy: .public): not sent further: \(why, privacy: .public)")
    }

    private func change(_ update: (inout [Entry]) -> Void) {
        var all = entries
        let before = all
        update(&all)
        if all != before { _ = store.save(all) }
    }
}
