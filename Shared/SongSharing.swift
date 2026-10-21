import BatonPlaybackKit
import BatonShareKit
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// Sharing a song with someone outside the LAN (docs/plan-song-sharing.md, specs/song-sharing.md).
///
/// One object for both apps, because everything here is the same on both: fetch the song from
/// the owner's own server, take its waveform and its artwork's colour, render the preview card,
/// seal, upload, and remember the link. The protocol itself (`PreparedShare`, `ShareClient`,
/// `ShareLedger`) lives in BatonShareKit, where it is tested on Linux against the real service;
/// this file is only what needs Apple frameworks or the app's own caches.
///
/// Nothing starts unless someone presses Share (or asks the music friend to, after sharing
/// once by hand). On iOS only, an explicitly started upload may finish in the background.
/// The ledger is otherwise refreshed when Shared Links is opened.
@MainActor
@Observable
final class SongSharing {
    static let shared = SongSharing()

    /// The install secret (spec §1), in the same Keychain the server credentials use.
    static let secretAccount = "baton.share.installSecret"
    /// The name the composer remembers for "From".
    static let fromKey = "baton.share.fromName"
    /// Set once the first-share disclosure has been shown and a share sent. The music friend's
    /// `music_share` refuses until it is, so an agent can never be the first to send a song out.
    static let disclosureKey = "baton.share.disclosureSeen"
    static let consentRequiredMessage = "Share a song once from Baton itself first (Share… in any song's menu), so the owner has seen where a shared song goes. After that, this tool can create links."

    private(set) var ledger: ShareLedger
    private(set) var isRefreshing = false
    /// Where the share in progress has got to, for the composer. `nil` when none is running.
    private(set) var stage: Stage?
    /// The last refresh's failure, for the Shared Links list. `nil` when it worked.
    private(set) var refreshError: String?
    /// Whole-book links staged on this device whose upload has not finished, newest first:
    /// Retry Upload continues each as the same link.
    private(set) var pendingBooks: [PendingBook] = []
    #if os(iOS)
    private(set) var pendingUploadCount = 0
    @ObservationIgnored private lazy var backgroundUploader: BackgroundShareUploadEngine = {
        let engine = BackgroundShareUploadEngine(
            directory: ledgerURL.deletingLastPathComponent().appendingPathComponent("PendingSongShares"),
            ledgerURL: ledgerURL)
        engine.onLedgerChanged = { [weak self] ledger in
            self?.ledger = ledger
            if !ledger.records.isEmpty { BatonStorage.defaults.set(true, forKey: SongSharing.disclosureKey) }
        }
        engine.onCreated = { [weak self] in
            guard let self else { return }
            _ = self.ledger.takeFailures()
            self.save()
        }
        engine.onProgress = { [weak self] fraction in self?.stage = .uploading(fraction) }
        engine.onPendingChanged = { [weak self] count in self?.pendingUploadCount = count }
        return engine
    }()

    func restoreBackgroundUploads() async { await backgroundUploader.restore() }

    func handleBackgroundUploadEvents(completion: @escaping () -> Void) {
        backgroundUploader.backgroundCompletionHandler = completion
        Task { await backgroundUploader.restore() }
    }
    #endif

    @ObservationIgnored private lazy var mixtapeStore = ShareUploadStore(
        directory: ledgerURL.deletingLastPathComponent().appendingPathComponent("PendingSongShares"), ledgerURL: ledgerURL)
    #if os(macOS)
    @ObservationIgnored private lazy var mixtapeUploader = MixtapeUploadCoordinator(store: mixtapeStore, onLedgerChanged: { [weak self] ledger in self?.ledger = ledger })
    #endif

    private let ledgerURL: URL
    private let base: URL

    init(ledgerURL: URL = SongSharing.defaultLedgerURL, base: URL = SongSharing.defaultBase) {
        self.ledgerURL = ledgerURL
        self.base = base
        ledger = ShareLedger.load(from: ledgerURL)
    }

    /// A development probe can use a throwaway local service. Ordinary launches always use
    /// the public service, even if a test variable accidentally remains in the environment.
    nonisolated static var defaultBase: URL {
        #if DEBUG
        probeBase(isProbe: BatonStorage.isProbe, environment: ProcessInfo.processInfo.environment)
        #else
        ShareLink.defaultBase
        #endif
    }

    nonisolated static func probeBase(isProbe: Bool, environment: [String: String]) -> URL {
        guard isProbe, let raw = environment["baton.share.baseURL"],
              let url = URL(string: raw), url.scheme == "http",
              let host = url.host, ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { return ShareLink.defaultBase }
        return url
    }

    /// `Application Support/Baton/SongShares.json`, beside the app's other stores, or in a
    /// probe instance's own directory (`BatonStorage`), so a probe never touches the owner's links.
    nonisolated static var defaultLedgerURL: URL {
        BatonStorage.supportDirectory().appendingPathComponent("SongShares.json")
    }

    /// Whether the first-share disclosure has been seen and a share sent, in the same defaults
    /// store `@AppStorage` reads in every scene (`BatonStorage.defaults`).
    static var hasSharedBefore: Bool { BatonStorage.defaults.bool(forKey: disclosureKey) }

    /// Both agent surfaces use the composer's options and one expiry contract.
    static func toolOptions(_ args: [String: Any], from: String) throws -> Options {
        // A recipient labels only the local handoff; validate before resolving or uploading.
        _ = try ShareToolHandoff.recipient(from: args)
        let days = (args["expires_days"] as? Int)
            ?? (args["expires_days"] as? String).flatMap(Int.init) ?? 7
        guard [1, 7, 30].contains(days) else {
            throw SongShareError.other("expires_days must be 1, 7 or 30.")
        }
        return Options(note: args["note"] as? String ?? "", from: from,
                       expiresInSeconds: days * 86400,
                       showsDetails: !((args["hide_details"] as? Bool) ?? false))
    }

    // MARK: - Options and progress

    struct Options: Equatable, Sendable {
        var note = ""
        var from = ""
        var expiresInSeconds = ShareLimits.standard.defaultExpirySeconds
        /// Off encrypts the title, artist, artwork and note too; link previews then say only
        /// that someone sent a song.
        var showsDetails = true
        /// Per-share opt-in from the composer. Past sharing is not preservation consent.
        var reviewPreservation = false
        /// A whole-book link: how many listeners it admits (nil: the service's default).
        var listeners: Int?
        /// A whole-book link: include each chapter's read-along text. Off unless chosen.
        var includesReadAlongText = false
    }

    enum Stage: Equatable, Sendable {
        case fetching
        case preparing
        /// A whole book, sealed chapter by chapter: done of total.
        case sealing(Int, Int)
        case uploading(Double)

        var label: String {
            switch self {
            case .fetching: "Getting the song from your music server…"
            case .preparing: "Encrypting…"
            case let .sealing(done, total): "Encrypting chapter \(min(total, done + 1)) of \(total)…"
            case .uploading: "Uploading…"
            }
        }
    }

    // MARK: - Sharing

    /// Shares one song and returns the record with its link. Every failure that never reached
    /// the service is queued and reported with the next create (`recentFailures`), which is how
    /// failures are counted without a telemetry call of their own.
    func share(_ song: NavidromeSong, options: Options, coverArtURL: URL?,
               onBackgroundUploadHandOff: (@MainActor () -> Void)? = nil) async throws -> ShareLedger.Record {
        defer { stage = nil }
        do {
            let record = try await perform(song, options: options, coverArtURL: coverArtURL,
                                           onBackgroundUploadHandOff: onBackgroundUploadHandOff)
            BatonStorage.defaults.set(true, forKey: Self.disclosureKey)
            return record
        } catch let error as SongShareError {
            if let reason = error.reportReason { note(reason) }
            throw error
        } catch let failure as ShareClient.Failure {
            if case .transport = failure { note("network") }
            throw SongShareError(failure)
        } catch {
            #if os(iOS)
            if let failure = error as? BackgroundShareUploadEngine.Failure {
                throw SongShareError.other(failure.errorDescription ?? "Sharing did not finish.")
            }
            #endif
            note("other")
            throw SongShareError.other(error.localizedDescription)
        }
    }

    private func perform(_ song: NavidromeSong, options: Options, coverArtURL: URL?,
                         onBackgroundUploadHandOff: (@MainActor () -> Void)?) async throws -> ShareLedger.Record {
        guard !song.isLocalOnly else { throw SongShareError.notOnServer }
        let duration = song.duration ?? 0
        guard duration > 0 else { throw SongShareError.unknownLength }
        guard duration <= ShareLimits.standard.maxDurationSeconds else { throw SongShareError.tooLong }
        let shareClient = try client()

        // Asked when the composer acts, never in the background: the kill switch and the limits.
        let config = try await shareClient.config()
        guard config.enabled else { throw SongShareError.paused }

        stage = .fetching
        let file = try await fetchAudio(song)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let audio = try Data(contentsOf: file)
        guard ShareCrypto.sealedLength(plaintextLength: audio.count) <= config.maxAudioBytes else {
            throw SongShareError.tooLarge
        }

        stage = .preparing
        let peaks = await WaveformExtractor.bars(forSongID: "share-\(song.id)", url: file, count: 200)
            .map { SharePresentation.peaks($0, count: 200) } ?? []
        let artwork = await artworkBytes(coverArtURL)
        let image = artwork.flatMap(Self.platformImage)
        let accent = image.map { Self.hex(ArtworkColorExtractor.palette(from: $0).uiAccent) }
        let from = options.from.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = ShareMetadata(
            title: song.title, artist: song.displayArtistName ?? "", album: song.album ?? "",
            durationSeconds: duration, from: from, note: options.note, accent: accent, peaks: peaks,
            recordingID: song.musicBrainzID.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() })
        let card = options.showsDetails
            ? Self.renderCard(title: song.title, artist: metadata.artist, from: from, artwork: image,
                              accent: accent.flatMap(Self.color) ?? .batonOrange)
            : nil

        let client = ShareClientInfo(platform: Self.platform, appVersion: Self.appVersion)
        let failures = ledger.pendingFailures
        let isPrivate = !options.showsDetails
        let expires = options.expiresInSeconds
        let cap = config.defaultPlayCap
        let reviewConsent = options.reviewPreservation ? CreateShareRequest.reviewConsentVersion : nil
        // Sealing a 10 MB song is real work; keep it off the main actor.
        let prepared = try await Task.detached(priority: .userInitiated) {
            try PreparedShare.make(audio: audio, metadata: metadata, isPrivate: isPrivate,
                                   expiresInSeconds: expires, playCap: cap, client: client,
                                   artwork: artwork, card: card, recentFailures: failures,
                                   reviewPreservationConsent: reviewConsent)
        }.value

        #if os(iOS)
        // Only ciphertext survives suspension. The preparation MP3 is no longer
        // needed once sealing is complete, even while the background task runs.
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        #endif
        return try await upload(prepared, client: shareClient, config: config, songID: song.id, title: song.title,
                                artist: metadata.artist, onBackgroundUploadHandOff: onBackgroundUploadHandOff)
    }

    /// Sends a sealed song and records its link: in the background session on the iPhone, in
    /// the foreground on the Mac. Songs and single book chapters both end here.
    private func upload(_ prepared: PreparedShare, client shareClient: ShareClient, config: ShareConfig,
                        songID: String, title: String, artist: String,
                        onBackgroundUploadHandOff: (@MainActor () -> Void)?) async throws -> ShareLedger.Record {
        stage = .uploading(0)
        #if os(iOS)
        return try await backgroundUploader.enqueue(prepared, client: shareClient, songID: songID,
                                                     title: title, artist: artist, attestationPolicy: config.appAttest,
                                                     onHandOff: onBackgroundUploadHandOff)
        #else
        let (link, summary) = try await shareClient.share(prepared) { fraction in
            Task { @MainActor in self.stage = .uploading(fraction) }
        }
        _ = ledger.takeFailures()
        let record = ShareLedger.Record(
            id: summary.id, link: link.absoluteString, songID: songID, title: title,
            artist: artist, isPrivate: prepared.request.preview == nil, createdAt: Date(),
            expiresAt: ShareDate.date(summary.expiresAt) ?? Date() + TimeInterval(prepared.request.expiresInSeconds), summary: summary)
        ledger.add(record)
        save()
        return record
        #endif
    }

    func shareMixtape(_ songs: [NavidromeSong], title: String, options: Options,
                      onBackgroundUploadHandOff: (@MainActor () -> Void)? = nil,
                      onStaged: (@MainActor (UUID) -> Void)? = nil) async throws -> ShareLedger.Record {
        defer { stage = nil }
        guard (2...12).contains(songs.count), Set(songs.map(\.id)).count == songs.count,
              songs.allSatisfy({ !$0.isLocalOnly && ($0.duration ?? 0) > 0 }) else {
            throw SongShareError.other("Choose 2 to 12 server tracks, up to 20 minutes in total.")
        }
        var remainingSeconds = ShareLimits.standard.maxDurationSeconds
        for song in songs {
            guard let seconds = song.duration, seconds <= remainingSeconds else {
                throw SongShareError.other("Choose 2 to 12 server tracks, up to 20 minutes in total.")
            }
            remainingSeconds -= seconds
        }
        let client = try client(), config = try await client.mixtapeConfiguration()
        guard config.enabled, config.mixtapes == 1 else { throw SongShareError.other("Mixtape sharing is not available on this service.") }
        var inputs = [PreparedMixtape.Input](), bytes = 0
        for song in songs {
            stage = .fetching
            let file = try await fetchAudio(song)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let data = try Data(contentsOf: file)
            let sealedBytes = ShareCrypto.sealedLength(plaintextLength: data.count)
            guard sealedBytes <= config.maxAudioBytes - bytes else { throw SongShareError.tooLarge }
            bytes += sealedBytes
            let peaks = await WaveformExtractor.bars(forSongID: "share-mixtape-\(song.id)", url: file, count: 200)
                .map { SharePresentation.peaks($0, count: 200) } ?? []
            inputs.append(.init(audio: data, metadata: .init(title: song.title, artist: song.displayArtistName ?? "",
                album: song.album ?? "", durationSeconds: song.duration!, from: options.from, note: options.note, peaks: peaks,
                recordingID: song.musicBrainzID.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() })))
        }
        stage = .preparing
        let preview: MixtapePreview? = options.showsDetails ? .init(title: title, from: options.from, note: options.note) : nil
        let consent = options.reviewPreservation ? CreateShareRequest.reviewConsentVersion : nil
        let frozenInputs = inputs
        let clientInfo = ShareClientInfo(platform: Self.platform, appVersion: Self.appVersion)
        let prepared = try await Task.detached(priority: .userInitiated) {
            try PreparedMixtape.make(tracks: frozenInputs, title: title, preview: preview, expiresInSeconds: options.expiresInSeconds,
                playCap: config.defaultPlayCap, client: clientInfo, reviewPreservationConsent: consent)
        }.value
        inputs.removeAll() // Only ciphertext remains in the durable upload ticket.
        let record = try await upload(prepared, client: client, config: config, songIDs: songs.map(\.id),
                                      onBackgroundUploadHandOff: onBackgroundUploadHandOff, onStaged: onStaged)
        BatonStorage.defaults.set(true, forKey: Self.disclosureKey)
        return record
    }

    /// Stages a sealed mixtape as a protected upload ticket and sends it: the background session
    /// on the iPhone, the foreground coordinator on the Mac. Mixtapes and book chapters both end here.
    private func upload(_ prepared: PreparedMixtape, client: ShareClient, config: ShareConfig, songIDs: [String],
                        onBackgroundUploadHandOff: (@MainActor () -> Void)?,
                        onStaged: (@MainActor (UUID) -> Void)?) async throws -> ShareLedger.Record {
        stage = .uploading(0)
        #if os(iOS)
        return try await backgroundUploader.enqueue(prepared, client: client, songIDs: songIDs,
            attestationPolicy: config.appAttest, onHandOff: onBackgroundUploadHandOff, onStaged: onStaged)
        #else
        let job = try mixtapeStore.stage(prepared, base: base, songIDs: songIDs)
        onStaged?(job.id)
        let record = try await mixtapeUploader.resume(job.id, client: client) { fraction in
            Task { @MainActor in self.stage = .uploading(fraction) }
        }
        ledger = ShareLedger.load(from: ledgerURL)
        return record
        #endif
    }

    /// Shares chapters of a book (`specs/book-sharing.md`, Phase 1, TBX-1000000132): one chapter
    /// as a song link, two to twelve as a mixtape, within the limits the service advertises. The
    /// audio is the chapters' own files on this device, so nothing is fetched, and no text
    /// leaves it: titles travel only as the link's metadata, encrypted when previews are off.
    func shareBook(_ book: BookShareDraft, chapters selected: [BookShareDraft.Chapter], options: Options,
                   onBackgroundUploadHandOff: (@MainActor () -> Void)? = nil,
                   onStaged: (@MainActor (UUID) -> Void)? = nil) async throws -> ShareLedger.Record {
        defer { stage = nil }
        do {
            let record = try await performBook(book, chapters: selected, options: options,
                                               onBackgroundUploadHandOff: onBackgroundUploadHandOff, onStaged: onStaged)
            BatonStorage.defaults.set(true, forKey: Self.disclosureKey)
            return record
        } catch let error as SongShareError {
            if let reason = error.reportReason { note(reason) }
            throw error
        } catch let failure as ShareClient.Failure {
            if case .transport = failure { note("network") }
            throw SongShareError(failure)
        } catch {
            #if os(iOS)
            if let failure = error as? BackgroundShareUploadEngine.Failure {
                throw SongShareError.other(failure.errorDescription ?? "Sharing did not finish.")
            }
            #endif
            note("other")
            throw SongShareError.other(error.localizedDescription)
        }
    }

    private func performBook(_ book: BookShareDraft, chapters selected: [BookShareDraft.Chapter], options: Options,
                             onBackgroundUploadHandOff: (@MainActor () -> Void)?,
                             onStaged: (@MainActor (UUID) -> Void)?) async throws -> ShareLedger.Record {
        let shareClient = try client()
        // Asked when the composer acts, never in the background: the kill switch and the limits.
        let config = try await shareClient.mixtapeConfiguration()
        guard config.enabled else { throw SongShareError.paused }

        stage = .preparing
        let planned = try selected.map { chapter in
            guard let bytes = (try? FileManager.default.attributesOfItem(atPath: chapter.url.path))?[.size] as? Int else {
                throw SongShareError.other("A chapter's audio is no longer on this device. Get it back, then share again.")
            }
            return ShareBookPlan.Chapter(index: chapter.index, title: chapter.title,
                                         durationSeconds: chapter.durationSeconds, bytes: bytes)
        }
        let container: ShareBookPlan.Container
        switch ShareBookPlan.check(planned, limits: .init(config: config)) {
        case let .success(kind): container = kind
        case let .failure(refusal): throw SongShareError.other(refusal.message)
        }

        let credits = ShareBookPlan.credits(book: book.title, author: book.author)
        let from = options.from.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientInfo = ShareClientInfo(platform: Self.platform, appVersion: Self.appVersion)
        let reviewConsent = options.reviewPreservation ? CreateShareRequest.reviewConsentVersion : nil
        let expires = options.expiresInSeconds
        let cap = config.defaultPlayCap
        func peaks(_ chapter: BookShareDraft.Chapter) async -> [Int] {
            await WaveformExtractor.bars(forSongID: "share-book-\(chapter.url.lastPathComponent)", url: chapter.url, count: 200)
                .map { SharePresentation.peaks($0, count: 200) } ?? []
        }

        switch container {
        case .song:
            let chapter = selected[0]
            let title = ShareBookPlan.chapterTitle(planned[0], book: book.title, chapterCount: book.chapterCount)
            let audio = try Data(contentsOf: chapter.url)
            let artwork = book.coverURL.flatMap { Self.coverBytes(at: $0) }
            let image = artwork.flatMap(Self.platformImage)
            let accent = image.map { Self.hex(ArtworkColorExtractor.palette(from: $0).uiAccent) }
            let shape = await peaks(chapter)
            let metadata = ShareMetadata(title: title, artist: credits.artist, album: credits.album,
                                         durationSeconds: planned[0].wireSeconds, from: from, note: options.note,
                                         accent: accent, peaks: shape)
            let card = options.showsDetails
                ? Self.renderCard(title: title, artist: credits.artist, from: from, artwork: image,
                                  accent: accent.flatMap(Self.color) ?? .batonOrange)
                : nil
            let failures = ledger.pendingFailures
            let isPrivate = !options.showsDetails
            let prepared = try await Task.detached(priority: .userInitiated) {
                try PreparedShare.make(audio: audio, metadata: metadata, isPrivate: isPrivate,
                                       expiresInSeconds: expires, playCap: cap, client: clientInfo,
                                       artwork: artwork, card: card, recentFailures: failures,
                                       reviewPreservationConsent: reviewConsent)
            }.value
            return try await upload(prepared, client: shareClient, config: config, songID: chapter.songID, title: title,
                                    artist: credits.artist, onBackgroundUploadHandOff: onBackgroundUploadHandOff)
        case .mixtape:
            var inputs = [PreparedMixtape.Input]()
            for (chapter, plan) in zip(selected, planned) {
                stage = .preparing
                let audio = try Data(contentsOf: chapter.url)
                let shape = await peaks(chapter)
                inputs.append(.init(audio: audio, metadata: .init(
                    title: ShareBookPlan.chapterTitle(plan, book: book.title, chapterCount: book.chapterCount),
                    artist: credits.artist, album: credits.album, durationSeconds: plan.wireSeconds,
                    from: from, note: options.note, peaks: shape)))
            }
            let title = ShareBookPlan.title(book: book.title, selected: planned, chapterCount: book.chapterCount)
            let preview: MixtapePreview? = options.showsDetails ? .init(title: title, from: from, note: options.note) : nil
            let frozenInputs = inputs
            let prepared = try await Task.detached(priority: .userInitiated) {
                try PreparedMixtape.make(tracks: frozenInputs, title: title, preview: preview, expiresInSeconds: expires,
                                         playCap: cap, client: clientInfo, reviewPreservationConsent: reviewConsent)
            }.value
            inputs.removeAll() // Only ciphertext remains in the durable upload ticket.
            return try await upload(prepared, client: shareClient, config: config, songIDs: selected.map(\.songID),
                                    onBackgroundUploadHandOff: onBackgroundUploadHandOff, onStaged: onStaged)
        }
    }

    /// A book's cover as the song page's artwork: JPEG or PNG within the art limit, as it is.
    /// Anything else is left off rather than re-encoded; the page has a placeholder.
    nonisolated static func coverBytes(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count <= ShareLimits.standard.maxArtBytes else { return nil }
        let head = [UInt8](data.prefix(8))
        let isJPEG = head.starts(with: [0xFF, 0xD8, 0xFF])
        let isPNG = head.starts(with: [0x89, 0x50, 0x4E, 0x47])
        return isJPEG || isPNG ? data : nil
    }

    func resumeMixtapeUpload(_ id: UUID, onBackgroundUploadHandOff: (@MainActor () -> Void)? = nil) async throws -> ShareLedger.Record {
        defer { stage = nil }
        stage = .uploading(0)
        #if os(iOS)
        let record = try await backgroundUploader.resumeMixtape(id, onHandOff: onBackgroundUploadHandOff)
        #else
        let record = try await mixtapeUploader.resume(id, client: client())
        ledger = ShareLedger.load(from: ledgerURL)
        #endif
        BatonStorage.defaults.set(true, forKey: Self.disclosureKey)
        return record
    }

    /// Explicit foreground retry on Mac; iPhone delegates the same protected tickets
    /// to its stable background session at launch/foreground.
    func resumeMixtapeUploads() async throws {
        #if os(iOS)
        _ = try mixtapeStore.load() // Preserve and report unreadable/invalid protected tickets.
        await backgroundUploader.restore()
        #else
        let client = try client(), loaded = try mixtapeStore.load()
        var interrupted = false
        for job in loaded.jobs where job.isMixtape {
            do { _ = try await mixtapeUploader.resume(job.id, client: client) }
            catch { interrupted = true }
        }
        ledger = ShareLedger.load(from: ledgerURL)
        if interrupted { throw SongShareError.other("Some protected mixtape uploads could not resume. Their drafts are kept; try again when sharing is available.") }
        #endif
    }

    // MARK: - Whole-book links (`/b/`, Phase 2)

    /// A whole-book link staged on this device that has not finished uploading.
    struct PendingBook: Identifiable, Equatable {
        let directory: URL
        let title: String
        var id: URL { directory }
    }

    /// `Application Support/Baton/PendingBookShares/<uuid>/`: one folder per whole-book link in
    /// progress, holding its sealed chapters, key and exact request (`PreparedBookShare`). Kept until
    /// the link is recorded or the sharer discards it, so a retry is always the same link.
    private var bookStagingRoot: URL {
        ledgerURL.deletingLastPathComponent().appendingPathComponent("PendingBookShares", isDirectory: true)
    }

    #if os(iOS)
    @ObservationIgnored private lazy var bookAttest = SongShareAppAttest(
        directory: ledgerURL.deletingLastPathComponent().appendingPathComponent("SongShareAttestKeys"))
    #endif

    /// Shares a whole book as one `/b/` link (`specs/book-sharing.md`, Phase 2): every chapter on
    /// this device, sealed to disk one at a time, then uploaded one at a time. Offered only when
    /// the service advertises `books: 1`. The book's text goes only when the sharer turned on
    /// "Include the text for read-along", sealed under its own key. `onStaged` hands the composer
    /// the staged folder once it exists, so a failed upload retries the same link.
    func shareWholeBook(_ book: BookShareDraft, options: Options,
                        onStaged: (@MainActor (URL) -> Void)? = nil) async throws -> ShareLedger.Record {
        defer { stage = nil }
        return try await reportingBookFailures {
            try await self.performWholeBook(book, options: options, onStaged: onStaged)
        }
    }

    /// Continues a staged whole-book link: the same key, request and link.
    func resumeBookUpload(_ directory: URL) async throws -> ShareLedger.Record {
        defer { stage = nil }
        return try await reportingBookFailures { try await self.uploadBook(directory) }
    }

    /// Retries every staged whole-book link, from Shared Links.
    func resumeBookUploads() async throws {
        loadPendingBooks()
        var interrupted = false
        for pending in pendingBooks {
            do { _ = try await resumeBookUpload(pending.directory) } catch { interrupted = true }
        }
        loadPendingBooks()
        if interrupted {
            throw SongShareError.other("Some book links could not finish uploading. Their encrypted copies are kept on this device; try again when sharing is available.")
        }
    }

    /// Deletes a staged whole-book link's encrypted copy from this device. A link the service
    /// already made but never finished ends by itself, unplayed.
    func discardBookUpload(_ directory: URL) {
        guard directory.deletingLastPathComponent().standardizedFileURL == bookStagingRoot.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
        loadPendingBooks()
    }

    /// Whether this device has any whole-book link, finished or not.
    var hasBookLinks: Bool { !pendingBooks.isEmpty || ledger.records.contains { $0.containerKind == .book } }

    /// The folder a whole book is being sealed into right now: never an orphan, whatever its age.
    @ObservationIgnored private var sealingDirectory: URL?

    /// Staging folders a seal left without a ticket (the app was quit or killed midway): up to a
    /// whole book of ciphertext no retry can use, because the key and request were never written.
    /// Only UUID-named folders directly in `root`, with no `book.json`, not `active`, and untouched
    /// for `age` (the folder and everything in it). Anything with a ticket is a link that can still
    /// be finished, and is kept.
    nonisolated static func orphanedBookStaging(in root: URL, active: URL?, now: Date = Date(),
                                                olderThan age: TimeInterval = 3600) -> [URL] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return [] }
        let activePath = active?.standardizedFileURL.path
        return folders.filter { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil, folder.standardizedFileURL.path != activePath,
                  let values = try? folder.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                  values.isSymbolicLink != true,
                  !manager.fileExists(atPath: folder.appendingPathComponent(PreparedBookShare.ticketName).path) else { return false }
            var latest = values.contentModificationDate ?? .distantFuture
            for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                latest = max(latest, (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture)
            }
            return now.timeIntervalSince(latest) > age
        }
    }

    func loadPendingBooks() {
        for orphan in Self.orphanedBookStaging(in: bookStagingRoot, active: sealingDirectory) {
            try? FileManager.default.removeItem(at: orphan)
        }
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: bookStagingRoot, includingPropertiesForKeys: [.creationDateKey])) ?? []
        pendingBooks = folders.compactMap { folder -> (PendingBook, Date)? in
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  manager.fileExists(atPath: folder.appendingPathComponent(PreparedBookShare.ticketName).path) else { return nil }
            let title = (try? PreparedBookShare.load(from: folder))?.manifest.title ?? "A book"
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return (PendingBook(directory: folder, title: title), created)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private func reportingBookFailures(_ work: () async throws -> ShareLedger.Record) async throws -> ShareLedger.Record {
        do {
            let record = try await work()
            BatonStorage.defaults.set(true, forKey: Self.disclosureKey)
            return record
        } catch let error as SongShareError {
            if let reason = error.reportReason { note(reason) }
            throw error
        } catch let failure as PreparedBookShare.Failure {
            let error = SongShareError.book(failure)
            if let reason = error.reportReason { note(reason) }
            throw error
        } catch let failure as ShareClient.Failure {
            if case .transport = failure { note("network") }
            throw SongShareError(failure)
        } catch {
            note("other")
            throw SongShareError.other(error.localizedDescription)
        }
    }

    private func performWholeBook(_ book: BookShareDraft, options: Options,
                                  onStaged: (@MainActor (URL) -> Void)?) async throws -> ShareLedger.Record {
        let shareClient = try client()
        // Asked when the composer acts: the kill switch, the advertisement and the caps.
        let config = try await shareClient.bookConfiguration()
        guard config.enabled else { throw SongShareError.paused }
        guard config.books == 1, let limits = config.book else {
            throw SongShareError.other("Book links aren't available on the share service yet.")
        }
        if case let .failure(refusal) = book.wholeBookCheck(limits) { throw SongShareError.other(refusal.message) }
        guard config.expiryChoices.contains(options.expiresInSeconds) else {
            throw SongShareError.other("Choose how long the link lasts.")
        }

        stage = .preparing
        var inputs = [PreparedBookShare.Chapter]()
        for chapter in book.chapters {
            let text = options.includesReadAlongText ? BookShareDraft.readAlongText(await book.timing?(chapter.index)) : nil
            inputs.append(.init(audio: chapter.url, title: ShareBookPlan.wholeBookChapterTitle(chapter.plan),
                                durationSeconds: chapter.plan.wireSeconds, text: text))
        }
        let title = ShareBookPlan.bookTitle(book.title)
        let author = ShareBookPlan.credits(book: book.title, author: book.author).artist
        let from = String(options.from.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ShareLimits.maxFromLength))
        let note = options.note
        let preview = options.showsDetails ? BookPreview(title: title, author: author, from: from, note: note) : nil
        let listeners = min(max(1, options.listeners ?? limits.defaultListeners), limits.maxListeners)
        let consent = options.reviewPreservation ? CreateShareRequest.reviewConsentVersion : nil
        let clientInfo = ShareClientInfo(platform: Self.platform, appVersion: Self.appVersion)
        let expires = options.expiresInSeconds
        let directory = bookStagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let frozen = inputs
        stage = .sealing(0, frozen.count)
        sealingDirectory = directory
        defer { sealingDirectory = nil }
        // Sealing a whole book is minutes of work; keep it off the main actor.
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try PreparedBookShare.make(chapters: frozen, title: title, author: author, from: from, note: note, preview: preview,
                                           expiresInSeconds: expires, listenerCap: listeners, client: clientInfo,
                                           reviewPreservationConsent: consent, limits: limits, directory: directory) { done, total in
                    Task { @MainActor in self.stage = .sealing(done, total) }
                }
            }.value
        } catch {
            // Nothing was staged (make removes what it wrote); the fresh folder is this attempt's own.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        loadPendingBooks()
        onStaged?(directory)
        return try await uploadBook(directory, client: shareClient, config: config)
    }

    /// Uploads a staged book and records its link: create (or the same create again), every blob
    /// not yet acknowledged, finalize. On the iPhone this runs in the foreground, with the few
    /// minutes of background time the system grants if the app is left mid-upload.
    private func uploadBook(_ directory: URL, client givenClient: ShareClient? = nil,
                            config givenConfig: ShareConfig? = nil) async throws -> ShareLedger.Record {
        let shareClient = try givenClient ?? client()
        let prepared = try PreparedBookShare.load(from: directory)
        stage = .uploading(0)
        #if os(iOS)
        let background = UIApplication.shared.beginBackgroundTask(withName: "Upload book share", expirationHandler: nil)
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        #endif
        // App Attest, where the service asks for it (the iPhone): a proof for the create, and a fresh
        // one if a retry comes after the first proof's challenge has lapsed (`ShareClient.shareBook`).
        #if os(iOS)
        var attest: ShareClient.BookAttestation?
        if prepared.created == nil {
            var config = givenConfig
            if config == nil { config = try await shareClient.bookConfiguration() }
            if let policy = config?.appAttest {
                let attester = bookAttest
                attest = { @MainActor body, proofRequestID in
                    try await attester.proof(client: shareClient, policy: policy, body: body,
                                             requestID: proofRequestID, path: "/v1/share/books")
                }
            }
        }
        #else
        let attest: ShareClient.BookAttestation? = nil
        #endif
        let result: (link: URL, summary: BookSummary)
        do {
            result = try await shareClient.shareBook(prepared, attest: attest) { fraction in
                Task { @MainActor in self.stage = .uploading(fraction) }
            }
        } catch let ShareClient.Failure.service(_, code, _) where code == "expired" {
            // The service ended this link before it was finished: nothing can resume it.
            try? prepared.remove()
            loadPendingBooks()
            throw SongShareError.other("This book's upload took too long and its link has ended. Share the book again to make a new link.")
        }
        _ = ledger.takeFailures()
        let manifest = prepared.manifest
        let record = ShareLedger.Record(
            id: result.summary.share.id, link: result.link.absoluteString, songID: "", title: manifest.title,
            artist: manifest.author, isPrivate: prepared.request.preview == nil, createdAt: Date(),
            expiresAt: ShareDate.date(result.summary.share.expiresAt) ?? Date() + TimeInterval(prepared.request.expiresInSeconds),
            summary: result.summary.share, kind: .book, bookSummary: result.summary)
        ledger.add(record)
        save()
        try? prepared.remove()
        loadPendingBooks()
        return record
    }

    /// The song as MP3 at 320 kbps, from the owner's own server with their credentials and any
    /// reverse-proxy headers, exactly as playback asks for it. MP3 because every browser plays
    /// it and Navidrome transcodes to it out of the box (plan §1).
    private func fetchAudio(_ song: NavidromeSong) async throws -> URL {
        guard let credentials = NavidromeConfig.credentials() else { throw SongShareError.notConnected }
        let url: URL
        do {
            url = try NavidromeConfig.makeClient().streamURL(songID: song.id, maxBitRate: 320, format: "mp3")
        } catch {
            throw SongShareError.notConnected
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        for (name, value) in credentials.customHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let (downloaded, response): (URL, URLResponse)
        do {
            (downloaded, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw SongShareError.fetchFailed
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: downloaded)
            throw SongShareError.transcodeFailed
        }
        // Into a folder of its own with an .mp3 name: the waveform reader opens it with
        // AVFoundation, which goes by the extension.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("baton-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("song.mp3")
        try FileManager.default.moveItem(at: downloaded, to: file)
        return file
    }

    /// Cover bytes the service will take as they are: JPEG or PNG within the art limit. A WebP
    /// cover, or a huge one, is left off rather than re-encoded; the page has a placeholder.
    private func artworkBytes(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        let (data, _) = await ArtworkCache.fetchBytes(for: url)
        guard let data, data.count <= ShareLimits.standard.maxArtBytes else { return nil }
        let head = [UInt8](data.prefix(8))
        let isJPEG = head.starts(with: [0xFF, 0xD8, 0xFF])
        let isPNG = head.starts(with: [0x89, 0x50, 0x4E, 0x47])
        return isJPEG || isPNG ? data : nil
    }

    // MARK: - Shared Links

    func refresh() async {
        guard !ledger.records.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            ledger.merge(try await client().list())
            if ledger.records.contains(where: { $0.containerKind == .mixtape }) { ledger.mergeMixtapes(try await client().listMixtapes()) }
            if ledger.records.contains(where: { $0.containerKind == .book }) { ledger.mergeBooks(try await client().listBooks()) }
            refreshError = nil
            save()
        } catch {
            refreshError = SongShareError(error).errorDescription
        }
    }

    func revoke(_ id: String, kind: ShareInvitation.Kind = .song) async throws {
        do {
            switch kind {
            case .mixtape: try await client().revokeMixtape(id)
            case .book: try await client().revokeBook(id)
            case .song: try await client().revoke(id)
            }
        } catch {
            throw SongShareError(error)
        }
        await refresh()
    }

    func extend(_ id: String, bySeconds seconds: Int = 604_800, kind: ShareInvitation.Kind = .song) async throws {
        do {
            switch kind {
            case .mixtape: ledger.updateMixtape(try await client().extendMixtape(id, bySeconds: seconds))
            case .book: ledger.updateBook(try await client().extendBook(id, bySeconds: seconds))
            case .song: ledger.update(try await client().extend(id, bySeconds: seconds))
            }
            save()
        } catch {
            throw SongShareError(error)
        }
    }

    /// Removes an ended share from this device's list. The server keeps only counters by then.
    func forget(_ id: String, kind: ShareInvitation.Kind = .song) {
        ledger.remove(id: id, kind: kind)
        save()
    }

    // MARK: - Pieces

    /// Registration never creates an installation secret as a side effect.
    func existingClientForReactionPush() -> ShareClient? {
        guard let secret = NavidromeKeychain.secret(account: Self.secretAccount), !secret.isEmpty else { return nil }
        return ShareClient(base: base, secret: secret)
    }

    /// The client, creating this install's secret on first use.
    func client() throws -> ShareClient {
        if let secret = NavidromeKeychain.secret(account: Self.secretAccount), !secret.isEmpty {
            return ShareClient(base: base, secret: secret)
        }
        let secret = ShareClient.newSecret()
        guard NavidromeKeychain.setSecret(secret, account: Self.secretAccount) else {
            throw SongShareError.keychain
        }
        return ShareClient(base: base, secret: secret)
    }

    private func note(_ reason: String) {
        ledger.noteFailure(reason)
        save()
    }

    private func save() {
        try? ShareUploadStore.saveLedger(ledger, to: ledgerURL)
        // Book links live beside the ledger, where released apps never read them.
        try? ledger.saveBooks(beside: ledgerURL)
    }

    static var platform: String {
        #if os(macOS)
            "macos"
        #else
            "ios"
        #endif
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static func platformImage(_ data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }

    static func image(_ image: PlatformImage) -> Image {
        #if canImport(AppKit)
            Image(nsImage: image)
        #else
            Image(uiImage: image)
        #endif
    }

    /// `#RRGGBB` for a colour, in sRGB.
    static func hex(_ color: Color) -> String {
        let resolved = color.resolve(in: EnvironmentValues())
        func byte(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(resolved.red), byte(resolved.green), byte(resolved.blue))
    }

    static func color(_ hex: String) -> Color? {
        guard ShareText.isHexColor(hex), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// The 1200×630 card used as the link preview's image (plan §2), as JPEG.
    static func renderCard(title: String, artist: String, from: String, artwork: PlatformImage?,
                           accent: Color) -> Data? {
        let renderer = ImageRenderer(content: ShareCardView(
            title: title, artist: artist, from: from, artwork: artwork.map(Self.image), accent: accent))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 1200, height: 630)
        guard let cgImage = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let jpeg = data as Data
        return jpeg.count <= ShareLimits.standard.maxCardBytes ? jpeg : nil
    }
}

/// The link preview's picture: artwork on the song's colour, with who sent it.
struct ShareCardView: View {
    let title: String
    let artist: String
    let from: String
    let artwork: Image?
    let accent: Color

    var body: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.95), Color(red: 0.09, green: 0.075, blue: 0.063)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 56) {
                Group {
                    if let artwork {
                        artwork.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.black.opacity(0.25)
                            .overlay(Image(systemName: "music.note").font(.system(size: 160)).foregroundStyle(.white.opacity(0.7)))
                    }
                }
                .frame(width: 430, height: 430)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 16)

                VStack(alignment: .leading, spacing: 14) {
                    Text(from.isEmpty ? "A song for you" : "\(from) sent you a song")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                    Text(title)
                        .font(.system(size: 66, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                    if !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("Tap to listen · Baton")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.batonOrange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(80)
        }
        .frame(width: 1200, height: 630)
    }
}

/// Why a share did not happen, in words for the person, and the reason the next create reports.
enum SongShareError: LocalizedError, Equatable {
    case notConnected, notOnServer, unknownLength, tooLong, tooLarge, fetchFailed, transcodeFailed
    case paused, busy, rateLimited, keychain
    case service(String)
    case other(String)
    /// A whole book that could not be prepared as one link.
    case book(PreparedBookShare.Failure)

    init(_ failure: ShareClient.Failure) {
        switch failure {
        case let .service(_, code, message):
            switch code {
            case "share_disabled": self = .paused
            case "busy": self = .busy
            case "rate_limited": self = .rateLimited
            case "too_large": self = .tooLarge
            default: self = .service(message)
            }
        case .transport:
            self = .other("Couldn't reach Baton's share service. Check your connection and try again.")
        case let .unexpected(status):
            self = .other("The share service answered unexpectedly (\(status)).")
        }
    }

    init(_ error: any Error) {
        if let error = error as? SongShareError { self = error }
        else if let failure = error as? ShareClient.Failure { self.init(failure) }
        else { self = .other(error.localizedDescription) }
    }

    var errorDescription: String? {
        switch self {
        case .notConnected: "Connect to your music server first."
        case .notOnServer: "Only songs on your music server can be shared."
        case .unknownLength: "Your music server didn't say how long this song is, so it can't be shared."
        case .tooLong: "Songs longer than 20 minutes can't be shared."
        case .tooLarge: "This song is too large to share."
        case .fetchFailed: "Couldn't get the song from your music server."
        case .transcodeFailed: "Your music server couldn't convert this song to MP3."
        case .paused: "Sharing is paused for now. Try again later."
        case .busy: "Sharing is busy right now. Try again later."
        case .rateLimited: "That's a lot of sharing for one day. Try again tomorrow."
        case .keychain: "Couldn't save this device's sharing key to the Keychain."
        case let .service(message), let .other(message): message
        case let .book(failure): Self.message(failure)
        }
    }

    private static func message(_ failure: PreparedBookShare.Failure) -> String {
        switch failure {
        case .noChapters: "No chapter of this book is on this device yet."
        case let .tooManyChapters(max): "A book link holds up to \(max) chapters."
        case let .unreadable(chapter): "Chapter \(chapter)'s audio couldn't be read on this device. Get it back, then share again."
        case let .chapterTooLong(chapter): "Chapter \(chapter) is too long for a book link."
        case .tooLong: "This book is too long for one link."
        case let .chapterTooLarge(chapter): "Chapter \(chapter) is too large for a book link."
        case let .textTooLarge(chapter): "Chapter \(chapter)'s text is too long to include. Turn off Include the text for read-along to share the audio alone."
        case .bookTooLarge: "This book is too large for one link."
        case .manifestTooLarge, .requestTooLarge: "This book has too many chapter names to fit one link."
        case .directoryInUse, .damaged: "The encrypted copy of this book on this device is damaged. Share the book again to make a new link."
        }
    }

    /// The `recentFailures` reason for a failure that never reached the service, or `nil` when
    /// it did (the service counted it already) or it was never a real attempt.
    var reportReason: String? {
        switch self {
        case .fetchFailed: "network"
        case .transcodeFailed: "transcode"
        case .tooLarge, .tooLong: "too_large"
        case .keychain, .other: "other"
        case let .book(failure):
            switch failure {
            case .tooManyChapters, .chapterTooLong, .tooLong, .chapterTooLarge, .textTooLarge, .bookTooLarge,
                 .manifestTooLarge, .requestTooLarge: "too_large"
            default: "other"
            }
        case .notConnected, .notOnServer, .unknownLength, .paused, .busy, .rateLimited, .service: nil
        }
    }
}
