import Foundation
import Observation
import OSLog

private let podcastCapabilityLog = Logger(subsystem: "io.tonebox.baton", category: "PodcastCapability")

/// Tracks whether the *active* Subsonic server actually implements the podcast API.
///
/// This matters because Baton's headline target — Navidrome — does **not** implement the
/// Subsonic podcast endpoints (`getPodcasts` & friends), and never has: the tracking issue
/// (navidrome/navidrome#793) has been open since 2021. On those servers `getPodcasts`
/// answers HTTP 501, so the Podcasts tab would otherwise render a scary "HTTP 501" error for
/// every Navidrome user. Servers that *do* implement it (gonic, Airsonic, Ampache, classic
/// Subsonic) keep the feature.
///
/// The store probes once per server, classifies the result, and persists it (keyed by the
/// active server id) so the nav doesn't flicker across launches. The sidebar hides the
/// Podcasts item when a server is known-unsupported; the tab itself falls back to an honest
/// "not available on this server" state for the brief window before the probe resolves.
@MainActor
@Observable
final class PodcastCapabilityStore {
    /// What we currently know about podcast support on the active server. `.unknown` covers
    /// both "haven't checked yet" and "the last check failed transiently" — in both cases the
    /// tab stays visible (we don't hide on a network blip), only `.unsupported` hides it.
    enum Support: Equatable { case unknown, supported, unsupported }

    private(set) var support: Support = .unknown

    /// The server id the current `support` value describes. When the active server changes
    /// (multi-server switch), a stale value is discarded and we re-probe.
    private var describedServerID: UUID?
    /// A probe is in flight — avoids stacking concurrent `getPodcasts` calls.
    private var probing = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Probe

    /// Resolves `support` for the active server, cheaply. Reads the persisted verdict first
    /// (no network) and only hits the server when we've never checked this one. A transient
    /// failure leaves `support` at `.unknown` and isn't persisted, so it's retried next time.
    func probeIfNeeded() async {
        guard let serverID = NavidromeConfig.activeServerID() else {
            // No server configured — nothing to probe; leave the tab visible (empty state).
            support = .unknown
            describedServerID = nil
            return
        }

        // Already resolved (non-transiently) for this exact server — nothing to do.
        if describedServerID == serverID, support != .unknown { return }

        // A prior session persisted a verdict for this server — trust it, skip the network.
        if let remembered = persisted(for: serverID) {
            support = remembered ? .supported : .unsupported
            describedServerID = serverID
            return
        }

        guard !probing, let client = try? NavidromeConfig.makeClient() else { return }
        probing = true
        defer { probing = false }

        do {
            // Channels only (no episodes) — the cheapest call that still exercises the
            // podcast route, so a supporting-but-empty server still resolves to `.supported`.
            _ = try await client.getPodcasts()
            note(.supported, for: serverID)
        } catch {
            if let verdict = Self.classify(error) {
                note(verdict, for: serverID)
            } else {
                // Transient (auth/offline/decode) — don't hide, don't remember; try again later.
                podcastCapabilityLog.debug("podcast probe inconclusive: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Fold in a verdict discovered elsewhere (e.g. the Podcasts tab's own load), so a single
    /// observed result updates both the tab and the nav without a second request.
    func record(_ verdict: Support) {
        guard verdict != .unknown, let serverID = NavidromeConfig.activeServerID() else { return }
        note(verdict, for: serverID)
    }

    private func note(_ verdict: Support, for serverID: UUID) {
        support = verdict
        describedServerID = serverID
        persist(verdict == .supported, for: serverID)
    }

    // MARK: - Classification

    /// Maps an error from a podcast request to a *durable* verdict, or `nil` when the failure
    /// is transient (auth, offline, decode) and says nothing about server support.
    ///
    /// Navidrome answers unimplemented Subsonic endpoints with **HTTP 501**; an absent route
    /// on some proxies surfaces as 404. Those are the only signals we treat as "unsupported."
    /// Subsonic *protocol* errors (`status: failed`) are deliberately left transient: a real
    /// server that reached the podcast handler and errored is worth surfacing, not silently
    /// hiding.
    static func classify(_ error: Error) -> Support? {
        guard let navidrome = error as? NavidromeError else { return nil }
        switch navidrome {
        case let .http(status) where status == 501 || status == 404:
            return .unsupported
        default:
            return nil
        }
    }

    // MARK: - Persistence

    private static func storageKey(for serverID: UUID) -> String {
        "tonebox.podcast.supported.\(serverID.uuidString)"
    }
    private static func stampKey(for serverID: UUID) -> String {
        "tonebox.podcast.supported.at.\(serverID.uuidString)"
    }
    /// Re-probe an `unsupported` verdict after this long — a server may gain podcast support
    /// later (Navidrome #793), and we shouldn't hide the tab forever. (W-36 / POD-08)
    static let unsupportedTTL: TimeInterval = 7 * 24 * 60 * 60
    /// Injectable clock for tests.
    nonisolated(unsafe) static var now: () -> Date = { Date() }

    func persisted(for serverID: UUID) -> Bool? { // internal for W-36 expiry test
        let key = Self.storageKey(for: serverID)
        guard defaults.object(forKey: key) != nil else { return nil }
        let supported = defaults.bool(forKey: key)
        if !supported {
            // Expire a stale "unsupported" so it gets re-probed.
            let stamp = defaults.double(forKey: Self.stampKey(for: serverID))
            if stamp == 0 || Self.now().timeIntervalSince1970 - stamp > Self.unsupportedTTL { return nil }
        }
        return supported
    }

    private func persist(_ supported: Bool, for serverID: UUID) {
        defaults.set(supported, forKey: Self.storageKey(for: serverID))
        defaults.set(Self.now().timeIntervalSince1970, forKey: Self.stampKey(for: serverID))
    }
}
