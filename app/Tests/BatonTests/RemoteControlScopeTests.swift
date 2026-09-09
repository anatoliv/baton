import AppKit
@testable import BatonAgentKit
import SwiftUI
import XCTest
@testable import Baton

/// TBX-5324, second round. Building `RemoteControlService` at the composition root was
/// necessary and not sufficient. The scenes wrote `.environment(appDelegate.remote)` in the
/// scene builder, and a `Window` scene's content is a *value* built while `BatonApp.body` is
/// evaluated, which happens once, before AppKit calls `applicationDidFinishLaunching`. The
/// `nil` that was there at launch was therefore baked into the Settings window's content and
/// the property was never read again, so Settings -> Remote and -> Friend Log showed their
/// "not available" fallback for the whole run on a build whose control socket and MCP port
/// were provably live.
///
/// These tests host the same wrapper the two windows use, with a service that arrives *after*
/// the view value was built, which is the real launch order. `AppCompositionRootTests` proves
/// the service is constructed at launch; this proves it reaches the pane.
@MainActor
final class RemoteControlScopeTests: XCTestCase {
    /// A service with nothing real behind it: a testing environment, a throwaway defaults
    /// suite and an in-memory secret store, the same shape `RemoteAuthorizationTests` uses.
    private func makeService() -> RemoteControlService {
        let music = MusicModel(environment: .testing)
        return RemoteControlService(
            player: music.music,
            tools: MCPToolSurface(music: music, focus: BatonAudioFocusRegistry()),
            settings: RemoteControlSettings(
                environment: .testing,
                defaults: UserDefaults(suiteName: "baton.remote.scope.tests.\(UUID().uuidString)")!,
                secrets: InMemorySecretStore()
            )
        )
    }

    /// The pane sees the service that arrives after the view was built.
    ///
    /// Red on the code this replaced: with the environment written where the scene is built,
    /// the probe kept reading the launch-time `nil` and this failed with
    /// "the pane never saw the service".
    func testAPaneSeesTheServiceThatArrivesAfterTheViewWasBuilt() throws {
        let host = RemoteControlHost()
        let box = ProbeBox()
        // Built while `service` is still nil, exactly as the Settings scene is built before
        // `applicationDidFinishLaunching` runs.
        let view = RemoteControlScope(host: host) { RemoteServiceProbe(box: box) }

        let window = show(view)
        defer { window.orderOut(nil) }
        spin(0.2)
        XCTAssertFalse(box.sawService, "the probe should start with no service, or this test proves nothing")

        host.service = makeService()
        spin(until: { box.sawService }, seconds: 3)

        XCTAssertTrue(box.sawService, "the pane never saw the service, so Settings -> Remote would show its fallback")
    }

    /// The real Settings root, on the Remote pane, renders the form rather than the fallback
    /// sentence a user was actually seeing.
    func testSettingsRemotePaneRendersTheFormRatherThanTheFallback() throws {
        let defaults = UserDefaults(suiteName: "baton.remote.pane.tests.\(UUID().uuidString)")!
        defaults.set(BatonSettingsCategory.remote.rawValue, forKey: BatonSettingsView.selectionKey)
        let host = RemoteControlHost()
        let music = MusicModel(environment: .testing)

        let view = RemoteControlScope(host: host) {
            BatonSettingsView()
                .environment(music)
                .defaultAppStorage(defaults)
        }
        let window = show(view, title: Self.windowTitle)
        defer { window.orderOut(nil) }
        spin(0.2)

        host.service = makeService()
        spin(1.0)

        let text = try accessibilityText()
        XCTAssertFalse(
            text.contains(where: { $0.contains("isn't available right now") }),
            "Settings -> Remote is still showing its missing-service fallback; saw \(text)"
        )
        XCTAssertTrue(
            text.contains(where: { $0.contains("Drive Baton from Telegram or Discord") }),
            "Settings -> Remote did not render the remote-control form; saw \(text)"
        )
    }

    // MARK: - Probe

    /// Records what the environment handed the view, from inside a real view body.
    @MainActor
    final class ProbeBox {
        private(set) var sawService = false
        func record(_ service: RemoteControlService?) { sawService = sawService || service != nil }
    }

    private struct RemoteServiceProbe: View {
        let box: ProbeBox
        @Environment(RemoteControlService.self) private var service: RemoteControlService?

        var body: some View {
            Text(service == nil ? "no service" : "service ready")
                .onAppear { box.record(service) }
                .onChange(of: service == nil) { _, _ in box.record(service) }
        }
    }

    // MARK: - Hosting

    private static let windowTitle = "Remote control scope harness"

    /// Host `view` in an off-screen window. Ordered in because SwiftUI does no work for a
    /// window that was never brought on screen, and off the visible desktop so a test run
    /// does not flash a window over whatever the machine is doing.
    private func show(_ view: some View, title: String = windowTitle) -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        return window
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func spin(until done: () -> Bool, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Every title, description and value in the harness window's accessibility tree.
    private func accessibilityText() throws -> Set<String> {
        let application = AXUIElementCreateApplication(getpid())
        var found: Set<String> = []
        for _ in 0..<40 {
            spin(0.05)
            guard let harness = harnessWindow(in: application) else { continue }
            found = []
            collect(from: harness, into: &found, depth: 0)
            if !found.isEmpty { break }
        }
        try XCTSkipIf(found.isEmpty, "no accessibility tree was readable for this process, so the pane cannot be read here")
        return found
    }

    private func harnessWindow(in application: AXUIElement) -> AXUIElement? {
        guard let windows = copy(application, "AXWindows") as? [AXUIElement] else { return nil }
        return windows.first { copy($0, "AXTitle") as? String == Self.windowTitle }
    }

    private func collect(from element: AXUIElement, into found: inout Set<String>, depth: Int) {
        guard depth < 25 else { return }
        for attribute in ["AXTitle", "AXDescription", "AXValue"] {
            if let text = copy(element, attribute) as? String, !text.isEmpty { found.insert(text) }
        }
        guard let children = copy(element, "AXChildren") as? [AXUIElement] else { return }
        for child in children { collect(from: child, into: &found, depth: depth + 1) }
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
