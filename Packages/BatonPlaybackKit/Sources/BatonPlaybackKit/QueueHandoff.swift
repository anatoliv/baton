import Foundation
import Observation
import BatonSubsonicKit
import BatonSubsonicModels

/// Cross-device continuity over the Subsonic play-queue slot: the phone saves its
/// queue when playback pauses or the app backgrounds, and on launch offers to pick
/// up whatever another Baton (usually the Mac) saved — mid-track. This is the
/// ecosystem feature no competitor has a desktop counterpart for.
@MainActor
@Observable
public final class QueueHandoff {
    /// A queue found on the server at launch, offered to the user before it's adopted.
    public struct Offer {
        public var queue: NavidromePlayQueue
        public var currentTitle: String? {
            queue.songs.first { $0.id == queue.currentID }?.title ?? queue.songs.first?.title
        }
    }

    public var offer: Offer?

    @ObservationIgnored private let controller: StreamingPlaybackController
    @ObservationIgnored private let server: Server
    @ObservationIgnored private var lastSavedSignature: String?

    /// Everything this type needs from the outside world, in one injectable value.
    ///
    /// It exists because handoff had no tests at all: the queue is fetched and saved
    /// through a static client built from the active server's Keychain credentials, which
    /// no test can stand up. Two findings that turn on exactly this behaviour (the Mac
    /// never asking, and the public demo being offered strangers' queues) needed a seam
    /// they could hold.
    public struct Server: Sendable {
        public var urlString: @Sendable @MainActor () -> String
        public var isConfigured: @Sendable @MainActor () -> Bool
        public var fetchQueue: @Sendable @MainActor () async -> NavidromePlayQueue?
        public var saveQueue: @Sendable @MainActor ([String], String?, Int) async -> Void

        public init(
            urlString: @escaping @Sendable @MainActor () -> String,
            isConfigured: @escaping @Sendable @MainActor () -> Bool,
            fetchQueue: @escaping @Sendable @MainActor () async -> NavidromePlayQueue?,
            saveQueue: @escaping @Sendable @MainActor ([String], String?, Int) async -> Void
        ) {
            self.urlString = urlString
            self.isConfigured = isConfigured
            self.fetchQueue = fetchQueue
            self.saveQueue = saveQueue
        }

        /// The real server: the active Navidrome connection.
        public static let live = Server(
            urlString: { NavidromeConfig.serverURLString },
            isConfigured: { NavidromeConfig.isConfigured },
            fetchQueue: { try? await NavidromeConfig.makeClient().getPlayQueue() },
            saveQueue: { songIDs, currentID, positionMs in
                try? await NavidromeConfig.makeClient().savePlayQueue(
                    songIDs: songIDs, currentID: currentID, positionMs: positionMs
                )
            }
        )
    }

    public init(controller: StreamingPlaybackController, server: Server = .live) {
        self.controller = controller
        self.server = server
    }

    /// The `c` client name this device saves under — offers from the same name are
    /// our own snapshots and never surface (the local queue restore covers those).
    #if os(iOS)
    public static let ownClientName = "baton-ios"
    #else
    public static let ownClientName = "baton"
    #endif

    /// Whether a server URL is the public Navidrome demo, whose `demo` account is shared
    /// with the whole internet.
    ///
    /// The play-queue slot is per **account**, not per person, so on that server saving
    /// publishes your queue to strangers and an offer hands you theirs. Baton's own copy
    /// calls this cross-device continuity, which is a different promise from a shared
    /// login, and the demo is the first-run "Try the demo" target — the one server a new
    /// user is most likely to be on. Matched on host, like every other demo check, so an
    /// edited scheme, port or path is still the demo.
    public static func isSharedPublicServer(_ urlString: String) -> Bool {
        guard let host = NavidromeConfig.validatedURL(urlString)?.host?.lowercased() else { return false }
        return host == URL(string: NavidromePublicDemo.url)?.host?.lowercased()
    }

    /// Whether handoff is allowed to touch the server-side slot at all right now.
    private var mayUseServerSlot: Bool {
        server.isConfigured() && !Self.isSharedPublicServer(server.urlString())
    }

    /// Checks the server's saved queue once at launch. Only offers it when it was
    /// saved by a different client — resuming our own queue is what the local
    /// persisted snapshot already does better.
    public func checkForHandoff() async {
        guard mayUseServerSlot else { return }
        guard let saved = await server.fetchQueue(),
              !saved.songs.isEmpty,
              saved.changedBy?.lowercased() != Self.ownClientName
        else { return }
        offer = Offer(queue: saved)
    }

    /// Adopts the offered queue: rebuilds it in the engine and seeks to the saved spot.
    public func acceptOffer() {
        guard let queue = offer?.queue else { return }
        offer = nil
        let startIndex = queue.currentID.flatMap { id in queue.songs.firstIndex { $0.id == id } } ?? 0
        controller.play(queue.songs, startAt: startIndex, source: .init(label: "Continued", kind: .playlist))
        if let ms = queue.positionMs, ms > 1000 {
            controller.seek(to: TimeInterval(ms) / 1000)
        }
    }

    public func declineOffer() { offer = nil }

    /// Drops a pending handoff offer.
    ///
    /// Deliberately local-only: the queue this reads lives on the *server*, under the
    /// account being disconnected from. Deleting it would reach across into state another
    /// device still uses, so teardown forgets the offer and leaves the server alone.
    public func clear() { offer = nil }

    /// Saves the current queue server-side. Called on pause and on backgrounding —
    /// not on a timer, so the server isn't hammered during normal listening.
    public func saveNow() {
        guard mayUseServerSlot else { return }
        let songs = controller.queue
        guard !songs.isEmpty else { return }
        let current = controller.nowPlaying?.id
        let position = Int(controller.currentTime * 1000)
        // Skip a save when nothing moved — backgrounding right after pausing is common.
        let signature = "\(current ?? "-"):\(position / 5000):\(songs.count)"
        guard signature != lastSavedSignature else { return }
        lastSavedSignature = signature
        Task { [server] in
            await server.saveQueue(songs.map(\.id), current, position)
        }
    }
}
