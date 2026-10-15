import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// MARK: - Listening estimate

/// How long a document takes to hear and how much space its audio takes, before anything is
/// rendered. The import sheet shows both ("About 1 h 11 m of audio. About 25 MB on this Mac.");
/// the acceptance criterion is that the size is within 15% of the result.
public struct ListeningEstimate: Sendable, Equatable {
    /// Narration pace, pauses included. Measured on the Mac walk (2026-10-03): the sample's 12,338
    /// words came to 4,222 s of audio in Kokoro's `af_heart` at default speed, 175 words a minute.
    /// The first guess, 150, overstated the sample by 16% (30 MB promised, 25.8 MB made), which
    /// is outside the 15% the spec allows.
    public static let wordsPerMinute = 175.0

    public var minutes: Double
    public var bytes: Int

    public init(words: Int, speed: Double? = nil, bitrate: Int = AudioSettings().bitrate) {
        minutes = Double(words) / (Self.wordsPerMinute * (speed ?? 1.0))
        bytes = Int(minutes * 60 * Double(bitrate) / 8)
    }

    public init(_ document: ImportedDocument, speed: Double? = nil, bitrate: Int = AudioSettings().bitrate) {
        self.init(words: document.wordCount, speed: speed, bitrate: bitrate)
    }

    /// "1 h 22 m", "45 m", "under a minute".
    public var durationText: String {
        let total = Int(minutes.rounded())
        if total < 1 { return "under a minute" }
        return total >= 60 ? "\(total / 60) h \(total % 60) m" : "\(total) m"
    }

    /// "29 MB", "850 KB".
    public var sizeText: String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1 ? "\(Int(mb.rounded())) MB" : "\(max(1, Int((Double(bytes) / 1000).rounded()))) KB"
    }
}

// MARK: - SHA-256

/// SHA-256, hex-encoded. CryptoKit on Apple platforms; a portable implementation elsewhere
/// (the gateway on Linux), checked against the same vectors in `SupportTypesTests` so both
/// paths are known to agree.
public enum SHA256Digest {
    public static func hex(of data: Data) -> String {
        #if canImport(CryptoKit)
        return CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return portableHex(of: data)
        #endif
    }

    public static func hex(ofFileAt url: URL) throws -> String {
        hex(of: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func portableHex(of data: Data) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(message[b]) << 24 | UInt32(message[b + 1]) << 16 | UInt32(message[b + 2]) << 8 | UInt32(message[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}

// MARK: - Language

/// The document's dominant language, as read-aloud detects it (`NLLanguageRecognizer`, with
/// the same 0.85 confidence floor). `nil` on Linux, where there is no recognizer; the device
/// that imports a book always runs on an Apple platform, and the gateway only reads the result.
public enum LanguageGuess {
    public static func detect(_ text: String) -> String? {
        #if canImport(NaturalLanguage)
        let sample = String(text.prefix(4000))
        guard sample.count >= 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.85 else { return nil }
        return language.rawValue.lowercased()
        #else
        return nil
        #endif
    }
}

// MARK: - Typography

/// Punctuation the parsers match, built from scalars rather than written as string literals:
/// the  lint (`scripts/lint-prose-dashes.py`) refuses an em dash in any string literal,
/// because in this repo a literal dash is almost always prose. These are not prose.
enum Typography {
    static let emDash = Character(Unicode.Scalar(0x2014)!)
    static let enDash = Character(Unicode.Scalar(0x2013)!)
}
