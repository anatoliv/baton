import Foundation

/// When a document waiting for the import screen may take the screen.
///
/// A document arrives from Files ("Open in"), from the share extension's inbox at activation or
/// from Clippings, and waits in `MobileModel.pendingDocumentImport` until the import screen has
/// been seen. The screen is a sheet at the root (shared with What's New, TBX-10876), and UIKit
/// will not present a sheet from a view controller that is already presenting one. With the full
/// player, an album, Settings or anything else up, the request was dropped without a word: the
/// document stayed pending, nothing showed it, and it looked lost.
///
/// So the import asks for what is in the way to close, and takes the sheet once nothing is. That
/// is the less surprising of the two choices. The person has just handed Baton a document, so
/// the import screen is what they expect to see; what closes for it (the player, a reveal,
/// Settings) is a view of state that is still there and opens again with a tap. Queued behind
/// the player instead, the document would wait out of sight until they happened to close it,
/// which looks exactly like lost. Two things are waited for rather than closed: the first-run
/// setup, a gate with no server behind it yet, and the root alerts (the queue handoff offer, a
/// link that failed), each a question one tap from answered.
///
/// Nothing is lost on the way. The pending document stays in the model until the person closes
/// the import screen; a sheet handed the import that never reached the screen (the app went to
/// the background first, or UIKit dropped it) is asked for again, on the next activation if the
/// app was away.
///
/// Pure, so the rules are tested without a screen (`ImportPresentationTests`).
struct ImportPresentation: Equatable {
    /// How long a sheet handed the import may take to appear before it is asked for again.
    static let appearanceGrace: TimeInterval = 2

    /// The world as it stands when asked.
    struct Situation: Equatable {
        var pending: URL?
        /// The app is active. Presenting from the background is how a sheet gets dropped.
        var isActive: Bool
        /// The first-run setup or a root alert is up: waited for, never closed.
        var waitsForGate: Bool
        /// Something other than the launch sheet is presented over the root.
        var otherPresentationUp: Bool
        var now: Date
    }

    enum Step: Equatable {
        /// Nothing pending, or the import screen is on screen: stop watching.
        case idle
        /// Pending, and something the import does not close is in the way; ask again soon.
        case wait
        /// Ask whatever is presented to close, then ask again.
        case closeOthers
        /// Put this import in the launch sheet.
        case show(URL)
    }

    /// The import the launch sheet has been handed.
    private(set) var shown: URL?
    /// Whether that import's screen appeared.
    private(set) var appeared = false
    private var shownAt: Date?

    mutating func step(_ situation: Situation) -> Step {
        guard let pending = situation.pending else {
            reset()
            return .idle
        }
        if shown == pending {
            if appeared { return .idle }
            // Handed over but not on screen: away from the screen, or past the grace, UIKit has
            // dropped it. Take it back so the next ask presents it afresh.
            let late = shownAt.map { situation.now.timeIntervalSince($0) > Self.appearanceGrace } ?? true
            guard !situation.isActive || late else { return .wait }
            reset()
            return .wait
        }
        guard situation.isActive, !situation.waitsForGate else {
            // A newer document than the one on screen keeps that one until it can take over.
            if shown != nil, !appeared { reset() }
            return .wait
        }
        if situation.otherPresentationUp { return .closeOthers }
        shown = pending
        appeared = false
        shownAt = situation.now
        return .show(pending)
    }

    /// The import screen for `url` is on screen.
    mutating func appeared(_ url: URL) {
        if shown == url { appeared = true }
    }

    /// What the launch sheet (`RootTabView`) holds.
    enum LaunchContent: Equatable {
        case importDocument(URL)
        case whatsNew
    }

    /// The import once it has been handed over; What's New only with no document pending, so
    /// the notes wait for the next launch rather than take the sheet a document is waiting for.
    func launchContent(pending: URL?, whatsNewWanted: Bool) -> LaunchContent? {
        if let shown { return .importDocument(shown) }
        if pending != nil { return nil }
        return whatsNewWanted ? .whatsNew : nil
    }

    /// What a launch sheet closing means.
    enum Closed: Equatable {
        /// The person closed the import screen: the document is done with.
        case endImport
        /// A sheet the app took back, or What's New making way, before the import was seen:
        /// the document stays pending and What's New's marker is left as it is.
        case keepImport
        /// The person closed What's New: mark this version's notes as seen.
        case markWhatsNewShown
        case nothing
    }

    func closed(pending: URL?, whatsNewWanted: Bool) -> Closed {
        if let pending { return shown == pending && appeared ? .endImport : .keepImport }
        return whatsNewWanted ? .markWhatsNewShown : .nothing
    }

    private mutating func reset() {
        shown = nil
        appeared = false
        shownAt = nil
    }
}
