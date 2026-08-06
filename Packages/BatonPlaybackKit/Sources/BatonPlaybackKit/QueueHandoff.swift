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
    @ObservationIgnored private var lastSavedSignature: String?

    public init(controller: StreamingPlaybackController) {
        self.controller = controller
    }

    /// Checks the server's saved queue once at launch. Only offers it when it was
    /// saved by a different client — resuming our own queue is what the local
    /// persisted snapshot already does better.
    /// The `c` client name this device saves under — offers from the same name are
    /// our own snapshots and never surface (the local queue restore covers those).
    #if os(iOS)
    public static let ownClientName = "baton-ios"
    #else
    public static let ownClientName = "baton"
    #endif

    public func checkForHandoff() async {
        guard NavidromeConfig.isConfigured else { return }
        guard let saved = try? await NavidromeConfig.makeClient().getPlayQueue(),
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
        let songs = controller.queue
        guard !songs.isEmpty else { return }
        let current = controller.nowPlaying?.id
        let position = Int(controller.currentTime * 1000)
        // Skip a save when nothing moved — backgrounding right after pausing is common.
        let signature = "\(current ?? "-"):\(position / 5000):\(songs.count)"
        guard signature != lastSavedSignature else { return }
        lastSavedSignature = signature
        Task {
            try? await NavidromeConfig.makeClient().savePlayQueue(
                songIDs: songs.map(\.id), currentID: current, positionMs: position
            )
        }
    }
}
