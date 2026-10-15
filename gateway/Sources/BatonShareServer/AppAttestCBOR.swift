import Foundation

enum AppAttestError: Error { case invalid }

/// Definite-length CBOR only; no tags, floats, duplicate keys or unbounded containers.
indirect enum AppAttestCBOR: Equatable {
    case integer(Int64), bytes(Data), text(String), array([AppAttestCBOR]), map([AppAttestCBOR: AppAttestCBOR])
    case boolean(Bool), null

    var bytes: Data? { if case let .bytes(v) = self { v } else { nil } }
    var text: String? { if case let .text(v) = self { v } else { nil } }
    var integer: Int64? { if case let .integer(v) = self { v } else { nil } }
    var array: [Self]? { if case let .array(v) = self { v } else { nil } }
    subscript(_ key: String) -> Self? { if case let .map(v) = self { v[.text(key)] } else { nil } }
    subscript(_ key: Int64) -> Self? { if case let .map(v) = self { v[.integer(key)] } else { nil } }

    static func decode(_ data: Data) throws -> Self {
        var parser = Parser(bytes: Array(data))
        let result = try parser.value(depth: 0)
        guard parser.offset == parser.bytes.count else { throw AppAttestError.invalid }
        return result
    }
    struct Parser {
        let bytes: [UInt8]
        var offset = 0
        var nodes = 0
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - offset else { throw AppAttestError.invalid }
            defer { offset += count }
            return Data(bytes[offset..<offset + count])
        }
        mutating func value(depth: Int) throws -> SelfValue {
            nodes += 1
            guard depth < 8, nodes <= 256, bytes.count <= 65536 else { throw AppAttestError.invalid }
            let initial = try take(1).first!
            let major = initial >> 5, additional = initial & 31
            if major == 7 {
                switch additional { case 20: return .boolean(false); case 21: return .boolean(true); case 22: return .null
                default: throw AppAttestError.invalid }
            }
            let n: UInt64
            switch additional {
            case 0...23: n = UInt64(additional)
            case 24: n = UInt64(try take(1).first!)
            case 25: n = try take(2).reduce(0) { ($0 << 8) | UInt64($1) }
            case 26: n = try take(4).reduce(0) { ($0 << 8) | UInt64($1) }
            case 27: n = try take(8).reduce(0) { ($0 << 8) | UInt64($1) }
            default: throw AppAttestError.invalid
            }
            guard n <= Int64.max else { throw AppAttestError.invalid }
            switch major {
            case 0: return .integer(Int64(n))
            case 1: return .integer(-1 - Int64(n))
            case 2: return .bytes(try take(Int(n)))
            case 3:
                guard let s = String(data: try take(Int(n)), encoding: .utf8) else { throw AppAttestError.invalid }
                return .text(s)
            case 4:
                guard n <= 32 else { throw AppAttestError.invalid }
                var values: [SelfValue] = []
                for _ in 0..<Int(n) { values.append(try value(depth: depth + 1)) }
                return .array(values)
            case 5:
                guard n <= 32 else { throw AppAttestError.invalid }
                var values: [SelfValue: SelfValue] = [:]
                for _ in 0..<Int(n) {
                    let key = try value(depth: depth + 1)
                    guard key.text != nil || key.integer != nil, values[key] == nil else { throw AppAttestError.invalid }
                    values[key] = try value(depth: depth + 1)
                }
                return .map(values)
            default: throw AppAttestError.invalid
            }
        }
        typealias SelfValue = AppAttestCBOR
    }
}
extension AppAttestCBOR: Hashable {
    func hash(into hasher: inout Hasher) {
        // Only scalar text/integer values are accepted as map keys.
        switch self { case let .text(v): hasher.combine(0); hasher.combine(v)
        case let .integer(v): hasher.combine(1); hasher.combine(v)
        default: hasher.combine(2) }
    }
}
