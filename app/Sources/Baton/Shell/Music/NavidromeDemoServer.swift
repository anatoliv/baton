import BatonPlaybackKit
import Foundation
import BatonSubsonicKit

/// The public Navidrome demo, offered as a zero-setup way to try Baton.
///
/// Two surfaces fill it in — the first-run connect sheet and Settings → Add Server — so the
/// credentials and the "this is not us" failure message live here rather than being duplicated
/// (and drifting) between them.
///
/// This is **third-party infrastructure**: the Navidrome project runs it for their own purposes
/// and can take it down or change its sign-in without notice. Anything that fails against it must
/// say so explicitly, or the very first thing a new user clicks reads as a bug in Baton.
enum NavidromeDemoServer {
    // The address and credentials are `NavidromePublicDemo`'s, in the package, so the two
    // apps cannot disagree about which server the demo button reaches. Two copies of a URL
    // is two copies until someone changes one. What stays here is the behaviour the package
    // has no business knowing: how Baton authenticates, and what it says when this fails.
    static var urlString: String { NavidromePublicDemo.url }
    static var username: String { NavidromePublicDemo.username }
    static var password: String { NavidromePublicDemo.password }
    static let host = "demo.navidrome.org"
    static let authMode: NavidromeAuthMode = .tokenSalt

    /// Whether a URL points at the demo. Matches on **host**, so a user who edited the scheme,
    /// port, or path still gets the demo-specific failure message.
    static func matches(_ urlString: String) -> Bool {
        NavidromeConfig.validatedURL(urlString)?.host?.lowercased() == host
    }

    /// The error to show when a connection to the demo fails, keeping the underlying error as
    /// detail but leading with who actually owns the outage.
    static func failureText(detail: String) -> String {
        "Couldn't reach the public Navidrome demo. That server is run by the Navidrome project, "
            + "not by Baton, and it can be offline or change its sign-in at any time — connect "
            + "your own server to get started. (\(detail))"
    }

    /// The error to show for `urlString`: demo-specific when it targets the demo, else the raw one.
    static func errorText(forURL urlString: String, detail: String) -> String {
        matches(urlString) ? failureText(detail: detail) : detail
    }
}
