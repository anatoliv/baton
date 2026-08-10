import Foundation
#if canImport(Network)
import Network
#endif

/// How much bandwidth to ask the server for, by the network you are on.
///
/// `NavidromeClient.streamURL(maxBitRate:)` has supported this since the client was
/// written, documented as "the per-network quality control a phone needs on cellular" —
/// and no caller ever passed it. So a phone on a train streamed a FLAC library at the
/// server's default, which is the bill and the buffering the parameter exists to avoid.
public enum StreamQuality: Int, CaseIterable, Sendable, Identifiable {
    /// No cap — the server decides, which is what has always happened.
    case original = 0
    case high = 320
    case medium = 192
    case low = 128

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .original: "Original"
        case .high: "High (320 kbps)"
        case .medium: "Medium (192 kbps)"
        case .low: "Low (128 kbps)"
        }
    }

    /// kbps to pass to the server, or nil for no cap.
    public var maxBitRate: Int? { rawValue == 0 ? nil : rawValue }

    public static let wifiKey = "baton.stream.quality.wifi"
    public static let cellularKey = "baton.stream.quality.cellular"

    /// Defaults chosen so nobody's Wi-Fi listening changes: original on Wi-Fi (today's
    /// behaviour), a sensible cap on cellular (a change, and the point of the feature).
    public static var wifi: StreamQuality {
        StreamQuality(rawValue: UserDefaults.standard.integer(forKey: wifiKey)) ?? .original
    }

    public static var cellular: StreamQuality {
        // `integer(forKey:)` returns 0 for an unset key, and 0 is `.original` — so an
        // unset cellular preference would mean "no cap", silently defeating the feature
        // for everyone who never opens Settings. Registering the default makes the
        // absent case mean `.high` instead.
        guard UserDefaults.standard.object(forKey: cellularKey) != nil else { return .high }
        return StreamQuality(rawValue: UserDefaults.standard.integer(forKey: cellularKey)) ?? .high
    }
}

extension NetworkReachability {
    /// The bitrate cap for the connection in use right now.
    ///
    /// Reuses `isMetered`, which already means "cellular, hotspot or Low Data Mode" and
    /// already drives whether the gapless prefetch runs. Adding a second path monitor for
    /// the same question would have been a second live subscription answering it slightly
    /// differently — and Low Data Mode is exactly a case where the user has asked for less
    /// traffic, so a stream cap belongs there too.
    public var streamQuality: StreamQuality { isMetered ? .cellular : .wifi }
}
