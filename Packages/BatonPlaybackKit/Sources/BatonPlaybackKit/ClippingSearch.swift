import Foundation
import Observation

/// The Clippings search index, shared by the Mac and the iPhone (M8.9, DOC-12).
///
/// Clippings used to filter with `lowercased().contains` over every clipping's whole text on each
/// keystroke. A book adds chapters of about 70,000 characters, so a library of a few books meant
/// lowercasing and scanning tens of megabytes per key. This keeps each searchable field folded
/// once, ahead of time, plus a small bitmap of the field's short byte sequences, and a query
/// touches only the clippings whose bitmap could contain it.
///
/// **What matches.** Exactly what matched before, and also anything that differs only in case or
/// accents: "cafe" finds "Café". A field matches when its folded text contains the folded query
/// as one substring, so a multi-word query is still one phrase, as it was.
///
/// Why it can never lose an old match: folding is the old `lowercased()` followed by canonical
/// decomposition (NFD) and dropping the nonspacing marks, applied the same way to the field and to
/// the query. If the lowercased field contained the lowercased query, the field is the query with
/// text on either side; decomposing and deleting marks from each part keeps the parts in order, so
/// the folded field still contains the folded query. The parity tests check this against the old
/// filter, kept verbatim as the oracle.
///
/// **The bitmap.** Every 1-, 2- and 3-byte sequence of a document's folded fields sets one bit
/// (a one-hash Bloom filter sized to the document). A query's own sequences must all be set
/// before the document is read at all; a bit that is set by coincidence only costs one confirming
/// `memmem`, so the bitmap can narrow but never decide. Per document rather than one shared
/// posting list, so adding, changing or removing a clipping touches that clipping alone.
public struct TextSearchIndex: Sendable {

    /// One searchable thing: a clipping's id and the fields a view searches.
    public struct Document: Sendable, Equatable {
        public var id: String
        public var fields: [String]

        public init(id: String, fields: [String]) {
            self.id = id
            self.fields = fields
        }
    }

    struct Entry: Sendable {
        var raw: [String]
        var folded: [[UInt8]]
        var grams: GramBits
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public var count: Int { entries.count }

    /// Whether `id` is indexed, for tests.
    public func contains(id: String) -> Bool { entries[id] != nil }

    // MARK: - Updating

    /// Makes the index hold exactly `documents`: new ones are added, changed ones re-folded,
    /// missing ones dropped, and unchanged ones (compared byte for byte) left alone.
    @discardableResult
    public mutating func sync(_ documents: [Document]) -> (added: Int, changed: Int, removed: Int) {
        var added = 0, changed = 0
        var seen = Set<String>()
        seen.reserveCapacity(documents.count)
        for document in documents {
            seen.insert(document.id)
            if let existing = entries[document.id] {
                if Self.sameBytes(existing.raw, document.fields) { continue }
                changed += 1
            } else {
                added += 1
            }
            update(document)
        }
        let gone = entries.keys.filter { !seen.contains($0) }
        for id in gone { entries[id] = nil }
        return (added, changed, gone.count)
    }

    /// Adds `document`, or replaces what was indexed under its id.
    public mutating func update(_ document: Document) {
        let folded = document.fields.map(Self.fold)
        entries[document.id] = Entry(raw: document.fields, folded: folded, grams: GramBits(folded))
    }

    public mutating func remove(id: String) {
        entries[id] = nil
    }

    // MARK: - Searching

    /// The ids of every document with a field that contains `query`, ignoring case and accents.
    /// An empty query matches nothing here: a view shows everything for an empty query without
    /// asking.
    public func search(_ query: String) -> Set<String> {
        guard !query.isEmpty else { return [] }
        let needle = Self.fold(query)
        // A query of nothing but marks folds to nothing; answer it the old way.
        guard !needle.isEmpty else {
            let lowered = query.lowercased()
            return Set(entries.filter { $0.value.raw.contains { $0.lowercased().contains(lowered) } }.keys)
        }
        let probes = GramBits.probes(needle)
        let candidates = entries.filter { $0.value.grams.mayContain(probes) }.map { ($0.key, $0.value.folded) }
        let bytes = candidates.reduce(0) { total, candidate in total + candidate.1.reduce(0) { $0 + $1.count } }
        var found = [Bool](repeating: false, count: candidates.count)
        if bytes < Self.parallelBytes || candidates.count < 2 {
            for (i, candidate) in candidates.enumerated() {
                found[i] = candidate.1.contains { Self.find(needle, in: $0) }
            }
        } else {
            // Every candidate read to the end (a phrase made of common words that is not there)
            // is the slow case: about 20 MB for 300 chapters. Spread it over the cores.
            let lanes = min(candidates.count, ProcessInfo.processInfo.activeProcessorCount)
            found.withUnsafeMutableBufferPointer { out in
                nonisolated(unsafe) let out = out
                DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                    for i in stride(from: lane, to: candidates.count, by: lanes) {
                        out[i] = candidates[i].1.contains { Self.find(needle, in: $0) }
                    }
                }
            }
        }
        var result = Set<String>()
        for (i, candidate) in candidates.enumerated() where found[i] { result.insert(candidate.0) }
        return result
    }

    /// Below this many candidate bytes one thread is quicker than starting several.
    static let parallelBytes = 1 << 20

    /// Whether one small field (a book's title) matches `query` with the index's rules, for the
    /// few things a view filters without indexing them.
    public static func matches(_ text: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = fold(query)
        guard !needle.isEmpty else { return text.lowercased().contains(query.lowercased()) }
        return find(needle, in: fold(text))
    }

    // MARK: - Folding

    /// `text` lowercased, decomposed, without nonspacing marks, as UTF-8. Comparing bytes is
    /// enough: a valid UTF-8 needle can only be found in valid UTF-8 at a scalar boundary.
    public static func fold(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        let ascii = text.utf8.withContiguousStorageIfAvailable { bytes in
            bytes.allSatisfy { $0 < 0x80 }
        } ?? text.utf8.allSatisfy { $0 < 0x80 }
        if ascii {
            // What `lowercased()` does to ASCII, without making a second string.
            for byte in text.utf8 { out.append(byte &- 65 < 26 ? byte | 0x20 : byte) }
            return out
        }
        for scalar in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars
        where scalar.properties.generalCategory != .nonspacingMark {
            UTF8.encode(scalar) { out.append($0) }
        }
        return out
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= haystack.count else { return false }
        return haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                memmem(hay.baseAddress, hay.count, pin.baseAddress, pin.count) != nil
            }
        }
    }

    /// Byte equality, which never normalizes: a string that only looks the same is re-folded,
    /// which is harmless, and nothing costs a Unicode comparison of a whole chapter.
    static func sameBytes(_ a: [String], _ b: [String]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where !x.utf8.elementsEqual(y.utf8) { return false }
        return true
    }
}

/// One document's 1-, 2- and 3-byte sequences as a bitmap, about two bits per byte of text
/// (512 bits for a title, 64 Kbit for a 70k-character chapter).
struct GramBits: Sendable {
    private var words: [UInt64]
    private var shift: UInt32

    init(_ fields: [[UInt8]]) {
        let bytes = fields.reduce(0) { $0 + $1.count }
        var log2 = 9
        while log2 < 17 && (1 << log2) < bytes * 2 { log2 += 1 }
        words = [UInt64](repeating: 0, count: (1 << log2) / 64)
        shift = UInt32(32 - log2)
        for field in fields { add(field) }
    }

    private mutating func add(_ field: [UInt8]) {
        field.withUnsafeBufferPointer { p in
            let n = p.count
            var i = 0
            while i < n {
                let a = UInt32(p[i])
                set(Self.hash(a | 1 << 24))
                if i + 1 < n {
                    let ab = a << 8 | UInt32(p[i + 1])
                    set(Self.hash(ab | 2 << 24))
                    if i + 2 < n { set(Self.hash(ab << 8 | UInt32(p[i + 2]) | 3 << 24)) }
                }
                i += 1
            }
        }
    }

    private mutating func set(_ hash: UInt32) {
        let bit = Int(hash >> shift)
        words[bit >> 6] |= 1 << UInt64(bit & 63)
    }

    /// The hashes a document must hold to possibly contain `needle`: its 3-byte sequences, or
    /// for a shorter needle the needle itself.
    static func probes(_ needle: [UInt8]) -> [UInt32] {
        switch needle.count {
        case 0: return []
        case 1: return [hash(UInt32(needle[0]) | 1 << 24)]
        case 2: return [hash(UInt32(needle[0]) << 8 | UInt32(needle[1]) | 2 << 24)]
        default:
            var seen = Set<UInt32>()
            var out: [UInt32] = []
            for i in 0..<(needle.count - 2) {
                let h = hash(UInt32(needle[i]) << 16 | UInt32(needle[i + 1]) << 8 | UInt32(needle[i + 2]) | 3 << 24)
                if seen.insert(h).inserted { out.append(h) }
            }
            return out
        }
    }

    func mayContain(_ probes: [UInt32]) -> Bool {
        for hash in probes {
            let bit = Int(hash >> shift)
            if words[bit >> 6] & (1 << UInt64(bit & 63)) == 0 { return false }
        }
        return true
    }

    /// Fibonacci hashing: the top bits of the product are well mixed, and a bitmap of 2^k bits
    /// takes the top k.
    static func hash(_ gram: UInt32) -> UInt32 { gram &* 0x9E37_79B1 }
}

/// The index behind a Clippings list, kept up to date with the store and answering a debounced
/// query off the main thread.
///
/// One per app, on the app's model, so leaving Clippings and coming back does not fold every
/// chapter again. The view calls `follow(_:)` when it appears and `setQuery(_:)` as the person
/// types, then filters through `filter(_:)` and `matches(title:)`.
@MainActor
@Observable
public final class ClippingSearch {

    /// Which of a clipping's fields a view searches. The Mac's list never searched the book's
    /// title on a chapter and the iPhone's did, so each keeps what it had.
    public struct Fields: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let title = Fields(rawValue: 1 << 0)
        public static let source = Fields(rawValue: 1 << 1)
        public static let documentTitle = Fields(rawValue: 1 << 2)
        public static let text = Fields(rawValue: 1 << 3)

        func values(of clipping: ClippingStore.Clipping) -> [String] {
            var out: [String] = []
            if contains(.title) { out.append(clipping.title) }
            if contains(.source), let source = clipping.source { out.append(source) }
            if contains(.documentTitle), let title = clipping.documentTitle { out.append(title) }
            if contains(.text), let text = clipping.text { out.append(text) }
            return out
        }
    }

    public let fields: Fields

    /// The ids matching `answeredQuery`; nil while there is no answer to filter by.
    public private(set) var matches: Set<String>?
    /// The query `matches` answers.
    public private(set) var answeredQuery = ""

    /// Whether lists should be filtered: a non-empty query has been answered.
    public var isFiltering: Bool { matches != nil }

    @ObservationIgnored private let indexer = Indexer()
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private weak var store: ClippingStore?
    /// The query as last typed, trimmed. Not observed: views redraw from their own text.
    @ObservationIgnored public private(set) var query = ""
    @ObservationIgnored private var pendingQuery: Task<Void, Never>?
    /// The last index update; each waits for the one before, so updates land in order.
    @ObservationIgnored private var lastSync: Task<Void, Never>?
    @ObservationIgnored private var syncGeneration = 0

    public init(fields: Fields, debounce: Duration = .milliseconds(150)) {
        self.fields = fields
        self.debounce = debounce
    }

    /// Indexes `store`'s items now and again whenever they change. Calling it again with the
    /// same store does nothing.
    public func follow(_ store: ClippingStore) {
        guard self.store !== store else { return }
        self.store = store
        resync()
    }

    /// The person typed. An empty query clears the filter at once; anything else is answered
    /// after `debounce` of quiet, and only if it is still the latest query by then.
    public func setQuery(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed != query else { return }
        query = trimmed
        pendingQuery?.cancel()
        guard !trimmed.isEmpty else {
            pendingQuery = nil
            matches = nil
            answeredQuery = ""
            return
        }
        let debounce = self.debounce
        pendingQuery = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.answer(trimmed)
        }
    }

    /// `items` narrowed to the answered query, in their order; all of them when not filtering.
    public func filter(_ items: [ClippingStore.Item]) -> [ClippingStore.Item] {
        guard let matches else { return items }
        return items.filter { matches.contains($0.id) }
    }

    /// Whether a small field outside the index (a book's title) matches the answered query.
    public func matches(title: String) -> Bool {
        guard isFiltering else { return true }
        return TextSearchIndex.matches(title, query: answeredQuery)
    }

    /// Settles after the pending query and index update, for tests.
    public func settle() async {
        await lastSync?.value
        await pendingQuery?.value
    }

    // MARK: - Private

    private func answer(_ query: String) async {
        var found: Set<String>
        var generation: Int
        // Asked again if the store changed while this was being answered, so an answer never
        // describes contents the index has since replaced.
        repeat {
            generation = syncGeneration
            await lastSync?.value
            found = await indexer.search(query)
        } while generation != syncGeneration
        guard query == self.query else { return }
        matches = found
        answeredQuery = query
    }

    private func resync() {
        guard let store else { return }
        let items = withObservationTracking { store.items } onChange: { [weak self] in
            Task { @MainActor in self?.resync() }
        }
        let fields = self.fields
        let documents = items.map { TextSearchIndex.Document(id: $0.id, fields: fields.values(of: $0.clipping)) }
        let previous = lastSync
        syncGeneration += 1
        lastSync = Task { [weak self, indexer] in
            await previous?.value
            await indexer.sync(documents)
            // A query already answered is answered again over the new contents at once.
            guard let self, !self.query.isEmpty, self.matches != nil else { return }
            let query = self.query
            let found = await indexer.search(query)
            guard query == self.query else { return }
            self.matches = found
            self.answeredQuery = query
        }
    }

    private actor Indexer {
        var index = TextSearchIndex()
        func sync(_ documents: [TextSearchIndex.Document]) { index.sync(documents) }
        func search(_ query: String) -> Set<String> { index.search(query) }
    }
}
