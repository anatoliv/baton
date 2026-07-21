import Foundation
import UserNotifications

/// Posts macOS user notifications for spoken summaries with a "Play" action (mode = "notify",
/// the default). Net-new `UserNotifications` integration; the Play action routes back to the
/// `SpeechPlaybackEngine` via `SpeechNotificationDelegate`, which the app installs at launch.
///
/// Note: notification delivery requires a properly bundled/signed app. Unsigned local dev
/// builds may silently fail to authorize — `mode: "auto"` and `"banner"` do not depend on it.
///
/// Not `@MainActor`: `UNUserNotificationCenter` is thread-safe, and the constants here are
/// read from the nonisolated notification delegate.
enum SpeechNotifier {
    static let categoryID = "baton.speech.summary"
    static let playActionID = "baton.speech.play"
    /// Carried in `userInfo` so the delegate can play on tap: a temp-file path for server
    /// audio, or the raw text to speak with the built-in voice (offline fallback).
    static let fileKey = "fileURL"
    static let nativeTextKey = "nativeText"

    /// Register the "Play" action category. Call once at launch.
    static func registerCategory() {
        let play = UNNotificationAction(identifier: playActionID, title: "Play", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: categoryID, actions: [play], intentIdentifiers: [], options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Whether a notification could actually be delivered — so a caller can honestly report a
    /// fallback instead of claiming success when notifications are off. (W-43 / SPEECH-03)
    enum PostResult { case delivered, denied }

    /// Post a notification whose Play action will play `utterance` (server audio or native voice).
    /// Returns `.denied` (without posting) when notifications aren't authorized, so `speak_summary`
    /// can fall back to an in-app banner rather than silently dropping the summary.
    static func post(text: String, utterance: SpeechPlaybackEngine.Utterance) async -> PostResult {
        await requestAuthorizationIfNeeded()
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return .denied }
        let content = UNMutableNotificationContent()
        content.title = "Task complete"
        content.body = text
        content.categoryIdentifier = categoryID
        switch utterance {
        case let .file(url): content.userInfo = [fileKey: url.path]
        case let .native(t): content.userInfo = [nativeTextKey: t]
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return .delivered
        } catch {
            return .denied
        }
    }
}

/// Handles the "Play" action (and a tap on the notification body) by playing the summary
/// through the shared `SpeechPlaybackEngine`. Installed as the notification-center delegate
/// at app launch and retained for the app's lifetime.
///
/// Deliberately not `@MainActor`: `UNUserNotificationCenterDelegate` callbacks are nonisolated,
/// and `SpeechPlaybackEngine` is `Sendable` (it's `@MainActor`), so this holds it directly and
/// hops onto the main actor to drive playback.
final class SpeechNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let speech: SpeechPlaybackEngine
    init(speech: SpeechPlaybackEngine) { self.speech = speech }

    /// Show the banner even when Baton is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard action == SpeechNotifier.playActionID || action == UNNotificationDefaultActionIdentifier else { return }
        let engine = speech // bind to a Sendable local so the closure doesn't capture self
        if let path = info[SpeechNotifier.fileKey] as? String {
            let url = URL(fileURLWithPath: path)
            await MainActor.run { engine.play(fileURL: url) }
        } else if let text = info[SpeechNotifier.nativeTextKey] as? String {
            await MainActor.run { engine.speakNative(text) }
        }
    }
}
