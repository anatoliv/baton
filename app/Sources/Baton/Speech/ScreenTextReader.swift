import AppKit

/// Tier 0 of read-aloud: getting text out of another application, for free.
///
/// A macOS **Services** entry is the only acquisition path that costs the user nothing. The
/// system does the crossing: the frontmost app puts its selection on a pasteboard and hands it
/// over, so Baton needs no Accessibility grant, no Screen Recording grant, and no per-app code.
/// That is why it ships before the hotkey rather than after — see `specs/read-aloud.md`,
/// decision 2, where the hotkey is unbound by default precisely because this path already works.
///
/// Phase 0 measured what the two apps that matter actually vend, and it inverted the
/// expectations: Ghostty exposes a complete `AXTextArea` (selection, range, whole scrollback)
/// while Chrome's `AXWebArea` implements no `AXSelectedText` at all. Services is the path that
/// does not care about any of that.
@MainActor
final class ScreenTextReader: NSObject {

    /// Registered as `NSApp.servicesProvider` at launch. A singleton for the same reason
    /// `MacIntentServices` is: AppKit hands the callback to an object, not to a closure, and
    /// the app has exactly one composition root.
    static let shared = ScreenTextReader()

    /// What a successful capture produced. Deliberately not the *spoken* form — normalization
    /// belongs to `SpeakableText` and speaking belongs to `ReadAloudCoordinator`, so this stays
    /// a plain description of what came off the screen.
    struct Capture: Equatable {
        let text: String
        let profile: SpeakableText.SourceProfile
        /// The application the text came from, for the HUD and for per-source voices.
        let sourceName: String?
        /// Speak the gist rather than the whole thing. Set by the "Summarize with Baton"
        /// service; needs a configured model, and says so when there isn't one.
        var gist: Bool = false
    }

    /// Set by the app at launch. Kept as a hook rather than a direct call into the speech engine
    /// so this file has no opinion about what happens to the text next, and so a test can
    /// observe a capture without an audio stack.
    var onCapture: ((Capture) -> Void)?

    /// The most recent capture, kept for diagnostics and tests. Not persistence: readings are
    /// never written to disk, and this dies with the process.
    private(set) var lastCapture: Capture?

    // MARK: - The Services entry point

    /// `NSMessage` for the "Speak with Baton" service declared in Info.plist.
    ///
    /// The selector shape is fixed by AppKit. The `error` pointer is how a service reports a
    /// failure to the *sending* app, which then shows it — so the messages here are read by
    /// someone who is looking at Chrome, not at Baton, and they say what to do rather than what
    /// went wrong internally.
    @objc func speakSelection(_ pasteboard: NSPasteboard,
                              userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let raw = pasteboard.string(forType: .string), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "Select some text first, then choose Speak with Baton." as NSString
            return
        }
        capture(raw, from: NSWorkspace.shared.frontmostApplication)
    }

    /// `NSMessage` for the "Summarize with Baton" service.
    @objc func summarizeSelection(_ pasteboard: NSPasteboard,
                                  userData: String?,
                                  error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let raw = pasteboard.string(forType: .string), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "Select some text first, then choose Summarize with Baton." as NSString
            return
        }
        capture(raw, from: NSWorkspace.shared.frontmostApplication, gist: true)
    }

    // MARK: - Capture

    /// Classify the source, record the capture, and hand it on. Shared by every tier, so the
    /// hotkey path (Phase 5) arrives here too and gets identical treatment.
    func capture(_ raw: String, from application: NSRunningApplication?, gist: Bool = false) {
        let capture = Capture(
            text: raw,
            profile: Self.profile(forBundleID: application?.bundleIdentifier),
            sourceName: application?.localizedName,
            gist: gist
        )
        lastCapture = capture
        onCapture?(capture)
    }

    // MARK: - Source classification

    /// Bundle-id prefixes that identify a terminal. Matched as prefixes so
    /// `com.googlecode.iterm2` and its betas, or a Ghostty nightly, land in the same bucket.
    private static let terminalBundleIDs = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "org.alacritty",
    ]

    private static let browserBundleIDs = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",   // Arc
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
    ]

    /// Which normalizer profile a source deserves. Unknown apps get `generic`, which does the
    /// shared cleaning only — the safe answer, since a wrong profile silently drops content
    /// (the terminal pass would eat lines a text editor legitimately starts with `>`).
    static func profile(forBundleID bundleID: String?) -> SpeakableText.SourceProfile {
        guard let bundleID else { return .generic }
        if terminalBundleIDs.contains(where: { bundleID.hasPrefix($0) }) { return .terminal }
        if browserBundleIDs.contains(where: { bundleID.hasPrefix($0) }) { return .browser }
        return .generic
    }

    /// The voice category for a source, used only when per-source voices are enabled
    /// (`ReadAloudSettings.perSourceVoices`, off by default per decision 3). These names are
    /// ordinary `SpeechConfig` categories, so they resolve through the same user-editable map
    /// as `ops`, `deploy` and the rest rather than through a second lookup table.
    static func voiceCategory(for profile: SpeakableText.SourceProfile) -> String? {
        switch profile {
        case .terminal: return "terminal"
        case .browser: return "browser"
        case .generic: return nil
        }
    }
}
