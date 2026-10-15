#if os(iOS)
import BatonShareKit
import BatonSubsonicKit
import Foundation
import UIKit

/// A single iOS background session for explicitly requested, sealed uploads.
/// Ticket files own the key/metadata; taskDescription contains only an opaque job
/// UUID and body kind. Redirects are refused rather than forwarding the bearer.
@MainActor
final class BackgroundShareUploadEngine: NSObject {
    nonisolated static let sessionIdentifier = "io.tonebox.baton.share-uploads"
    typealias Job = BackgroundShareUploadStore.Job

    enum Failure: LocalizedError {
        case upload
        var errorDescription: String? {
            "Couldn't finish uploading the shared song. Try again from Share Song."
        }
    }

    let store: BackgroundShareUploadStore
    private let sessionConfiguration: URLSessionConfiguration?
    private let backgroundConfiguration: URLSessionConfiguration?
    private let secretProvider: () -> String?
    private let suppliedAppAttest: SongShareAppAttest?
    var onCreated: (() -> Void)?
    var onLedgerChanged: ((ShareLedger) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onPendingChanged: ((Int) -> Void)?
    var backgroundCompletionHandler: (() -> Void)? {
        didSet { finishBackgroundEventsIfPossible() }
    }
    private var jobs: [UUID: Job] = [:]
    private var activeTasks: [UUID: Int] = [:]
    private var waiters: [UUID: CheckedContinuation<ShareLedger.Record, any Error>] = [:]
    private var hasRestored = false
    private var restoring = false
    private var reconcilingRestoredJobs = false
    private var restoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventsFinished = false
    private var creating = false
    private var createWaiters: [CheckedContinuation<Void, Never>] = []
    private lazy var appAttest = suppliedAppAttest ?? SongShareAppAttest(directory: store.directory.deletingLastPathComponent().appendingPathComponent("SongShareAttestKeys"))
    private var delegateOperations = 0
    private let delegateState = BackgroundShareUploadDelegateState()

    private lazy var session: URLSession = {
        let config = backgroundConfiguration ?? sessionConfiguration ?? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    /// The optional fixture configuration still applies to foreground and upload work.
    /// An explicit upload configuration overrides only file transfers; JSON requests
    /// remain foreground. Ordinary callers retain the stable production session ID.
    /// A supplied coordinator enables isolated integration; nil retains Apple App Attest.
    init(directory: URL, ledgerURL: URL, configuration: URLSessionConfiguration? = nil,
         backgroundConfiguration: URLSessionConfiguration? = nil,
         appAttest: SongShareAppAttest? = nil,
         secretProvider: @escaping () -> String? = { NavidromeKeychain.secret(account: SongSharing.secretAccount) }) {
        sessionConfiguration = configuration
        self.backgroundConfiguration = backgroundConfiguration
        suppliedAppAttest = appAttest
        self.secretProvider = secretProvider
        store = BackgroundShareUploadStore(directory: directory, ledgerURL: ledgerURL)
        super.init()
    }

    /// Called at app initialization and by the app delegate, before screens load.
    /// Every launch reuses the session identifier and enumerates its tasks once.
    func restore() async {
        if hasRestored {
            for job in Array(jobs.values) where activeTasks[job.id] == nil && (job.finalized != nil || job.failure != nil) { commit(job) }
            for job in Array(jobs.values) where activeTasks[job.id] == nil && job.created != nil {
                if job.finalized != nil || job.failure != nil { commit(job) }
                else { await reconcile(job.id, retryExhausted: true) }
            }
            for job in Array(jobs.values) where job.created == nil && job.failure == nil && job.createProof != nil {
                await recoverCreate(job.id)
            }
            return
        }
        if restoring {
            await withCheckedContinuation { restoreWaiters.append($0) }
            return
        }
        restoring = true
        let loaded: (jobs: [Job], orphans: [UUID])
        do { loaded = try store.load() }
        catch {
            restoring = false
            for waiter in restoreWaiters { waiter.resume() }
            restoreWaiters.removeAll()
            return // Keep files intact; a later explicit restore can retry the read.
        }
        jobs = Dictionary(loaded.jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tasks = await session.allTasks
        for task in tasks {
            guard let ticket = Self.ticket(task), let job = jobs[ticket.id],
                  job.created != nil, job.finalized == nil, job.failure == nil,
                  job.nextKind == ticket.kind, activeTasks[ticket.id] == nil else {
                task.cancel()
                continue
            }
            activeTasks[ticket.id] = task.taskIdentifier
            if task.state == .suspended { task.resume() }
        }
        for id in loaded.orphans { try? store.remove(id) }
        hasRestored = true
        reconcilingRestoredJobs = true
        restoring = false
        for waiter in restoreWaiters { waiter.resume() }
        restoreWaiters.removeAll()
        pendingChanged()
        for job in Array(jobs.values) where activeTasks[job.id] == nil {
            if job.finalized != nil || job.failure != nil {
                commit(job)
            } else if job.created == nil {
                if job.createProof != nil { await recoverCreate(job.id); continue }
                // A create whose response was lost is ambiguous. Never POST another
                // create automatically; the service sweeps the orphan pending share.
                fail(job.id, reason: "network")
            } else {
                await reconcile(job.id, retryExhausted: true)
            }
        }
        reconcilingRestoredJobs = false
        finishBackgroundEventsIfPossible()
    }

    func enqueue(_ prepared: PreparedShare, client: ShareClient, songID: String,
                 title: String, artist: String, attestationPolicy: ShareAttestationPolicy? = nil,
                 onHandOff: (@MainActor () -> Void)? = nil) async throws -> ShareLedger.Record {
        await restore()
        await acquireCreate()
        var job: Job
        do { job = try store.stage(prepared, base: client.base, songID: songID, title: title, artist: artist) }
        catch { releaseCreate(); throw error }
        jobs[job.id] = job
        pendingChanged()
        // Only this explicitly invoked path creates a share. Reserve a brief UIKit
        // background interval for its small JSON request; large bodies use URLSession.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Create song share", expirationHandler: nil)

        do {
            let body = try JSONEncoder().encode(prepared.request)
            if let policy = attestationPolicy {
                job.createProof = try await appAttest.proof(client: client, policy: policy, body: body, requestID: job.id.uuidString)
                if job.createProof != nil { job.createBody = body; try store.save(job); jobs[job.id] = job }
            }
            var request = URLRequest(url: client.base.appendingPathComponent("v1/share/shares"))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("Bearer \(client.secret)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            if let proof = job.createProof { request.setValue(try proof.headerValue(), forHTTPHeaderField: ShareAttestationProof.header) }
            // Ephemeral foreground session also refuses redirects with credentials.
            let foreground = URLSession(configuration: sessionConfiguration ?? .ephemeral, delegate: BackgroundShareNoRedirectDelegate(), delegateQueue: nil)
            defer { foreground.finishTasksAndInvalidate() }
            let (data, response) = try await foreground.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if job.createProof == nil || (status >= 400 && status < 500 && status != 429) { fail(job.id, reason: "other") }
                throw Failure.upload
            }
            try store.attach(try JSONDecoder().decode(CreateShareResponse.self, from: data), to: &job)
            jobs[job.id] = job
            onCreated?()
        } catch {
            if jobs[job.id] != nil, job.createProof == nil { fail(job.id, reason: "network") }
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            releaseCreate()
            throw Failure.upload
        }
        if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        releaseCreate()
        return try await withCheckedThrowingContinuation { continuation in
            waiters[job.id] = continuation
            schedule(job.id)
            // Only this invocation's durable ticket/file and resumed owned task unlock
            // its composer. Global pending/progress and onCreated are too early.
            if activeTasks[job.id] != nil { onHandOff?() }
        }
    }

    private func acquireCreate() async {
        if creating { await withCheckedContinuation { createWaiters.append($0) } }
        else { creating = true }
    }
    private func releaseCreate() {
        if createWaiters.isEmpty { creating = false }
        else { createWaiters.removeFirst().resume() }
    }
    private func recoverCreate(_ id: UUID) async {
        await acquireCreate()
        defer { releaseCreate() }
        guard var job = jobs[id], job.created == nil, let body = job.createBody, let proof = job.createProof,
              let secret = secretProvider(), !secret.isEmpty else { return }
        var request = URLRequest(url: job.base.appendingPathComponent("v1/share/shares"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let foreground = URLSession(configuration: sessionConfiguration ?? .ephemeral, delegate: BackgroundShareNoRedirectDelegate(), delegateQueue: nil)
        defer { foreground.finishTasksAndInvalidate() }
        do {
            request.setValue(try proof.headerValue(), forHTTPHeaderField: ShareAttestationProof.header)
            let (data, response) = try await foreground.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode >= 500 || http.statusCode == 429 { return }
            guard (200..<300).contains(http.statusCode) else { fail(id, reason: "network"); return }
            try store.attach(JSONDecoder().decode(CreateShareResponse.self, from: data), to: &job)
            jobs[id] = job
            onCreated?()
            schedule(id)
        } catch { /* Preserve exact signed request/key after an unmeasurable response. */ }
    }

    private func schedule(_ id: UUID) {
        guard activeTasks[id] == nil, var job = jobs[id], let created = job.created,
              let kind = job.nextKind else { return }
        guard job.record.expiresAt > Date() else { fail(id, reason: "network"); return }
        guard (job.attempts[kind] ?? 0) < 3 else {
            if kind == "finalize" {
                // Its response may have been lost after acceptance. Keep the key
                // and ticket until a foreground ownership read resolves it.
                waiters.removeValue(forKey: id)?.resume(throwing: Failure.upload)
            } else { fail(id, reason: "network") }
            return
        }
        guard let secret = secretProvider(), !secret.isEmpty else {
            // Keychain may be locked before the first unlock. Keep the ticket; the
            // next foreground restore must be able to resume rather than lose it.
            return
        }
        let path: String
        switch kind {
        case "audio": path = created.uploads.audio
        case "art": path = created.uploads.art
        case "card": path = created.uploads.card
        default: path = "/v1/share/shares/\(created.id)/finalize"
        }
        guard let url = URL(string: path, relativeTo: job.base)?.absoluteURL,
              BackgroundShareUploadStore.sameOrigin(url, job.base) else {
            fail(id, reason: "other")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = kind == "finalize" ? "POST" : "PUT"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        do {
            guard FileManager.default.fileExists(atPath: store.file(id, kind: kind).path) else {
                fail(id, reason: "other")
                return
            }
            // Persist the attempt before creating/resuming a task. An interrupted
            // launch never races a second live task for the same job/body.
            job.attempts[kind, default: 0] += 1
            try store.save(job)
            jobs[id] = job
            let task = session.uploadTask(with: request, fromFile: store.file(id, kind: kind))
            task.taskDescription = "\(id.uuidString):\(kind)"
            activeTasks[id] = task.taskIdentifier
            task.resume()
        } catch { fail(id, reason: "other") }
    }

    /// Lost PUT/finalize responses are reconciled against ownership. Retrying the
    /// same job never creates a second share or increments finalization twice.
    private func reconcile(_ id: UUID, retryExhausted: Bool = false) async {
        guard let job = jobs[id], let created = job.created else { return }
        guard let secret = secretProvider(), !secret.isEmpty else { return }
        do {
            let reconciliationSession = URLSession(configuration: sessionConfiguration ?? .ephemeral, delegate: BackgroundShareNoRedirectDelegate(), delegateQueue: nil)
            defer { reconciliationSession.finishTasksAndInvalidate() }
            let summaries = try await ShareClient(base: job.base, secret: secret, session: reconciliationSession).list()
            guard let summary = summaries.first(where: { $0.id == created.id }) else {
                fail(id, reason: "network")
                return
            }
            if summary.status == .ready { finalize(id, summary: summary) }
            else if summary.status == .pending {
                if retryExhausted, var current = jobs[id], let kind = current.nextKind,
                   (current.attempts[kind] ?? 0) >= 3 {
                    current.attempts[kind] = 0
                    try store.save(current)
                    jobs[id] = current
                }
                schedule(id)
            }
            else { fail(id, reason: "other") }
        } catch {
            // This read is optional: the same upload may safely be retried, with
            // duplicate-state responses verified in completed() below.
            schedule(id)
        }
    }

    private func completed(id: UUID, kind: String, taskID: Int, status: Int, data: Data, failed: Bool) async {
        if restoring {
            await withCheckedContinuation { restoreWaiters.append($0) }
        }
        guard activeTasks[id] == taskID, var job = jobs[id] else { return }
        activeTasks[id] = nil
        if failed || status >= 500 || status == 429 {
            if kind == "finalize" { await reconcile(id) }
            else { schedule(id) }
            return
        }
        if status == 409 {
            let body = try? JSONDecoder().decode(ShareErrorBody.self, from: data)
            let duplicate = ["audio": "The audio is already uploaded.", "art": "The artwork is already uploaded.",
                             "card": "The card is already uploaded."]
            if body?.code == "state", body?.error == duplicate[kind], kind != "finalize" {
                job.completedKinds.insert(kind)
                do { try store.save(job); jobs[id] = job; schedule(id) }
                catch { fail(id, reason: "other") }
            } else { await reconcile(id) }
            return
        }
        guard (200..<300).contains(status) else { fail(id, reason: "other"); return }
        if kind == "finalize" {
            guard let summary = try? JSONDecoder().decode(ShareSummary.self, from: data),
                  summary.id == job.created?.id, summary.status == .ready else {
                await reconcile(id)
                return
            }
            finalize(id, summary: summary)
        } else {
            job.completedKinds.insert(kind)
            do { try store.save(job); jobs[id] = job; schedule(id) }
            catch { fail(id, reason: "other") }
        }
    }

    private func finalize(_ id: UUID, summary: ShareSummary) {
        guard var job = jobs[id] else { return }
        job.finalized = summary
        do { try store.save(job); jobs[id] = job; commit(job) }
        catch { waiters.removeValue(forKey: id)?.resume(throwing: Failure.upload) }
    }

    private func fail(_ id: UUID, reason: String) {
        guard var job = jobs[id] else { return }
        job.failure = reason
        do { try store.save(job); jobs[id] = job; commit(job) }
        catch { waiters.removeValue(forKey: id)?.resume(throwing: Failure.upload) }
    }

    private func commit(_ job: Job) {
        do {
            let ledger = try store.commit(job)
            onLedgerChanged?(ledger)
            jobs[job.id] = nil
            try? store.remove(job.id)
            pendingChanged()
            if let record = ledger.records.first(where: { $0.id == job.record.id }), job.finalized != nil {
                waiters.removeValue(forKey: job.id)?.resume(returning: record)
            } else { waiters.removeValue(forKey: job.id)?.resume(throwing: Failure.upload) }
        } catch { waiters.removeValue(forKey: job.id)?.resume(throwing: Failure.upload) }
    }

    private func pendingChanged() { onPendingChanged?(jobs.count) }

    private func finishBackgroundEventsIfPossible() {
        guard eventsFinished, delegateState.pending == 0, !restoring, !reconcilingRestoredJobs, let completion = backgroundCompletionHandler else { return }
        backgroundCompletionHandler = nil
        eventsFinished = false
        completion()
    }

    nonisolated private static func ticket(_ task: URLSessionTask) -> (id: UUID, kind: String)? {
        guard let description = task.taskDescription else { return nil }
        let parts = description.split(separator: ":")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              ["audio", "art", "card", "finalize"].contains(String(parts[1])) else { return nil }
        return (id, String(parts[1]))
    }
}

extension BackgroundShareUploadEngine: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        delegateState.append(data, task: dataTask.taskIdentifier)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                               totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0, let ticket = Self.ticket(task),
              delegateState.shouldForward(task.taskIdentifier, fraction: Double(totalBytesSent) / Double(totalBytesExpectedToSend)) else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in
            guard let job = self.jobs[ticket.id] else { return }
            let total = job.bodies.reduce(0) { $0 + $1.bytes }
            let done = job.bodies.filter { job.completedKinds.contains($0.kind) }.reduce(0) { $0 + $1.bytes }
            let current = job.bodies.first { $0.kind == ticket.kind }?.bytes ?? 0
            self.onProgress?(0.05 + 0.90 * (Double(done) + fraction * Double(current)) / Double(max(total, 1)))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let data = delegateState.take(task.taskIdentifier)
        guard let ticket = Self.ticket(task) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let failed = error != nil
        delegateState.beginCallback()
        Task { @MainActor in
            self.delegateOperations += 1
            await self.completed(id: ticket.id, kind: ticket.kind, taskID: task.taskIdentifier,
                                 status: status, data: data, failed: failed)
            self.delegateOperations -= 1
            self.delegateState.endCallback()
            self.finishBackgroundEventsIfPossible()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.eventsFinished = true
            self.finishBackgroundEventsIfPossible()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Delegate callbacks arrive off the main actor. Responses are bounded and kept
/// only in memory; the durable phase, not an untrusted response, drives recovery.
private final class BackgroundShareUploadDelegateState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Int: Data] = [:]
    private var progress: [Int: Double] = [:]
    private var callbacks = 0
    var pending: Int { lock.lock(); defer { lock.unlock() }; return callbacks }
    func beginCallback() { lock.lock(); callbacks += 1; lock.unlock() }
    func endCallback() { lock.lock(); callbacks -= 1; lock.unlock() }
    func append(_ data: Data, task: Int) {
        lock.lock(); defer { lock.unlock() }
        if (responses[task]?.count ?? 0) + data.count <= 256 * 1024 {
            responses[task, default: Data()].append(data)
        }
    }
    func take(_ task: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        progress[task] = nil
        return responses.removeValue(forKey: task) ?? Data()
    }
    func shouldForward(_ task: Int, fraction: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fraction - (progress[task] ?? -1) >= 0.01 || fraction >= 1 else { return false }
        progress[task] = fraction
        return true
    }
}

private final class BackgroundShareNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
