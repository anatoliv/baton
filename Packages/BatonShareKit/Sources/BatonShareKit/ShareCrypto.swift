#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation

/// The `BSH1` format: AES-128-GCM in fixed-size records, keyed by a subkey of the share key.
///
/// Spec: `specs/song-sharing.md` §2. Vectors: `specs/share-crypto/vectors.json`, written by an
/// independent Python implementation, and checked here and by the browser's `share-crypto.mjs`.
///
/// **Why records rather than one GCM call over the whole song.** A single seal cannot be checked
/// until the last byte has arrived, and a reader that wants to start sooner has to trust bytes it
/// has not authenticated. Records authenticate as they go. The final flag in each record's
/// associated data is what makes that safe against truncation: a song cut at a record boundary
/// would otherwise decrypt cleanly as a shorter song.
public enum ShareCrypto {
    public static let magic = Data("BSH1".utf8)
    public static let headerLength = 20
    public static let tagLength = 16
    public static let nonceLength = 12
    public static let keyLength = 16
    public static let defaultRecordSize = 65536
    public static let recordSizeRange = 1024 ... 1_048_576

    /// What the subkey is for. Each payload gets its own, so a ciphertext can never be opened as
    /// a different kind of thing, even under the same share key.
    public enum Purpose: String, Sendable, CaseIterable {
        case audio, meta, art

        var info: Data { Data("baton-share v1 \(rawValue)".utf8) }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The bytes are not a `BSH1` stream at all: bad magic, a record size outside the range,
        /// or a length no sealer could have produced.
        case format(String)
        /// A record did not authenticate: wrong key, tampering, truncation or reordering.
        case authentication
        /// The key is not 16 bytes.
        case badKey
    }

    /// A fresh share key.
    public static func newKey() -> Data { randomBytes(keyLength) }

    public static func seal(_ plaintext: Data, key: Data, purpose: Purpose,
                            recordSize: Int = defaultRecordSize,
                            baseNonce: Data? = nil) throws -> Data {
        guard recordSizeRange.contains(recordSize) else {
            throw Failure.format("record size \(recordSize) is outside \(recordSizeRange)")
        }
        let subkey = try self.subkey(key, purpose)
        let base = baseNonce ?? randomBytes(nonceLength)
        guard base.count == nonceLength else { throw Failure.format("base nonce must be 12 bytes") }

        var header = magic
        header.append(contentsOf: bigEndianBytes(UInt32(recordSize)))
        header.append(base)

        let plain = [UInt8](plaintext)
        let count = max(1, (plain.count + recordSize - 1) / recordSize)
        var out = header
        out.reserveCapacity(header.count + plain.count + count * tagLength)
        for index in 0 ..< count {
            let start = index * recordSize
            let end = min(start + recordSize, plain.count)
            let chunk = start < end ? Data(plain[start ..< end]) : Data()
            let box = try AES.GCM.seal(chunk, using: subkey,
                                       nonce: AES.GCM.Nonce(data: nonce(base, index)),
                                       authenticating: aad(header, isFinal: index == count - 1))
            out.append(box.ciphertext)
            out.append(box.tag)
        }
        return out
    }

    public static func open(_ ciphertext: Data, key: Data, purpose: Purpose) throws -> Data {
        let bytes = [UInt8](ciphertext)
        let layout = try self.layout(headerBytes: Array(bytes.prefix(headerLength)),
                                     totalLength: bytes.count)
        let subkey = try self.subkey(key, purpose)
        let header = Data(bytes[0 ..< headerLength])
        let base = Data(bytes[8 ..< headerLength])

        var out = Data()
        out.reserveCapacity(bytes.count - headerLength - layout.records * tagLength)
        var offset = headerLength
        for index in 0 ..< layout.records {
            let isFinal = index == layout.records - 1
            let length = isFinal ? layout.lastRecordLength : layout.recordSize + tagLength
            let record = bytes[offset ..< offset + length]
            offset += length
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: nonce(base, index)),
                    ciphertext: Data(record.dropLast(tagLength)),
                    tag: Data(record.suffix(tagLength)))
                out.append(try AES.GCM.open(box, using: subkey,
                                            authenticating: aad(header, isFinal: isFinal)))
            } catch {
                throw Failure.authentication
            }
        }
        return out
    }

    /// The shape of a `BSH1` stream, from its header and total length alone.
    public struct Layout: Equatable, Sendable {
        public let recordSize: Int
        public let records: Int
        public let lastRecordLength: Int
        /// What the plaintext must have been, given the layout.
        public var plaintextLength: Int { (records - 1) * recordSize + lastRecordLength - ShareCrypto.tagLength }
    }

    /// Checks that a stream is structurally `BSH1` without any key.
    ///
    /// The server runs this over every upload. It cannot authenticate anything, but it does mean
    /// the share endpoint only ever stores things that are shaped like a sealed song, which makes
    /// it a poor general-purpose file host.
    public static func layout(headerBytes: [UInt8], totalLength: Int) throws -> Layout {
        guard totalLength >= headerLength + tagLength, headerBytes.count >= headerLength else {
            throw Failure.format("shorter than one empty record")
        }
        guard Data(headerBytes[0 ..< 4]) == magic else { throw Failure.format("not BSH1") }
        let recordSize = headerBytes[4 ..< 8].reduce(0) { $0 << 8 | Int($1) }
        guard recordSizeRange.contains(recordSize) else {
            throw Failure.format("record size \(recordSize) is outside \(recordSizeRange)")
        }
        let body = totalLength - headerLength
        let full = recordSize + tagLength
        let records = (body + full - 1) / full
        let last = body - (records - 1) * full
        guard last >= tagLength else { throw Failure.format("the last record is shorter than a tag") }
        return Layout(recordSize: recordSize, records: records, lastRecordLength: last)
    }

    /// The length a sealed plaintext of `count` bytes will have. Lets a client declare
    /// `audioBytes` before it has finished sealing, and a test check the arithmetic.
    public static func sealedLength(plaintextLength count: Int, recordSize: Int = defaultRecordSize) -> Int {
        let records = max(1, (count + recordSize - 1) / recordSize)
        return headerLength + count + records * tagLength
    }

    // MARK: - Pieces

    static func subkey(_ key: Data, _ purpose: Purpose) throws -> SymmetricKey {
        guard key.count == keyLength else { throw Failure.badKey }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
                                      salt: Data(), info: purpose.info,
                                      outputByteCount: keyLength)
    }

    static func nonce(_ base: Data, _ index: Int) -> Data {
        var bytes = [UInt8](base)
        var counter = UInt64(index)
        // A 96-bit big-endian counter; an index never needs more than the low 64 bits.
        for position in stride(from: nonceLength - 1, through: nonceLength - 8, by: -1) {
            bytes[position] ^= UInt8(counter & 0xFF)
            counter >>= 8
        }
        return Data(bytes)
    }

    static func aad(_ header: Data, isFinal: Bool) -> Data {
        var data = header
        data.append(isFinal ? 1 : 0)
        return data
    }

    static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// SHA-256 as lowercase hex, the form every checksum in the share protocol takes.
public enum ShareHash {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An incremental hash, for an upload checked as it streams to disk.
    public struct Running {
        private var hasher = SHA256()
        public init() {}
        public mutating func update(_ data: Data) { hasher.update(data: data) }
        public func finalizeHex() -> String {
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The sharer id for an install secret (spec §1). A prefix of a domain-separated hash: enough
    /// to tell sharers apart in a report, and not the value the server looks the secret up by.
    public static func sharerID(secret: String) -> String {
        String(sha256Hex(Data("baton-share sharer v1\0".utf8) + Data(secret.utf8)).prefix(16))
    }

    /// What the server stores and looks a secret up by.
    public static func secretDigest(_ secret: String) -> String {
        sha256Hex(Data("baton-share secret v1\0".utf8) + Data(secret.utf8))
    }
}

/// Unpadded base64url, the encoding of every id and key in a share link.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }
}
