import Foundation
import Testing
@testable import Baton

/// TBX-5324: Settings → Remote and → Friend Log both read `RemoteControlService`
/// (`BatonAppDelegate.remote`) through the environment, and it used to be built inside the
/// main "Baton" window's `.task`. That meant it simply did not exist whenever that window was
/// closed at quit and restored closed — Baton keeps running from the menu bar — so both panes
/// rendered empty with nothing on screen to say why.
///
/// **Why this is checked by reading the source, not by constructing a live `BatonAppDelegate`.**
/// `RemoteControlService` and its neighbours (the MCP server, the chat bridges, preference
/// sync) touch the real Keychain, the real MCP loopback port, and the real
/// `~/Library/Application Support/Baton/*.json` files when built with their production
/// defaults — the same reason `MacFriendMemoryTests` reads `MacFriendLogView`'s source rather
/// than rendering it live. `applicationDidFinishLaunching` itself skips this whole block under
/// XCTest (`!BatonEnvironment.current.isTesting`) for exactly that reason, and it is not
/// something a test can call directly without AppKit's own launch sequence behind it (an
/// earlier attempt at this fix, building everything in `BatonApp.init()` instead, compiled but
/// crashed on launch, because `NSApp` is `nil` until AppKit assigns it — after `init()` already
/// ran). So there is no live instance in the test host to inspect. What a source read *can*
/// prove, and what regresses if someone moves the construction back into a window's `.task`,
/// is where the call sites live relative to `applicationDidFinishLaunching` and `body`.
@Suite("App composition root")
struct AppCompositionRootTests {
    /// …/app/Tests/BatonTests/ThisFile.swift → repo root
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("app/Sources/Baton/BatonApp.swift"),
            encoding: .utf8
        )
    }

    /// The slice of the file from `func applicationDidFinishLaunching` up to (not including)
    /// `func applicationWillTerminate`, which immediately follows it with nothing else in
    /// between.
    private func launchBody(_ source: String) throws -> Substring {
        guard let start = source.range(of: "func applicationDidFinishLaunching("),
              let end = source.range(of: "func applicationWillTerminate(")
        else {
            Issue.record("BatonApp.swift no longer has both applicationDidFinishLaunching and applicationWillTerminate")
            return Substring("")
        }
        #expect(start.upperBound < end.lowerBound, "applicationDidFinishLaunching should come before applicationWillTerminate")
        return source[start.upperBound..<end.lowerBound]
    }

    /// The service Settings → Remote and → Friend Log both read exists before any window can
    /// open, not after one does. Red on the code this replaced: `RemoteControlService(` lived
    /// inside a `.task` on `Window("Baton", …)`, after `var body`, never inside a launch hook
    /// that runs regardless of window state.
    @Test("RemoteControlService is built in applicationDidFinishLaunching, before any window exists")
    func remoteControlServiceBuiltAtLaunch() throws {
        let text = try source()
        let body = try launchBody(text)
        #expect(body.contains("RemoteControlService("),
                "RemoteControlService(...) should be constructed inside applicationDidFinishLaunching")
    }

    /// The MCP server and the chat bridges share one audio-focus registry so a socket suspend
    /// and an MCP resume interoperate (§7 in the surrounding comment). `RemoteControlService`
    /// depends on that same registry through `MCPToolSurface`, so `BatonMCPServer` has to be
    /// built at the same composition root, not left behind in a window's `.task` — otherwise
    /// `RemoteControlService` would need a second, unshared registry, breaking that interop.
    @Test("BatonMCPServer (the shared audio-focus registry owner) is built at launch too")
    func mcpServerBuiltAtLaunch() throws {
        let text = try source()
        let body = try launchBody(text)
        #expect(body.contains("BatonMCPServer("),
                "BatonMCPServer(...) should be constructed inside applicationDidFinishLaunching, alongside RemoteControlService")
    }

    /// The launch hook must not run under XCTest — the same guard already used for
    /// `SparkleUpdater` a few lines above `BatonApp.init()`, and for the same reason: a live
    /// MCP listener, chat bridges and a network sync scheduler are exactly the real-world side
    /// effects `BatonEnvironment` exists to keep out of the test host.
    @Test("The launch hook is gated on BatonEnvironment, not run unconditionally")
    func launchHookGatedOnTestEnvironment() throws {
        let text = try source()
        let body = try launchBody(text)
        #expect(body.contains("!BatonEnvironment.current.isTesting"),
                "the RemoteControlService/BatonMCPServer block should stay gated off under XCTest")
    }

    /// `BatonApp` has to actually wire the delegate up, or none of the above runs at all.
    @Test("BatonApp installs BatonAppDelegate via NSApplicationDelegateAdaptor")
    func appInstallsDelegate() throws {
        let text = try source()
        #expect(text.contains("@NSApplicationDelegateAdaptor(BatonAppDelegate.self)"),
                "BatonApp should install BatonAppDelegate so applicationDidFinishLaunching actually fires")
    }

    /// Regression guard for the original defect: nothing that used to live in the main
    /// window's `.task` should still be there. If this starts failing because a *different*,
    /// unrelated `.task` was legitimately added to that window later, narrow the check rather
    /// than delete it — the point is that composition-root services specifically don't belong
    /// there again.
    @Test("The main window's Window(\"Baton\", …) no longer builds RemoteControlService")
    func mainWindowNoLongerBuildsRemoteControlService() throws {
        let text = try source()
        guard let windowRange = text.range(of: "Window(\"Baton\", id: MusicWindowView.windowID)"),
              let nextWindowRange = text.range(of: "Window(\"Mini Player\"")
        else {
            Issue.record("Couldn't find the \"Baton\" window scene block to check")
            return
        }
        let windowBlock = text[windowRange.upperBound..<nextWindowRange.lowerBound]
        #expect(!windowBlock.contains("RemoteControlService("),
                "RemoteControlService(...) should not be constructed inside the main window's scene")
    }
}
