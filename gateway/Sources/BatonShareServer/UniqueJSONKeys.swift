import Foundation

/// Reject ambiguous JSON objects before normal typed decoding, including escaped duplicate IDs.
struct UniqueJSONKeys {
    private let bytes: [UInt8]
    private var index = 0
    static func validate(_ data: Data) -> Bool {
        var parser = Self(bytes: Array(data))
        guard parser.value(depth: 0) else { return false }
        parser.space()
        return parser.index == parser.bytes.count
    }
    private mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    private mutating func take(_ byte: UInt8) -> Bool {
        space(); guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true
    }
    private mutating func string() -> String? {
        space(); let start = index
        guard take(34) else { return nil }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 { guard index < bytes.count else { return nil }; index += 1 }
            else if byte == 34 { return try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
        }
        return nil
    }
    private mutating func value(depth: Int) -> Bool {
        guard depth < 32 else { return false }
        space(); guard index < bytes.count else { return false }
        if bytes[index] == 123 {
            index += 1; var keys = Set<String>()
            if take(125) { return true }
            repeat {
                guard let key = string(), keys.insert(key).inserted, take(58), value(depth: depth + 1) else { return false }
                if take(125) { return true }
            } while take(44)
            return false
        }
        if bytes[index] == 91 {
            index += 1
            if take(93) { return true }
            repeat {
                guard value(depth: depth + 1) else { return false }
                if take(93) { return true }
            } while take(44)
            return false
        }
        if bytes[index] == 34 { return string() != nil }
        let start = index
        while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
        return index > start
    }
}
