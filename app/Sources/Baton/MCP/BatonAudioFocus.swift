import Foundation

/// Cross-process audio-focus registry for the MCP `audio_suspend` / `audio_resume`
/// tools (§4 of the integration spec) and the Unix-socket fast-path (§7). It maps opaque
/// string handles onto the player's `StreamingPlaybackController.AudioFocusToken`, so a
/// client can suspend under an owner id and later resume with just the handle — the actual
/// owner/generation race-safety lives in the controller.
///
/// The controller is *last-writer-wins* on `currentFocus`, which already gives the
/// spec's "stacking" behaviour: a second `audio_suspend` takes focus, and releasing
/// an older (superseded) handle is a clean no-op because its token is no longer
/// `currentFocus`.
///
/// **Robustness (§4.3):** every handle remembers the connection that created it and the
/// time it was placed, so a crashed/killed client's handles can be auto-resumed — either
/// when that connection's SSE stream closes (`expireHandles(forConnection:)`) or after a
/// hard time-bound (`expireStaleHandles`). Both share the controller's generation guard, so
/// they never fight a user who has since taken over the transport.
@MainActor
final class BatonAudioFocusRegistry {
    /// A live suspend claim: the opaque handle plus the controller token it redeems.
    private struct Entry {
        let token: StreamingPlaybackController.AudioFocusToken
        /// Identifier of the connection/session that created this handle (SSE stream key or
        /// fast-path socket connection). Nil for callers that don't supply one. Used to
        /// auto-expire the handle when that connection drops.
        let connectionID: String?
        /// When the handle was placed — drives the time-bound auto-expiry.
        let createdAt: Date
        var resolved = false // set once resume has been attempted (idempotency)
    }

    private var entries: [String: Entry] = [:]

    /// A handle with no live owner auto-expires after this long (§4.3 "time-bounded").
    static let handleMaxAge: TimeInterval = 10 * 60

    /// The lowest volume an **agent-supplied** duck level may request, so `duck` always means
    /// "dim but still audible" — an agent that wants true silence must use `pause` mode, not duck
    /// to 0. The user's own configured duck level (Settings → Playback) is NOT subject to this;
    /// they may choose full silence for their own spoken summaries if they like.
    nonisolated static let agentDuckFloorPercent = 5

    /// Clamp an agent's explicit `duckToPercent` to the audible floor … 100.
    nonisolated static func clampAgentDuck(_ percent: Int) -> Int {
        max(agentDuckFloorPercent, min(percent, 100))
    }

    /// Injectable clock so tests can drive the time-bound without waiting.
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: - Suspend

    /// Acquire audio focus for `owner`. `mode` chooses pause vs. duck; `duckToPercent` is the
    /// target level for `mode == .duck` (default 20). `connectionID` associates the handle
    /// with the client that created it so it can be auto-expired on disconnect. Returns the
    /// handle plus the JSON-legible outcome (mirrors §4.4).
    func suspend(
        owner: String,
        mode: StreamingPlaybackController.AudioFocusToken.Mode = .pause,
        duckToPercent: Int = 20,
        connectionID: String? = nil,
        on music: StreamingPlaybackController
    ) -> [String: Any] {
        let previousState = stateLabel(music.state)
        let token: StreamingPlaybackController.AudioFocusToken
        switch mode {
        case .pause:
            token = music.acquireAudioFocusSuspend(owner: owner)
        case .duck:
            token = music.acquireAudioFocusDuck(owner: owner, toPercent: duckToPercent)
        }
        let handle = "af_" + BatonMCPAuth.generateToken().prefix(24)
        entries[handle] = Entry(token: token, connectionID: connectionID, createdAt: now())
        return [
            "handle": handle,
            "owner": token.owner,
            "generation": token.generation,
            "suspended": token.didSuspend,
            "mode": token.mode.rawValue,
            "previousState": previousState,
        ]
    }

    /// Back-compat convenience: pause-mode suspend with no connection association.
    func suspend(owner: String, on music: StreamingPlaybackController) -> [String: Any] {
        suspend(owner: owner, mode: .pause, connectionID: nil, on: music)
    }

    // MARK: - Resume

    /// Redeem a handle. Resumes only if this owner still holds focus, it actually
    /// suspended, and the user hasn't intervened (all enforced inside the
    /// controller). Reports a reason when it declines. Idempotent.
    func resume(handle: String, on music: StreamingPlaybackController) -> [String: Any] {
        guard var entry = entries[handle] else {
            return ["resumed": false, "reason": "nothing-to-resume"]
        }
        if entry.resolved {
            return ["resumed": false, "reason": "already-resumed"]
        }
        let outcome = release(entry.token, on: music)
        entry.resolved = true
        entries[handle] = entry
        return outcome
    }

    /// Reconstruct a token from explicit fields (the SendMessage/fast-path variant the
    /// lead described: `audio_resume` with `owner` + `generation`). Used when a client
    /// prefers to pass the token components instead of the opaque handle.
    func resume(
        owner: String,
        generation: Int,
        didSuspend: Bool,
        on music: StreamingPlaybackController
    ) -> [String: Any] {
        // Release the REAL stored token for this owner+generation, not a reconstructed
        // one: a rebuilt token defaults to `.pause`/no-previous-volume and would never
        // `==` a stored `.duck` token, so a ducked stream would never restore.
        if let match = entries.first(where: {
            !$0.value.resolved
                && $0.value.token.owner == owner
                && $0.value.token.generation == generation
        }) {
            let outcome = release(match.value.token, on: music)
            var entry = match.value
            entry.resolved = true
            entries[match.key] = entry
            return outcome
        }
        // No live entry (already resolved / unknown) — best-effort pause-mode release.
        let token = StreamingPlaybackController.AudioFocusToken(
            owner: owner, generation: generation, didSuspend: didSuspend
        )
        return release(token, on: music)
    }

    /// Shared release + outcome inference. Reads the observable state before/after the
    /// controller's `releaseAudioFocus` (whose guards are private) to report a useful reason.
    private func release(
        _ token: StreamingPlaybackController.AudioFocusToken,
        on music: StreamingPlaybackController
    ) -> [String: Any] {
        // The controller returns whether it actually resumed/restored — authoritative for
        // both modes (a duck restore isn't observable from transport state, so we can't infer
        // it ourselves). It enforces the current-holder + didSuspend + generation guards.
        let acted = music.releaseAudioFocus(token)
        if acted { return ["resumed": true] }
        // Declined. Distinguish "nothing was ever suspended" from "the user intervened".
        let reason = token.didSuspend ? "user-changed-state" : "nothing-to-resume"
        return ["resumed": false, "reason": reason]
    }

    // MARK: - Expiry (§4.3)

    /// Auto-expire every un-resolved handle created by `connectionID` — call when that
    /// client's SSE stream (or fast-path socket) closes. Each expiring handle is released
    /// through the controller, which auto-resumes/restores only if the user hasn't taken
    /// over (generation unchanged). A crashed dictation therefore can't leave Baton
    /// paused/ducked forever. Returns the number of handles expired.
    @discardableResult
    func expireHandles(forConnection connectionID: String, on music: StreamingPlaybackController) -> Int {
        expire(where: { $0.connectionID == connectionID }, on: music)
    }

    /// Auto-expire handles older than `handleMaxAge` (the time-bound in §4.3). Belt-and-braces
    /// for a client that dropped without a clean stream-close signal. Returns the count.
    @discardableResult
    func expireStaleHandles(on music: StreamingPlaybackController) -> Int {
        let cutoff = now().addingTimeInterval(-Self.handleMaxAge)
        return expire(where: { $0.createdAt < cutoff }, on: music)
    }

    private func expire(
        where predicate: (Entry) -> Bool,
        on music: StreamingPlaybackController
    ) -> Int {
        var expired = 0
        for (handle, entry) in entries where !entry.resolved && predicate(entry) {
            _ = release(entry.token, on: music)
            var e = entry
            e.resolved = true
            entries[handle] = e
            expired += 1
        }
        return expired
    }

    // MARK: - Helpers

    /// Number of live (un-resolved) handles — for tests/introspection.
    var liveHandleCount: Int { entries.values.filter { !$0.resolved }.count }

    private func stateLabel(_ state: StreamingPlaybackController.State) -> String {
        switch state {
        case .idle: "stopped"
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .error: "error"
        }
    }
}
