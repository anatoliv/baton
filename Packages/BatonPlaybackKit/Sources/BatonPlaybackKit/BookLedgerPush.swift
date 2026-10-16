import Foundation

/// Sends a book's place and finished mark to the other device when listening halts, not ten
/// minutes later.
///
/// The book ledger travelled only when a device synced on its own: at launch, on coming to the
/// front, or on the ten-minute heartbeat. Stop on the Mac, pick up the phone, and Play started
/// from where the book had been up to ten minutes earlier; the TBX-10974 walk measured 8 to 10
/// minutes for a handoff. So both apps now ask for a sync when the transport pauses or stops, and
/// when the app leaves the foreground.
///
/// Debounced, because those events come in bursts (a pause, then Stop, then switching away), and
/// one round trip covers them all. Not on the five-second position saves: those happen all the
/// time while a book plays, and a pause or stop always follows the last one that matters.
///
/// A push only goes when the ledger differs from what this device last sent, so pausing a song
/// costs nothing. The caller's `push` is the app's ordinary sync, which already honours
/// `BATON_DEBUG_PREFERENCE_SYNC=off` and an unconfigured gateway; it reports whether it reached
/// the gateway, and a failed push is tried again by the next event.
@MainActor
public final class BookLedgerPush {
    public static let defaultDelay: Duration = .seconds(2)

    private let delay: Duration
    private let ledger: @MainActor () -> ClippingLedger
    private let push: @MainActor () async -> Bool
    private var pending: Task<Void, Never>?
    private var lastSent: ClippingLedger?

    public init(delay: Duration = BookLedgerPush.defaultDelay,
                ledger: @escaping @MainActor () -> ClippingLedger,
                push: @escaping @MainActor () async -> Bool) {
        self.delay = delay
        self.ledger = ledger
        self.push = push
    }

    /// Whether a push is waiting out its delay.
    public var isPending: Bool { pending != nil }

    /// Push after the delay, replacing any push already waiting.
    public func schedule() {
        pending?.cancel()
        pending = Task { @MainActor [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            await self.sendIfChanged()
        }
    }

    /// Push now, taking the place of a push still waiting. For leaving the foreground on the
    /// phone, where the app holds a background task only for as long as this takes.
    public func flush() async {
        pending?.cancel()
        pending = nil
        await sendIfChanged()
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func sendIfChanged() async {
        let current = ledger()
        guard current != lastSent else { return }
        if await push() {
            // What the merge left here, so a pull that brought the other device's changes does
            // not count as something this device still has to send.
            lastSent = ledger()
        }
    }
}
