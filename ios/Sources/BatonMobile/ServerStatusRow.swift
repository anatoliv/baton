import BatonSubsonicKit
import SwiftUI

/// Whether the music server is actually answering, right now.
///
/// The states, the wording and the badge itself are `ServiceStatus` in `Shared/` — every
/// configurable service in both apps answers this question, and the vocabulary drifting apart
/// is how one screen ends up with a green light that means something else. What is left here
/// is the one thing specific to a Subsonic server: what to ask it.
@MainActor
@Observable
final class ServerStatus {
    private(set) var state: ServiceStatus = .unknown

    /// Pings the active server. Cheap — `verify` is one authenticated request plus a
    /// best-effort extensions probe — so it can run whenever Settings appears.
    func check() async {
        guard !StreamingPlaybackController.isOfflineMode else {
            state = .offline
            return
        }
        let url = NavidromeConfig.serverURLString
        guard !url.isEmpty else {
            state = .notConfigured("No server yet")
            return
        }

        state = .checking
        state = await ServiceStatus.probing {
            let info = try await NavidromeConfig.verify(
                urlString: url,
                username: NavidromeConfig.username,
                secret: NavidromeConfig.secret,
                authMode: NavidromeConfig.authMode
            )
            // Only claimed when the server actually advertised extensions, since that is the
            // one thing the ping proves beyond "it answered".
            return .ok(detail: info.extensions.isEmpty ? nil : "OpenSubsonic extensions available")
        }
    }
}
