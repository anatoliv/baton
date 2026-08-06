// Compatibility shims that let the Subsonic client — and everything layered on
// it, including the headless gateway — build on Linux, where Apple's OSLog,
// CryptoKit and Security frameworks don't exist.
//
// Deliberately dependency-free. Adding swift-crypto would pull a package into
// every Mac and iPhone build to serve a Linux-only need; MD5 here is a fixed,
// fully-specified legacy requirement of the Subsonic auth scheme (not a security
// primitive we chose), and the canonical vector in `NavidromeClientTests` proves
// this implementation byte-for-byte on whichever platform runs it.

// Linux splits URLSession/HTTPURLResponse into a separate module; re-export it
// module-wide so no call site needs an #if of its own.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif

#if canImport(OSLog)
@_exported import OSLog
#else
import Foundation

/// The slice of `os.Logger` this codebase uses, for Linux. Messages go to
/// stderr; `privacy:` is accepted and ignored, because there is no unified log
/// to redact into.
public struct Logger: Sendable {
    public enum Privacy: Sendable { case `public`, `private`, auto }

    /// Mirrors OSLog's interpolation so call sites need no `#if` of their own.
    public struct Message: ExpressibleByStringInterpolation, Sendable {
        public struct StringInterpolation: StringInterpolationProtocol {
            var text = ""
            public init(literalCapacity: Int, interpolationCount: Int) {
                text.reserveCapacity(literalCapacity)
            }
            public mutating func appendLiteral(_ literal: String) { text += literal }
            public mutating func appendInterpolation(_ value: some Any, privacy: Privacy = .auto) {
                text += String(describing: value)
            }
        }

        let text: String
        public init(stringLiteral value: String) { text = value }
        public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
    }

    private let label: String

    public init(subsystem: String, category: String) {
        label = "\(subsystem)/\(category)"
    }

    public func debug(_ message: Message) { emit("DEBUG", message) }
    public func info(_ message: Message) { emit("INFO", message) }
    public func notice(_ message: Message) { emit("NOTICE", message) }
    public func warning(_ message: Message) { emit("WARN", message) }
    public func error(_ message: Message) { emit("ERROR", message) }
    public func fault(_ message: Message) { emit("FAULT", message) }

    private func emit(_ level: String, _ message: Message) {
        FileHandle.standardError.write(Data("[\(level)] \(label): \(message.text)\n".utf8))
    }
}
#endif

#if canImport(CryptoKit)
@_exported import CryptoKit
#else
import Foundation

/// `Insecure.MD5`, matching CryptoKit's shape for the one call this codebase
/// makes (`Insecure.MD5.hash(data:)`, then iterating the digest bytes).
/// RFC 1321.
public enum Insecure {
    public struct MD5Digest: Sequence, Sendable {
        let bytes: [UInt8]
        public func makeIterator() -> Array<UInt8>.Iterator { bytes.makeIterator() }
    }

    public enum MD5 {
        public static func hash(data: some DataProtocol) -> MD5Digest {
            MD5Digest(bytes: digest(Array(data)))
        }

        private static let shifts: [UInt32] = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
        ]
        /// floor(abs(sin(i + 1)) * 2^32), the RFC's K table.
        private static let sines: [UInt32] = (0 ..< 64).map {
            UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296))
        }

        private static func digest(_ message: [UInt8]) -> [UInt8] {
            var padded = message
            let bitLength = UInt64(message.count) &* 8
            padded.append(0x80)
            while padded.count % 64 != 56 { padded.append(0) }
            for shift in stride(from: 0, to: 64, by: 8) {
                padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
            }

            var a0: UInt32 = 0x6745_2301, b0: UInt32 = 0xEFCD_AB89
            var c0: UInt32 = 0x98BA_DCFE, d0: UInt32 = 0x1032_5476

            for chunkStart in stride(from: 0, to: padded.count, by: 64) {
                var words = [UInt32](repeating: 0, count: 16)
                for index in 0 ..< 16 {
                    let base = chunkStart + index * 4
                    words[index] = UInt32(padded[base])
                        | UInt32(padded[base + 1]) << 8
                        | UInt32(padded[base + 2]) << 16
                        | UInt32(padded[base + 3]) << 24
                }
                var a = a0, b = b0, c = c0, d = d0
                for i in 0 ..< 64 {
                    var f: UInt32
                    var g: Int
                    switch i {
                    case 0 ..< 16: f = (b & c) | (~b & d); g = i
                    case 16 ..< 32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                    case 32 ..< 48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                    default: f = c ^ (b | ~d); g = (7 * i) % 16
                    }
                    f = f &+ a &+ sines[i] &+ words[g]
                    a = d; d = c; c = b
                    b = b &+ (f << shifts[i] | f >> (32 - shifts[i]))
                }
                a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
            }

            var out: [UInt8] = []
            for word in [a0, b0, c0, d0] {
                for shift in stride(from: 0, to: 32, by: 8) {
                    out.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
                }
            }
            return out
        }
    }
}
#endif
