import BatonAgentKit
import BatonSpeech
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import Testing
@testable import Baton

/// The Mac review's dead ends (`docs/reviews/2026-09-08/mac-app.md`, findings F2 to F18).
///
/// Every one of these was a screen that told the user something untrue, or a control that did
/// nothing, and every one type-checked perfectly. Several are guarded here by reading the
/// source rather than by calling code: a menu built by `Commands` and a modifier applied to a
/// `Scene` cannot be instantiated in a unit test, and the defects were both of that shape — a
/// list that had drifted from the enum it was supposed to mirror, and a modifier applied to
/// one window out of seven. `AmbientNavigationTests` set that precedent in this suite for the
/// same reason.
@MainActor
@Suite("Mac dead ends")
struct MacDeadEndTests {
    /// …/app/Tests/BatonTests/ThisFile.swift → repo root
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BatonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - F2. The Go menu covers every section

    @Test("The Go menu lists every MusicTab")
    func goMenuCoversEveryTab() {
        #expect(GoMenuCommands.sections == MusicView.MusicTab.allCases)
        // The two that were missing, named so a failure says which contract broke rather than
        // only that two arrays differ.
        #expect(GoMenuCommands.sections.contains(.clippings))
        #expect(GoMenuCommands.sections.contains(.folders))
        #expect(GoMenuCommands.sections.count == 14)
    }

    /// The list has to be *derived*, not merely correct today.
    ///
    /// `sections == allCases` passes for a hand-written list that happens to be complete, and
    /// the hand-written list was complete once too — it drifted when Clippings and Folders were
    /// added to the rail and not to the menu. So the guard is that the menu body contains no
    /// literal tab assignment other than the one Find legitimately makes.
    @Test("The Go menu is built from the enum, not hand-listed")
    func goMenuIsNotHandWritten() throws {
        let text = try source("app/Sources/Baton/App/BatonCommandRouter.swift")
        let menu = try #require(text.range(of: "struct GoMenuCommands")).lowerBound
        let body = String(text[menu...])
        // `Find…` sets `.search` on purpose: it is not a section jump, it also focuses the
        // field. Every other literal assignment would be a section the enum no longer drives.
        let assignments = body.components(separatedBy: "router.pendingTab = .")
            .dropFirst()
            .map { $0.prefix { $0.isLetter } }
        #expect(assignments.allSatisfy { $0 == "search" },
                "the Go menu assigns tabs by name again: \(assignments)")
        #expect(body.contains("MusicView.MusicTab.allCases"))
    }

    @Test("The nine numeric shortcuts are unique and on the sections they were on")
    func goMenuShortcutsAreStable() {
        let numbered = MusicView.MusicTab.allCases.filter { $0.goShortcut != nil }
        #expect(numbered.count == 9)
        let characters = numbered.compactMap { $0.goShortcut?.character }
        #expect(Set(characters).count == 9, "two sections claim the same ⌘-number")
        // The nine the menu already had, unchanged: building from `allCases` must not silently
        // move ⌘8 off History because Clippings now sorts ahead of it.
        #expect(MusicView.MusicTab.history.goShortcut?.character == "8")
        #expect(MusicView.MusicTab.later.goShortcut?.character == "9")
        #expect(MusicView.MusicTab.clippings.goShortcut == nil)
        #expect(MusicView.MusicTab.folders.goShortcut == nil)
    }

    // MARK: - F3. Every window follows the appearance setting

    /// The one window that is allowed not to: a player surface, dark by design.
    private static let chromeExempt = "MiniPlayerWindowView"

    @Test("Every window scene applies the appearance setting")
    func everySceneCarriesChrome() throws {
        let text = try source("app/Sources/Baton/BatonApp.swift")
        // Split on the scene declarations themselves, so each chunk is one scene's builder.
        let scenes = text.components(separatedBy: "\n        Window(").dropFirst()
        #expect(scenes.count >= 7, "expected to be scanning BatonApp's windows, found \(scenes.count)")

        var offenders: [String] = []
        for scene in scenes {
            let name = String(scene.prefix { $0 != ")" })
            // Stop at the next scene or the end of the body, whichever comes first.
            let block = scene.components(separatedBy: "\n        MenuBarExtra").first ?? scene
            guard !block.contains(Self.chromeExempt) else { continue }
            if !block.contains(".batonChrome()") { offenders.append(name) }
        }
        #expect(offenders.isEmpty, "windows that ignore the appearance setting: \(offenders)")
    }

    /// The gate is the first screen a new user sees, and it sat outside the branch the
    /// modifier was applied inside — so the half of the app that was wrong was the half
    /// nobody could miss.
    @Test("MusicView applies the appearance setting outside the isConfigured branch")
    func notConnectedGateFollowsTheSetting() throws {
        let text = try source("app/Sources/Baton/Shell/Music/MusicView.swift")
        let chrome = try #require(text.range(of: ".batonChrome()")).lowerBound
        let gate = try #require(text.range(of: "MusicNotConnectedView()")).lowerBound
        #expect(gate < chrome, "the modifier must sit outside (after) the else branch that draws the gate")
    }

    // MARK: - F4. A stale "no server configured" banner is cleared on connect

    @Test("Connecting a server clears a playback error left over from having none")
    func connectClearsTheStaleBanner() async throws {
        let suite = "MacDeadEnd.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let savedDefaults = NavidromeConfig.defaults
        NavidromeConfig.defaults = defaults
        NavidromeKeychain.inMemoryStore = [:]
        defer {
            NavidromeConfig.defaults = savedDefaults
            NavidromeKeychain.inMemoryStore = nil
            defaults.removePersistentDomain(forName: suite)
        }

        let model = MusicModel(environment: .testing)
        // Exactly the first-run sequence: nothing configured, so building the stream URL
        // throws `.notConfigured` and the transport parks in `.error` with the banner text.
        model.music.play([NavidromeSong(id: "s1", title: "T", artist: "A", album: nil,
                                        duration: 10, coverArtID: nil)])
        guard case let .error(message) = model.music.state else {
            Issue.record("expected the transport to be in .error, got \(model.music.state)")
            return
        }
        #expect(message.contains("No music server is configured"))

        // The discard port: a connection that is refused at once, so `loadAlbums` fails fast
        // rather than resolving a name that does not exist.
        let entry = NavidromeConfig.addServer(displayName: "Home", urlString: "http://127.0.0.1:9",
                                              username: "u", secret: "p", authMode: .tokenSalt)
        await model.selectServer(id: entry.id)

        if case .error = model.music.state {
            Issue.record("the banner survived a successful connect: \(model.music.state)")
        }
    }

    // MARK: - F8. The bearer token is masked wherever it is shown

    @Test("The client-configuration snippet hides the token unless the eye is open")
    func configSnippetIsMasked() {
        let info = AgentAccessInfo(url: "http://127.0.0.1:8765/mcp", token: "sk-live-do-not-show-me")
        let hidden = info.clientConfigSnippet(revealingToken: false)
        #expect(!hidden.contains("sk-live-do-not-show-me"))
        #expect(hidden.contains(AgentAccessInfo.maskedToken))
        // The endpoint is not a secret and must still be readable, or the block stops being
        // worth showing at all.
        #expect(hidden.contains("http://127.0.0.1:8765/mcp"))

        // Copy configuration still copies something that works.
        let shown = info.clientConfigSnippet(revealingToken: true)
        #expect(shown.contains("Bearer sk-live-do-not-show-me"))
    }

    // MARK: - F11. A never-configured speech host is not a failure

    @Test("A TTS host nobody has entered reads as unconfigured, not unreachable")
    func speechHostsStartUnconfigured() throws {
        let suite = "MacDeadEndSpeech.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let saved = SpeechConfig.defaults
        SpeechConfig.defaults = defaults
        defer {
            SpeechConfig.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }

        #expect(!SpeechConfig.hasStoredHost(for: .kokoro))
        #expect(!SpeechConfig.hasStoredHost(for: .chatterbox))
        // The placeholder is still handed out for anything that needs an address — the point
        // is only that nobody asked for it.
        #expect(SpeechConfig.kokoroBaseURL == "http://127.0.0.1:8880")

        // A host somebody typed counts, even when it is the same address as the placeholder:
        // running Kokoro on this machine is the ordinary case, and a comparison against the
        // default would call a real, working setup unconfigured.
        SpeechConfig.kokoroBaseURL = "http://127.0.0.1:8880"
        #expect(SpeechConfig.hasStoredHost(for: .kokoro))
        #expect(!SpeechConfig.hasStoredHost(for: .chatterbox))

        // Clearing the field is going back to "not set up", not a broken host.
        SpeechConfig.kokoroBaseURL = "   "
        #expect(!SpeechConfig.hasStoredHost(for: .kokoro))
    }

    // MARK: - F12. A failed deep link says so

    @Test("A failed baton:// link names the reason")
    func deepLinkFailureNamesTheReason() {
        let offline = BatonApp.deepLinkFailureText("Couldn't open that track",
                                                   error: NavidromeError.notConfigured)
        #expect(offline.hasPrefix("Couldn't open that track"))
        #expect(offline.contains("No music server is configured"),
                "the toast has to carry the diagnosis, or it is the silent failure with a noise")

        // No underlying error (an album that came back empty) still says something.
        #expect(BatonApp.deepLinkFailureText("Couldn't open that album") == "Couldn't open that album")
    }

    // MARK: - F15. Search draws no chrome before a query

    @Test("Search hides its counts and sort until a query has been submitted")
    func searchChromeWaitsForAQuery() {
        #expect(!MusicCollectionView.showsChrome(searchMode: true, submittedQuery: ""))
        // Typing is not submitting: in search mode the field runs a server query on return, so
        // the chrome must not flicker in mid-word.
        #expect(!MusicCollectionView.showsChrome(searchMode: true, submittedQuery: "   "))
        #expect(MusicCollectionView.showsChrome(searchMode: true, submittedQuery: "daft punk"))
        // Liked is not a search screen and never hides anything.
        #expect(MusicCollectionView.showsChrome(searchMode: false, submittedQuery: ""))
    }

    // MARK: - F16. Both player surfaces report a failure the same way

    @Test("The mini player reads the same error state the now-playing bar does")
    func miniPlayerHasAnErrorRow() throws {
        let bar = try source("app/Sources/Baton/Shell/Music/NowPlayingBar.swift")
        let mini = try source("app/Sources/Baton/Shell/Music/MiniPlayerWindowView.swift")
        // The identical computed property in both, so the two windows cannot disagree about
        // whether playback failed — which is exactly what they did: the bar showed the banner
        // and the mini player showed a clean, playable card at the same instant.
        let shape = "if case let .error(message) = player.state { return message }"
        #expect(bar.contains(shape))
        #expect(mini.contains(shape), "the mini player has no error row again")
        #expect(mini.contains("player.retryCurrent()"),
                "an error the user cannot act on is only half a fix")
    }

    // MARK: - F17. Everything started at launch is stopped at quit

    @Test("The preference-sync scheduler is stopped when the app terminates")
    func schedulerIsStoppedAtQuit() throws {
        let app = try source("app/Sources/Baton/BatonApp.swift")
        let teardown = try #require(app.range(of: "willTerminateNotification")).lowerBound
        let after = String(app[teardown...].prefix(600))
        #expect(after.contains("scheduler?.stop()"),
                "PreferenceSyncScheduler.stop() has no caller outside the tests again")
    }
}
