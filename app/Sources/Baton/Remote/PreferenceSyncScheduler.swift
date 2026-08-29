import AppKit
import Foundation
import OSLog
import BatonPlaybackKit
import BatonSubsonicKit

/// Keeps the Mac's shared settings current without anyone pressing a button.
///
/// Sync existed on both devices, but only the phone ran it on its own — the Mac's single
/// caller was the "Sync now" button in Settings. So a search made on the phone, a podcast
/// subscribed there, an EQ curve adjusted there, all sat in the shared document until
/// someone happened to open Settings and press a button they had no reason to press. The
/// feature worked; it just never fired. That is indistinguishable from broken, and it was
/// reported as broken.
///
/// Three triggers, matching what the phone does:
/// - **at launch**, so opening the Mac picks up whatever the phone did since;
/// - **when the app becomes active**, which is the moment you actually switch to the Mac
///   and expect to see what you just did on the phone;
/// - **on a slow heartbeat**, for a window left open all day.
///
/// `syncIfDue` collapses these — the activation and heartbeat triggers overlap constantly,
/// and without a floor, switching apps repeatedly would hammer the gateway.
///
/// Entirely inert when no gateway is configured, which is the common case: it re-checks
/// each tick rather than giving up, so setting one up starts syncing without a relaunch.
private let clippingSyncLog = Logger(subsystem: "io.tonebox.baton", category: "Clippings")

@MainActor
final class PreferenceSyncScheduler {
    /// Long enough that an all-day window is quiet, short enough that "I searched on my
    /// phone a few minutes ago" resolves on its own.
    private static let heartbeat: TimeInterval = 600
    /// Floor between actual network calls, across all three triggers.
    private static let minimumInterval: TimeInterval = 60

    private let model: MusicModel
    private let sync = PreferenceSync(deviceName: Host.current().localizedName ?? "Mac")
    private var loop: Task<Void, Never>?
    private var activation: NSObjectProtocol?

    init(model: MusicModel) { self.model = model }

    func start() {
        guard loop == nil else { return }
        // Before the first sync, so the first merge has this device's existing clippings in it.
        // Backdated to each clipping's own creation — see `seedLedgerIfNeeded`.
        model.clippings.seedLedgerIfNeeded()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.runIfConfigured()
                try? await Task.sleep(for: .seconds(Self.heartbeat))
            }
        }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.runIfConfigured() }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
    }

    /// The gateway to talk to, or `nil` when there isn't one configured.
    ///
    /// Split out so it can be tested: an over-eager guard here is silent — the scheduler
    /// runs on time, decides there is nothing to talk to, and syncing never happens, which
    /// looks exactly like the bug this class exists to fix.
    static func gateway(urlString: String?, token: String?) -> (url: URL, token: String)? {
        let raw = (urlString ?? "").trimmingCharacters(in: .whitespaces)
        let secret = (token ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !secret.isEmpty,
              let url = URL(string: raw), url.scheme != nil, url.host != nil
        else { return nil }
        return (url, secret)
    }

    private func runIfConfigured() async {
        guard let gateway = Self.gateway(
            urlString: UserDefaults.standard.string(forKey: "baton.agent.gatewayURL"),
            token: NavidromeKeychain.secret(account: "baton.agent.gatewayToken")
        ) else { return }

        await sync.syncIfDue(gatewayURL: gateway.url, token: gateway.token,
                             minimumInterval: Self.minimumInterval)

        // A sync merges into UserDefaults; anything already read into memory can't see it.
        // Podcasts adopt their synced feeds when that screen appears, so only this one
        // needs waking here.
        model.searchRecents.reload()

        // Clippings are the other half of a merge that has to reach disk: the ledger arrives in
        // UserDefaults, but a rename or a deletion made on the phone only takes effect when the
        // sidecars and files here are brought into line with it.
        let changed = model.clippings.reconcileWithLedger()
        if changed.renamed > 0 || changed.deleted > 0 {
            clippingSyncLog.notice(
                "clippings reconciled: \(changed.renamed, privacy: .public) renamed, \(changed.deleted, privacy: .public) deleted"
            )
        }
    }
}
