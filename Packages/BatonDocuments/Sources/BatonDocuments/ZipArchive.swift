import Foundation

/// Reading a zip archive, for EPUB: the central directory, stored and deflated entries, and a
/// CRC check on every entry read.
///
/// Written here rather than taken from a package because Foundation has no unzip on iOS, and
/// this is the one place Baton needs one (`specs/document-clippings.md`, *Risks*: "EPUB needs
/// an unzip"). An EPUB uses only what is below: no zip64 (an EPUB is far from 4 GB), no
/// encryption (zip's own; DRM is refused separately), no compression other than deflate.
/// Each of those is refused with a reason rather than misread.
struct ZipArchive {
    struct Entry: Equatable {
        var name: String
        var method: UInt16
        var flags: UInt16
        var crc32: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notAZip
        case unsupported(String)
        case damaged(String)

        var description: String {
            switch self {
            case .notAZip: return "it is not a zip archive"
            case .unsupported(let what): return "it uses \(what), which Baton cannot read"
            case .damaged(let what): return "it is damaged (\(what))"
            }
        }
    }

    let data: [UInt8]
    let entries: [Entry]

    /// The largest entry Baton inflates: an EPUB chapter is kilobytes, a picture a few
    /// megabytes. Anything past this is a zip bomb or not a book.
    static let maximumEntryBytes = 64 * 1024 * 1024

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        self.data = bytes
        // The end-of-central-directory record is in the last 64 KB + 22 bytes (its comment can
        // be up to 64 KB long).
        guard bytes.count >= 22 else { throw Failure.notAZip }
        var eocd: Int?
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while i >= floor {
            if Self.u32(bytes, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard let end = eocd else { throw Failure.notAZip }
        let count = Int(Self.u16(bytes, end + 10))
        let directorySize = Int(Self.u32(bytes, end + 12))
        let directoryOffset = Int(Self.u32(bytes, end + 16))
        if count == 0xFFFF || directoryOffset == 0xFFFF_FFFF { throw Failure.unsupported("zip64") }
        guard directoryOffset + directorySize <= bytes.count else { throw Failure.damaged("the directory is past the end") }

        var entries: [Entry] = []
        var p = directoryOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, Self.u32(bytes, p) == 0x0201_4B50 else { throw Failure.damaged("a directory entry is missing") }
            let flags = Self.u16(bytes, p + 8)
            let method = Self.u16(bytes, p + 10)
            let crc = Self.u32(bytes, p + 16)
            let compressed = Int(Self.u32(bytes, p + 20))
            let uncompressed = Int(Self.u32(bytes, p + 24))
            let nameLength = Int(Self.u16(bytes, p + 28))
            let extraLength = Int(Self.u16(bytes, p + 30))
            let commentLength = Int(Self.u16(bytes, p + 32))
            let offset = Int(Self.u32(bytes, p + 42))
            guard p + 46 + nameLength <= bytes.count else { throw Failure.damaged("a name runs past the end") }
            // Bit 11 says UTF-8; otherwise the name is CP437, which for EPUB paths is ASCII.
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, flags: flags, crc32: crc, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: offset))
            p += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name } ?? entries.first { $0.name.lowercased() == name.lowercased() }
    }

    func contents(of name: String) throws -> Data? {
        guard let entry = entry(named: name) else { return nil }
        return try contents(of: entry)
    }

    func contents(of entry: Entry) throws -> Data {
        if entry.flags & 1 != 0 { throw Failure.unsupported("zip encryption") }
        guard entry.uncompressedSize <= Self.maximumEntryBytes else { throw Failure.unsupported("an entry larger than 64 MB") }
        let h = entry.localHeaderOffset
        guard h + 30 <= data.count, Self.u32(data, h) == 0x0403_4B50 else { throw Failure.damaged("\(entry.name) has no header") }
        let start = h + 30 + Int(Self.u16(data, h + 26)) + Int(Self.u16(data, h + 28))
        guard start + entry.compressedSize <= data.count else { throw Failure.damaged("\(entry.name) runs past the end") }
        let raw = data[start..<(start + entry.compressedSize)]
        let out: [UInt8]
        switch entry.method {
        case 0:
            out = Array(raw)
        case 8:
            do { out = try Inflate.inflate(raw, expectedSize: entry.uncompressedSize) } catch {
                throw Failure.damaged("\(entry.name) does not inflate: \(error)")
            }
        default:
            throw Failure.unsupported("compression method \(entry.method)")
        }
        guard out.count == entry.uncompressedSize else { throw Failure.damaged("\(entry.name) has the wrong size") }
        guard CRC32.checksum(out) == entry.crc32 else { throw Failure.damaged("\(entry.name) fails its checksum") }
        return Data(out)
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// Raw DEFLATE (RFC 1951) decoding: stored, fixed-Huffman and dynamic-Huffman blocks.
///
/// The structure follows Mark Adler's `puff.c`, the reference decoder written to be read:
/// canonical Huffman codes held as counts per length and symbols in code order, decoded a bit
/// at a time. That is slower than a table-driven decoder and plenty for book chapters, and
/// small enough to check against the RFC line by line.
enum Inflate {
    enum Failure: Error, Equatable {
        case truncated, badBlockType, badStoredLength, badCodeLengths, badCode, badDistance, tooLarge
    }

    private struct Huffman {
        var count: [Int]   // codes of each length, 0...15
        var symbol: [Int]  // symbols in canonical order

        init(lengths: ArraySlice<Int>) throws {
            count = Array(repeating: 0, count: 16)
            for l in lengths { count[l] += 1 }
            symbol = Array(repeating: 0, count: lengths.count)
            if count[0] == lengths.count { return }  // no codes: allowed, decoding with it fails
            var left = 1
            for len in 1...15 {
                left <<= 1
                left -= count[len]
                if left < 0 { throw Failure.badCodeLengths }  // over-subscribed
            }
            var offsets = Array(repeating: 0, count: 16)
            for len in 1..<15 { offsets[len + 1] = offsets[len] + count[len] }
            for (s, l) in lengths.enumerated() where l != 0 {
                symbol[offsets[l]] = s
                offsets[l] += 1
            }
        }
    }

    private struct Reader {
        let input: ArraySlice<UInt8>
        var position: Int
        var bitBuffer: UInt32 = 0
        var bitCount = 0

        init(_ input: ArraySlice<UInt8>) {
            self.input = input
            position = input.startIndex
        }

        mutating func bits(_ need: Int) throws -> Int {
            var value = bitBuffer
            while bitCount < need {
                guard position < input.endIndex else { throw Failure.truncated }
                value |= UInt32(input[position]) << UInt32(bitCount)
                position += 1
                bitCount += 8
            }
            bitBuffer = value >> UInt32(need)
            bitCount -= need
            return Int(value & ((1 << UInt32(need)) - 1))
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1...15 {
                code |= try bits(1)
                let count = h.count[len]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.badCode
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                       4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    /// The order code-length code lengths are sent in (RFC 1951, 3.2.7).
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static func inflate(_ input: ArraySlice<UInt8>, expectedSize: Int? = nil, limit: Int = ZipArchive.maximumEntryBytes) throws -> [UInt8] {
        var out: [UInt8] = []
        if let expectedSize { out.reserveCapacity(min(expectedSize, limit)) }
        var r = Reader(input)
        var last = 0
        repeat {
            last = try r.bits(1)
            switch try r.bits(2) {
            case 0: try stored(&r, &out)
            case 1: try codes(&r, &out, fixedLength, fixedDistance, limit)
            case 2:
                let (length, distance) = try dynamicTables(&r)
                try codes(&r, &out, length, distance, limit)
            default: throw Failure.badBlockType
            }
        } while last == 0
        return out
    }

    private static func stored(_ r: inout Reader, _ out: inout [UInt8]) throws {
        r.bitBuffer = 0
        r.bitCount = 0
        guard r.position + 4 <= r.input.endIndex else { throw Failure.truncated }
        let len = Int(r.input[r.position]) | Int(r.input[r.position + 1]) << 8
        let nlen = Int(r.input[r.position + 2]) | Int(r.input[r.position + 3]) << 8
        guard len == (~nlen & 0xFFFF) else { throw Failure.badStoredLength }
        r.position += 4
        guard r.position + len <= r.input.endIndex else { throw Failure.truncated }
        out.append(contentsOf: r.input[r.position..<(r.position + len)])
        r.position += len
    }

    private static func codes(_ r: inout Reader, _ out: inout [UInt8], _ lengthCode: Huffman, _ distanceCode: Huffman, _ limit: Int) throws {
        while true {
            var symbol = try r.decode(lengthCode)
            if symbol < 256 {
                out.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                symbol -= 257
                guard symbol < 29 else { throw Failure.badCode }
                let length = lengthBase[symbol] + (try r.bits(lengthExtra[symbol]))
                let d = try r.decode(distanceCode)
                guard d < 30 else { throw Failure.badDistance }
                let distance = distanceBase[d] + (try r.bits(distanceExtra[d]))
                guard distance <= out.count else { throw Failure.badDistance }
                let start = out.count - distance
                for k in 0..<length { out.append(out[start + k]) }
            }
            if out.count > limit { throw Failure.tooLarge }
        }
    }

    private static let fixedLength: Huffman = {
        var lengths = Array(repeating: 8, count: 288)
        for s in 144..<256 { lengths[s] = 9 }
        for s in 256..<280 { lengths[s] = 7 }
        return try! Huffman(lengths: lengths[...])
    }()

    private static let fixedDistance: Huffman = try! Huffman(lengths: Array(repeating: 5, count: 30)[...])

    private static func dynamicTables(_ r: inout Reader) throws -> (Huffman, Huffman) {
        let nlen = try r.bits(5) + 257
        let ndist = try r.bits(5) + 1
        let ncode = try r.bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw Failure.badCodeLengths }
        var codeLengths = Array(repeating: 0, count: 19)
        for i in 0..<ncode { codeLengths[codeLengthOrder[i]] = try r.bits(3) }
        let lencode = try Huffman(lengths: codeLengths[...])

        var lengths = Array(repeating: 0, count: nlen + ndist)
        var index = 0
        while index < nlen + ndist {
            var symbol = try r.decode(lencode)
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
                continue
            }
            var value = 0
            if symbol == 16 {
                guard index > 0 else { throw Failure.badCodeLengths }
                value = lengths[index - 1]
                symbol = 3 + (try r.bits(2))
            } else if symbol == 17 {
                symbol = 3 + (try r.bits(3))
            } else {
                symbol = 11 + (try r.bits(7))
            }
            guard index + symbol <= nlen + ndist else { throw Failure.badCodeLengths }
            for _ in 0..<symbol { lengths[index] = value; index += 1 }
        }
        guard lengths[256] != 0 else { throw Failure.badCodeLengths }  // no end-of-block code
        return (try Huffman(lengths: lengths[0..<nlen]), try Huffman(lengths: lengths[nlen...]))
    }
}
