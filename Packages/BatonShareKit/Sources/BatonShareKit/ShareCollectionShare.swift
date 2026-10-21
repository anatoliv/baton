import Foundation

/// An album or playlist sealed to disk one track at a time (specs/collection-sharing.md, "Sealing",
/// TBX-1000000485).
///
/// A book's chapters are files already on the device, so `make(chapters:)` reads them as they are.
/// A collection's tracks are not: each is fetched from the music server (or converted on the
/// device) as AAC, and holding a whole album of plaintext at once would mean hundreds of
/// megabytes on disk. So `makeCollection` asks a producer for one track at a time, into a file
/// inside the app-private staging directory, seals it, hashes it and deletes the plaintext before
/// asking for the next: at most one track's plaintext exists at any moment, and a seal the app was
/// killed in leaves only ciphertext and that one file in a ticketless folder the sweeper removes.
///
/// Every cap is checked before the first track is fetched, from the library's durations and the
/// chosen bit rates (`ShareCollectionLimits.estimatedBytes`), and again exactly as each track lands
/// from its real size and measured duration. The result is an ordinary `PreparedBookShare`: the
/// same ticket, retry, App Attest and upload path as a book.
extension PreparedBookShare {
    /// One track to be produced, in the collection's order.
    public struct PlannedTrack: Sendable, Equatable {
        public var title: String
        public var artist: String?
        public var album: String?
        public var trackNumber: Int?
        /// The library's length, for the caps checked up front.
        public var estimatedSeconds: Int
        /// The bit rate the producer encodes at, in bits a second.
        public var bitRate: Int
        public init(title: String, artist: String? = nil, album: String? = nil, trackNumber: Int? = nil,
                    estimatedSeconds: Int, bitRate: Int = ShareCollectionLimits.musicBitRate) {
            self.title = title; self.artist = artist; self.album = album; self.trackNumber = trackNumber
            self.estimatedSeconds = estimatedSeconds; self.bitRate = bitRate
        }
    }

    /// Makes one track's plaintext (an M4A) at `destination`, which does not exist yet, and returns
    /// its measured duration in whole seconds. `index` is the track's 0-based position.
    public typealias TrackProducer = @Sendable (_ index: Int, _ destination: URL) async throws -> Int

    /// The plaintext file a track is produced into, inside the staging directory.
    public static func plaintextName(_ index: Int) -> String { "track-\(index).plain.m4a" }

    public static func makeCollection(kind: ShareCollectionKind, tracks: [PlannedTrack], title: String, artist: String = "",
                                      from: String = "", note: String = "", cover: ShareBookManifest.Cover? = nil,
                                      preview: BookPreview?, expiresInSeconds: Int, listenerCap: Int, client: ShareClientInfo,
                                      reviewPreservationConsent: String? = nil, limits bookLimits: ShareBookLimits,
                                      directory: URL, key: Data = ShareCrypto.newKey(), requestID: String = UUID().uuidString,
                                      produce: TrackProducer,
                                      progress: (@Sendable (_ sealed: Int, _ total: Int) -> Void)? = nil) async throws -> Self {
        let limits = bookLimits.applied()
        guard key.count == ShareCrypto.keyLength else { throw ShareCrypto.Failure.badKey }
        guard !tracks.isEmpty else { throw Failure.noChapters }
        guard tracks.count <= limits.maxBookChapters else { throw Failure.tooManyChapters(max: limits.maxBookChapters) }

        // Every cap first, from the library's lengths and the chosen bit rates.
        var seen = Set<String>()
        func freshID() -> String {
            var id = ShareBookCrypto.newID()
            while !seen.insert(id).inserted { id = ShareBookCrypto.newID() }
            return id
        }
        let placeholder = String(repeating: "0", count: 64)
        var planned = [ShareBookManifest.Chapter](), estimated = 0, seconds = 0
        for (offset, track) in tracks.enumerated() {
            let number = offset + 1
            guard (1 ... limits.maxBookChapterSeconds).contains(track.estimatedSeconds) else { throw Failure.chapterTooLong(chapter: number) }
            guard track.estimatedSeconds <= limits.maxBookSeconds - seconds else { throw Failure.tooLong }
            seconds += track.estimatedSeconds
            let bytes = ShareCrypto.sealedLength(plaintextLength: ShareCollectionLimits.estimatedBytes(
                seconds: track.estimatedSeconds, bitRate: track.bitRate))
            guard bytes <= limits.maxBookChapterBytes else { throw Failure.chapterTooLarge(chapter: number) }
            guard bytes <= limits.maxBookBytes - estimated else { throw Failure.bookTooLarge }
            estimated += bytes
            planned.append(.init(id: freshID(), title: track.title, durationSeconds: track.estimatedSeconds, audioBytes: bytes,
                                 audioSHA256: placeholder, artist: track.artist, album: track.album, trackNumber: track.trackNumber))
        }
        // The manifest's sealed size hardly moves with the real sizes; a cover that would make it
        // too large is left off rather than refusing the link ("no cover is fine").
        func manifest(_ chapters: [ShareBookManifest.Chapter], cover: ShareBookManifest.Cover?) -> ShareBookManifest {
            ShareBookManifest(collection: kind, title: title, artist: artist, from: from, note: note, cover: cover, tracks: chapters)
        }
        func sealedSize(_ draft: ShareBookManifest) throws -> Int {
            ShareCrypto.sealedLength(plaintextLength: try JSONEncoder().encode(draft.validated(limits: limits)).count)
        }
        var cover = cover
        // Room for the real sizes' and durations' extra digits once the tracks land.
        let slack = 32 * tracks.count + 64
        var manifestBytes = try sealedSize(manifest(planned, cover: cover)) + slack
        if manifestBytes > limits.maxBookManifestBytes, cover != nil {
            cover = nil
            manifestBytes = try sealedSize(manifest(planned, cover: nil)) + slack
        }
        guard manifestBytes <= limits.maxBookManifestBytes else { throw Failure.manifestTooLarge }
        guard manifestBytes <= limits.maxBookBytes - estimated else { throw Failure.bookTooLarge }

        try Self.prepare(directory)
        var written = [URL]()
        let manager = FileManager.default
        do {
            var sealedTracks = [ShareBookManifest.Chapter](), blobs = [Blob](), total = 0
            seconds = 0
            for (offset, _) in tracks.enumerated() {
                try Task.checkCancellation()
                let number = offset + 1
                var entry = planned[offset]
                let plain = directory.appendingPathComponent(plaintextName(offset))
                try? manager.removeItem(at: plain)
                written.append(plain)
                // One track's plaintext at a time: produce, check, seal, write, hash, delete.
                let measured = try await produce(offset, plain)
                let hash: String = try {
                    defer { try? manager.removeItem(at: plain) }
                    guard let audio = try? Data(contentsOf: plain, options: .mappedIfSafe), !audio.isEmpty else {
                        throw Failure.unreadable(chapter: number)
                    }
                    guard (1 ... limits.maxBookChapterSeconds).contains(measured) else { throw Failure.chapterTooLong(chapter: number) }
                    guard measured <= limits.maxBookSeconds - seconds else { throw Failure.tooLong }
                    let bytes = ShareCrypto.sealedLength(plaintextLength: audio.count)
                    guard bytes <= limits.maxBookChapterBytes else { throw Failure.chapterTooLarge(chapter: number) }
                    guard bytes <= limits.maxBookBytes - manifestBytes - total else { throw Failure.bookTooLarge }
                    let sealed = try ShareCrypto.seal(audio, key: ShareBookCrypto.chapterKey(rootKey: key, chapterID: entry.id), purpose: .audio)
                    guard sealed.count == bytes else { throw Failure.damaged }
                    let url = directory.appendingPathComponent(entry.id + ".sealed")
                    try ShareUploadStore.writeProtected(sealed, to: url)
                    written.append(url)
                    entry.audioBytes = bytes
                    entry.durationSeconds = measured
                    return ShareHash.sha256Hex(sealed)
                }()
                seconds += entry.durationSeconds
                total += entry.audioBytes
                entry.audioSHA256 = hash
                blobs.append(.init(id: entry.id, role: .audio, bytes: entry.audioBytes, sha256: hash))
                sealedTracks.append(entry)
                progress?(number, tracks.count)
            }
            let book = try assemble(manifest(sealedTracks, cover: cover), blobs: blobs, key: key, requestID: requestID,
                                    preview: preview, expiresInSeconds: expiresInSeconds, listenerCap: listenerCap, client: client,
                                    reviewPreservationConsent: reviewPreservationConsent, bookLimits: bookLimits, directory: directory)
            return book
        } catch {
            for url in written { try? manager.removeItem(at: url) }
            try? manager.removeItem(at: directory.appendingPathComponent(ticketName))
            throw error
        }
    }
}
