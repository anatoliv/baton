import Foundation

/// A share link: `https://batonmusic.app/s/<id>#<key>` (spec §1).
///
/// The key is the whole fragment, so a link either carries a usable key or it does not; there is
/// no second field to get wrong. Built and parsed only here, so the app's share sheet, the deep
/// link route and the tests all agree on what a link is.
public struct ShareLink: Equatable, Sendable {
    public static let defaultBase = URL(string: "https://batonmusic.app")!
    /// Hosts whose `/s/` links are shares. The universal-link route checks against this.
    public static let hosts: Set<String> = ["batonmusic.app", "www.batonmusic.app", "baton.tonebox.io"]

    public let id: String
    public let key: Data

    public init(id: String, key: Data) {
        self.id = id
        self.key = key
    }

    /// The link to hand to a friend.
    public func url(base: URL = ShareLink.defaultBase) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/s/\(id)"
        components.fragment = Base64URL.encode(key)
        return components.url!
    }

    /// Parses a link. `nil` for anything that is not a share link with a complete key.
    ///
    /// - Parameter allowedHosts: pass `nil` to accept any host (a local test server).
    public init?(url: URL, allowedHosts: Set<String>? = ShareLink.hosts) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), components.user == nil,
              components.password == nil, components.query == nil,
              components.percentEncodedPath.hasPrefix("/s/")
        else { return nil }
        if let allowedHosts {
            guard allowedHosts.contains(host), components.scheme?.lowercased() == "https",
                  components.port == nil || components.port == 443 else { return nil }
        }
        let id = String(components.percentEncodedPath.dropFirst(3))
        guard Self.isValidID(id), let fragment = components.percentEncodedFragment,
              let key = Base64URL.decode(fragment), key.count == ShareCrypto.keyLength,
              Base64URL.encode(key) == fragment else { return nil }
        self.init(id: id, key: key)
    }

    /// A share id is 16 bytes of base64url: exactly 22 characters from that alphabet, in the
    /// one spelling that round-trips. The last character carries four unused bits, so without the
    /// round-trip check several strings would name the same id.
    public static func isValidID(_ id: String) -> Bool {
        guard id.count == 22, let bytes = Base64URL.decode(id), bytes.count == 16 else { return false }
        return Base64URL.encode(bytes) == id
    }
}
