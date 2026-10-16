import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLResponse, HTTPURLResponse and URLError on Linux
#endif

/// A book's cover: the parts every device and the gateway agree on.
///
/// A cover comes, in order of preference, from the book's own file (an EPUB's cover picture),
/// from Open Library when the listener asks for one ("Find Cover…"), from a design made here
/// from the title and author ("Make a Cover"), or from a picture the listener chooses. Whatever
/// its source, what is kept and sent is one bounded JPEG or PNG, re-encoded on the device that
/// took it (`BookCoverImaging`), so the gateway and the other devices only ever see an image
/// this code made.
///
/// Foundation only, like the rest of the package, so the gateway decodes the same types.
public enum BookCoverImage {
    /// The most a stored or uploaded cover may be. A re-encoded 1024-pixel cover is a few hundred
    /// kilobytes; the gateway refuses anything past this.
    public static let maximumBytes = 2 * 1024 * 1024
    /// The most a picture may be before it is decoded: a download from Open Library, a chosen
    /// file, an EPUB's cover. Larger is not a cover.
    public static let maximumSourceBytes = 15 * 1024 * 1024
    /// The longest side a kept cover has, in pixels.
    public static let maximumSide = 1024

    public enum Kind: String, Codable, Sendable {
        case jpeg, png

        public var mimeType: String { self == .jpeg ? "image/jpeg" : "image/png" }
        public var fileExtension: String { self == .jpeg ? "jpg" : "png" }

        public init?(mimeType: String) {
            switch mimeType.lowercased().split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) {
            case "image/jpeg", "image/jpg": self = .jpeg
            case "image/png": self = .png
            default: return nil
            }
        }
    }

    /// What the bytes are, by their signature rather than by anything said about them. Only the
    /// two kinds Baton writes are recognised: the gateway keeps nothing else.
    public static func kind(of data: Data) -> Kind? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return .jpeg }
        if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        return nil
    }
}

extension BookJob {
    /// The cover the home server keeps for a book, or that it removed. Kept beside
    /// the job in its own file (`cover.json`), never in `job.json`, so the render loop, which
    /// writes the job back from its own copy, cannot undo a cover change.
    ///
    /// `changedAt` is the home server's own clock, set by every upload and every removal, so a
    /// device can tell "changed since I last looked" without comparing clocks across devices.
    /// A removal keeps the record with no digest, so another device removes its copy too.
    public struct Cover: Codable, Sendable, Equatable {
        /// The image's digest; nil when the cover was removed.
        public var sha256: String?
        public var kind: BookCoverImage.Kind?
        public var bytes: Int?
        public var changedAt: Date
        /// Counts every change of this job's cover, from 1. `changedAt` is written to the whole
        /// second, so two changes in one second read the same by it and never by this. Nil in a
        /// record from a gateway older than revisions; a client then compares `changedAt`.
        public var revision: Int?

        public init(sha256: String?, kind: BookCoverImage.Kind?, bytes: Int?, changedAt: Date, revision: Int? = nil) {
            self.sha256 = sha256
            self.kind = kind
            self.bytes = bytes
            self.changedAt = changedAt
            self.revision = revision
        }

        public var isRemoved: Bool { sha256 == nil }
    }
}

// MARK: - Open Library

/// "Find Cover…": Open Library's search and covers APIs, which need no key.
///
/// Only the title and the author leave the device, and only when the listener asks. The search
/// answers with works; a work with a `cover_i` has a picture at
/// `https://covers.openlibrary.org/b/id/<cover_i>-<S|M|L>.jpg`. Checked against the live API on
/// 2026-10-16: `docs[].cover_i` (Int, absent when the work has none), `title`, `author_name`
/// ([String]), `first_publish_year`, `edition_count`, `key` ("/works/OL88800W").
public enum OpenLibraryCovers {
    public static let searchEndpoint = URL(string: "https://openlibrary.org/search.json")!
    public static let coversHost = "covers.openlibrary.org"
    /// How many works to ask for. Some have no cover, so more than are shown.
    public static let searchLimit = 20
    /// How many candidates to show at most.
    public static let candidateLimit = 12
    /// A listener waiting on a sheet: past this, say the search is slow rather than spin.
    public static let timeout: TimeInterval = 15

    public enum Size: String, Sendable { case small = "S", medium = "M", large = "L" }

    /// One cover the listener can pick.
    public struct Candidate: Equatable, Sendable, Identifiable {
        public var coverID: Int
        public var title: String
        public var authors: [String]
        public var year: Int?
        public var editions: Int?
        public var id: Int { coverID }

        public init(coverID: Int, title: String, authors: [String], year: Int? = nil, editions: Int? = nil) {
            self.coverID = coverID
            self.title = title
            self.authors = authors
            self.year = year
            self.editions = editions
        }

        public func imageURL(_ size: Size) -> URL { OpenLibraryCovers.coverURL(id: coverID, size: size) }

        /// "E. M. Forster, 1909" under the picture.
        public var caption: String {
            ([authors.first] + [year.map(String.init)]).compactMap { $0 }.joined(separator: ", ")
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noTitle
        case unreadable
        case http(Int)
        case offline
        case slow
        case notAnImage

        public var description: String {
            switch self {
            case .noTitle: return "This book has no title to search for."
            case .unreadable: return "Open Library answered with something Baton can't read."
            case let .http(status): return "Open Library answered \(status). Try again later."
            case .offline: return "Baton couldn't reach Open Library. Check the connection and try again."
            case .slow: return "Open Library is taking too long to answer. Try again later."
            case .notAnImage: return "That cover couldn't be read as a picture. Try another one."
            }
        }
    }

    /// The search for one book: its title, and its author when known. `fields` keeps the answer
    /// small; `default=false` is not needed here because covers are only asked for by id.
    public static func searchURL(title: String, author: String?, limit: Int = searchLimit,
                                 endpoint: URL = searchEndpoint) -> URL? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        var query = [URLQueryItem(name: "title", value: title)]
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty,
           !BookCoverDesign.isUnknownAuthor(author) {
            query.append(URLQueryItem(name: "author", value: author))
        }
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        query.append(URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,first_publish_year,edition_count"))
        parts.queryItems = query
        return parts.url
    }

    /// What fetching needs from the caller: a URLSession's `data(from:)` in the apps, a scripted
    /// answer or a loopback server in tests.
    public typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

    /// The candidates for a book, or why there are none, in the words the finder shows: a
    /// timeout is "taking too long", anything else that kept the answer away is "couldn't reach".
    public static func search(title: String, author: String?, endpoint: URL = searchEndpoint,
                              fetch: Fetch) async -> Result<[Candidate], Failure> {
        guard let url = searchURL(title: title, author: author, endpoint: endpoint) else { return .failure(.noTitle) }
        do {
            let (data, response) = try await fetch(url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .failure(.http(status)) }
            return .success(try candidates(from: data, title: title, author: author))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Self.failure(for: error))
        }
    }

    /// The bytes of a download, refused as soon as they pass `limit` rather than after the whole
    /// body is in memory. `cancel` stops the transfer when the limit is hit.
    public static func collect<S: AsyncSequence>(_ bytes: S, limit: Int, cancel: @Sendable () -> Void = {}) async throws -> Data
        where S.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit {
                cancel()
                throw Failure.notAnImage
            }
        }
        return data
    }

    /// A transport error in the finder's words.
    public static func failure(for error: Error) -> Failure {
        if let error = error as? URLError, error.code == .timedOut { return .slow }
        return .offline
    }

    /// The picture for a cover id. `default=false` makes a missing picture a 404 instead of a
    /// blank image the listener would be offered.
    public static func coverURL(id: Int, size: Size) -> URL {
        URL(string: "https://\(coversHost)/b/id/\(id)-\(size.rawValue).jpg?default=false")!
    }

    /// The candidates in a search answer, best first: works without a picture dropped, the
    /// same picture once, then the closest title and author ahead of the rest, keeping Open
    /// Library's own order (its relevance) among equals.
    public static func candidates(from data: Data, title: String, author: String?,
                                  limit: Int = candidateLimit) throws -> [Candidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]] else { throw Failure.unreadable }
        var seen = Set<Int>()
        var found: [Candidate] = []
        for doc in docs {
            guard let cover = (doc["cover_i"] as? Int) ?? (doc["cover_i"] as? NSNumber)?.intValue, cover > 0,
                  seen.insert(cover).inserted else { continue }
            found.append(Candidate(coverID: cover, title: (doc["title"] as? String) ?? title,
                                   authors: (doc["author_name"] as? [String]) ?? [],
                                   year: doc["first_publish_year"] as? Int, editions: doc["edition_count"] as? Int))
        }
        return Array(rank(found, title: title, author: author).prefix(limit))
    }

    /// Exact title first, then a title that contains the asked one (a subtitle), then the rest;
    /// within each, a matching author first. Stable, so Open Library's relevance decides ties.
    public static func rank(_ candidates: [Candidate], title: String, author: String?) -> [Candidate] {
        let wanted = normalized(title)
        let surname = author.flatMap { normalized($0).split(separator: " ").last.map(String.init) }
        func score(_ c: Candidate) -> Int {
            let t = normalized(c.title)
            var s = t == wanted ? 4 : (t.hasPrefix(wanted) || wanted.hasPrefix(t) || t.contains(wanted) ? 2 : 0)
            if let surname, !surname.isEmpty, c.authors.contains(where: { normalized($0).split(separator: " ").contains(Substring(surname)) }) {
                s += 1
            }
            return s
        }
        return candidates.enumerated()
            .sorted { a, b in
                let (x, y) = (score(a.element), score(b.element))
                return x != y ? x > y : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Lowercase, no accents or punctuation, single spaces, no leading article: "The Machine
    /// Stops!" and "machine stops" are the same title.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let words = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        var parts = String(words).split(separator: " ").map(String.init)
        if let first = parts.first, ["the", "a", "an"].contains(first), parts.count > 1 { parts.removeFirst() }
        return parts.joined(separator: " ")
    }

    /// Whether a downloaded picture may be taken at all: HTTPS from Open Library's own hosts
    /// (and archive.org, where it keeps some pictures), a 2xx answer, and no more than a cover's
    /// worth of bytes. What is taken is still decoded and re-encoded before it is kept.
    public static func acceptsDownload(from url: URL?, status: Int, bytes: Int) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        let trusted = host == coversHost || host == "openlibrary.org" || host.hasSuffix(".archive.org") || host == "archive.org"
        return trusted && (200..<300).contains(status) && bytes > 0 && bytes <= BookCoverImage.maximumSourceBytes
    }
}

// MARK: - A designed cover

/// "Make a Cover": a cover drawn on the device from the title and the author, with
/// no network and no model. Only when both are known, which is what "the book's context is fully
/// defined" means: a cover with a title and no author would look like a finished design that
/// says less than the row it sits in.
///
/// This is the design, decided from the text alone and the same on every device: the palette
/// and the ornament come from a stable hash of the title (FNV-1a, not Swift's per-process
/// seeded `Hasher`), so the same book always gets the same cover. `BookCoverImaging.render`
/// draws it.
public struct BookCoverDesign: Equatable, Sendable {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case noTitle
        case noAuthor

        /// Why "Make a Cover" is unavailable, in the menu's own words.
        public var description: String {
            switch self {
            case .noTitle: return "needs the book's title"
            case .noAuthor: return "needs the book's author"
            }
        }
    }

    public struct RGB: Equatable, Sendable {
        public var red: Double, green: Double, blue: Double

        public init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        /// WCAG relative luminance.
        public var luminance: Double {
            func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }

        public static func contrast(_ a: RGB, _ b: RGB) -> Double {
            let (x, y) = (a.luminance, b.luminance)
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
    }

    public struct Palette: Equatable, Sendable {
        public var name: String
        public var background: RGB
        public var ink: RGB
        public var accent: RGB
    }

    /// The ornament behind the type.
    public enum Motif: String, CaseIterable, Sendable {
        case band, rings, stripes, frame
    }

    /// Book-jacket colours, each pair chosen so the title clears WCAG AAA (7:1) on its ground
    /// (`BookCoverTests` checks every one).
    public static let palettes: [Palette] = [
        Palette(name: "oxblood", background: RGB(0x5B1A1F), ink: RGB(0xF6EBDD), accent: RGB(0xD9A441)),
        Palette(name: "ink", background: RGB(0x14213D), ink: RGB(0xF4EFE6), accent: RGB(0xE07A5F)),
        Palette(name: "forest", background: RGB(0x1E3B2F), ink: RGB(0xF1EBDC), accent: RGB(0xC9A227)),
        Palette(name: "teal", background: RGB(0x0F4C5C), ink: RGB(0xFBF4E6), accent: RGB(0xF2A65A)),
        Palette(name: "plum", background: RGB(0x3D1E3F), ink: RGB(0xF7ECE1), accent: RGB(0x9CC5A1)),
        Palette(name: "charcoal", background: RGB(0x222222), ink: RGB(0xF3F0EA), accent: RGB(0xE63946)),
        Palette(name: "cream", background: RGB(0xF3EAD7), ink: RGB(0x1D1A16), accent: RGB(0xB5442E)),
        Palette(name: "sand", background: RGB(0xE9D8B4), ink: RGB(0x231A10), accent: RGB(0x2F5D62)),
        Palette(name: "sky", background: RGB(0xDCE8EF), ink: RGB(0x12263A), accent: RGB(0xC8553D)),
        Palette(name: "mustard", background: RGB(0xE3B23C), ink: RGB(0x1B1B1E), accent: RGB(0x7A1F2B)),
        Palette(name: "rose", background: RGB(0xF2D7D0), ink: RGB(0x2A1418), accent: RGB(0x3E6259)),
        Palette(name: "slate", background: RGB(0x2F3E46), ink: RGB(0xF0EDE5), accent: RGB(0x84A98C)),
    ]

    public let title: String
    public let author: String
    public let palette: Palette
    public let motif: Motif
    /// The hash the choices came from, for the ornament's own small variations.
    public let seed: UInt64

    /// The design for a book, or why there is none.
    public static func make(title: String?, author: String?) throws -> BookCoverDesign {
        let title = clean(title ?? "")
        guard !title.isEmpty else { throw Refusal.noTitle }
        let author = clean(author ?? "")
        guard !author.isEmpty, !isUnknownAuthor(author) else { throw Refusal.noAuthor }
        let seed = fnv1a(OpenLibraryCovers.normalized(title))
        return BookCoverDesign(title: title, author: author, palette: palettes[Int(seed % UInt64(palettes.count))],
                               motif: Motif.allCases[Int((seed >> 17) % UInt64(Motif.allCases.count))], seed: seed)
    }

    /// Why "Make a Cover" is off for this book, or nil when it can be made.
    public static func refusal(title: String?, author: String?) -> Refusal? {
        do { _ = try make(title: title, author: author); return nil } catch { return error as? Refusal }
    }

    /// An author that is a placeholder rather than a name.
    public static func isUnknownAuthor(_ author: String) -> Bool {
        ["unknown", "unknown author", "anonymous", "anon", "various", "n/a", "none"]
            .contains(clean(author).lowercased())
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 64-bit FNV-1a over the UTF-8 bytes: stable across processes, devices and releases.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
