import AppKit
import BatonShareKit
import BatonPlaybackKit
import SwiftUI

/// A receiver window can open even when the main music window was closed at quit.
@MainActor
final class IncomingShareWindowController: NSWindowController, NSWindowDelegate {
    private var admissionToken: UUID?
    private weak var admissionPlayback: StreamingPlaybackController?

    init(invitation: ShareInvitation, music: MusicModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Shared with you"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = IncomingSharedContent(
            invitation: invitation,
            audioSession: IncomingShareAudioSession { [weak self, weak music] callback in
                guard let self, let music else { throw ShareReceiverClient.Failure.unavailable }
                self.releaseAdmission()
                let token = music.music.observePlaybackAdmission { callback(.libraryStarting) }
                self.admissionToken = token
                self.admissionPlayback = music.music
                return { [weak self, weak playback = music.music] in
                    playback?.releasePlaybackAdmission(token)
                    if self?.admissionToken == token { self?.admissionToken = nil; self?.admissionPlayback = nil }
                }
            }, pauseLibrary: { music.internetRadio.engine.pauseForPlaybackHandoff(); music.music.pauseForPlaybackHandoff() },
            playLibrary: { song in
                music.music.play([song], source: .init(label: song.title, kind: .song, id: song.id))
            }, close: { [weak self] in self?.close() })
        // A hosting controller sizes its window to the content's ideal size, which for this
        // form is next to nothing: the window opened at 80 by 84 points, too small to see the
        // song or its Play button. The content asks for a real size, the hosting
        // controller enforces only its minimum, and the window starts at the intended size.
        let hosting = NSHostingController(rootView: content
            .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 720))
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 560, height: 720))
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    private func releaseAdmission() {
        if let token = admissionToken { admissionPlayback?.releasePlaybackAdmission(token) }
        admissionToken = nil; admissionPlayback = nil
    }
    func windowWillClose(_ notification: Notification) {
        releaseAdmission()
        window?.contentViewController = nil
    }
}

extension BatonAppDelegate {
    func presentIncomingShare(_ invitation: ShareInvitation) {
        guard let music else { return }
        incomingShareWindow?.close()
        let controller = IncomingShareWindowController(invitation: invitation, music: music)
        incomingShareWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL, let invitation = ShareInvitation(url: url) else { return false }
        // A whole-book link plays in the browser player only.
        if invitation.kind == .book { NSWorkspace.shared.open(url); return true }
        presentIncomingShare(invitation)
        return true
    }
}
