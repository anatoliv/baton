import Foundation

/// Reduces a gateway address someone typed to the root that Baton appends its own paths to.
///
/// **Why this exists.** Baton asks for two URLs on the same settings screen, and they want
/// opposite shapes:
///
/// - The **model provider** wants the API root *including* `/v1` — its own default is
///   `https://api.openai.com/v1`.
/// - The **gateway** wants the bare root, because every caller appends `v1/agent`,
///   `v1/state` or `v1/device/poll` itself.
///
/// So a perfectly reasonable person copies the shape they just used one field up, and gets
/// `…/v1/v1/agent`, a 404, and a message telling them the address "isn't a Baton gateway" —
/// which is both true and useless, because the address was very nearly right.
///
/// Being liberal about the input is the kinder half of that trade: nobody is served by a
/// convention they have to remember, and there is no gateway route where a literal `/v1`
/// segment could ever be meant as part of the root.
public enum GatewayAddress {

    /// Normalize a typed address: trim it, drop trailing slashes, and drop a trailing `/v1`.
    /// Returns `nil` when the text is not a usable absolute URL.
    public static func root(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return nil
        }
        return root(url)
    }

    /// Normalize an already-parsed address. Idempotent, so it is safe to apply at a call site
    /// whose input may already have been normalized upstream.
    public static func root(_ url: URL) -> URL {
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        // Only a *trailing* `/v1`, and only as a whole segment: a gateway genuinely hosted
        // under a path like `/baton/v1x` must survive untouched.
        if path.lowercased().hasSuffix("/v1") {
            path.removeLast(3)
        } else if path.lowercased() == "/v1" || path.lowercased() == "v1" {
            path = ""
        }
        while path.hasSuffix("/") { path.removeLast() }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.path = path
        // A query or fragment on a gateway root is always a paste artefact, never meaningful.
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    /// Whether the gateway's bearer token may be sent to `url` (TBX-1000000505 B-9).
    ///
    /// HTTPS always. Plain HTTP to a host on the home network (`isPrivate`, the caller's rule,
    /// `RemoteNaturalLanguage.isPrivate` in the apps, so there is still one copy of it) or to a
    /// name, which App Transport Security already refuses when it is public. Never plain HTTP to
    /// any other IP address: ATS lets those through, and the token would cross the internet in
    /// the clear. The device link, the book client, the pending-import relay and preference sync
    /// all ask this before they send the token; only the agent route asked before.
    public static func allowsBearer(to url: URL, isPrivate: (String) -> Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return isPrivate(host) || isTunnelOrLinkLocal(host) || !isIPLiteral(host)
    }

    /// Addresses a public network never routes, which the shared private rule does not list:
    /// Tailscale's 100.64.0.0/10 (whose traffic WireGuard already encrypts; gateway/README.md
    /// calls plain HTTP over Tailscale fine), and IPv6 unique-local fc00::/7 (Tailscale's
    /// fd7a:115c:a1e0::/48 among them) and link-local fe80::/10.
    static func isTunnelOrLinkLocal(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if bare.contains(":") {
            guard let first = bare.split(separator: ":", omittingEmptySubsequences: false).first,
                  first.count == 4, let word = UInt16(first, radix: 16) else { return false }
            return word & 0xFE00 == 0xFC00 || word & 0xFFC0 == 0xFE80
        }
        let octets = bare.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64 ... 127).contains(octets[1])
    }

    /// An IPv4 or IPv6 address rather than a name.
    static func isIPLiteral(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.contains(":") { return true }   // only an IPv6 address has a colon in its host
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
