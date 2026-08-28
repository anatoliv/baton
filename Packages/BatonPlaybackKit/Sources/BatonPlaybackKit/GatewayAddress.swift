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
}
