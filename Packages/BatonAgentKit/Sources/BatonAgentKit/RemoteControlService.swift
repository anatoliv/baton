// Apple-only: this file owns the router + chat bridges, which lives in BatonPlaybackKit.
// The gateway builds the same package on Linux for the agent loop alone.
#if canImport(AVFoundation)
import Foundation
import Observation
import BatonPlaybackKit
import BatonSubsonicKit
import BatonSubsonicModels

/// Owns the chat bridges: starts the ones that are configured, stops the ones
/// that aren't, and publishes their state for the Settings pane.
///
/// `apply()` is idempotent and is the single entry point — the Settings UI edits
/// `settings` and calls it, so there's one place that decides what should be
/// running rather than start/stop calls scattered across views.
@MainActor
@Observable
public final class RemoteControlService {
    public let settings: RemoteControlSettings

    private let router: RemoteCommandRouter
    private var telegram: TelegramBridge?
    private var discord: DiscordBridge?

    public init(player: StreamingPlaybackController, tools: RemoteToolSurface, focus: BatonAudioFocusRegistry, settings: RemoteControlSettings? = nil) {
        let settings = settings ?? RemoteControlSettings()
        self.settings = settings
        router = RemoteCommandRouter(player: player, tools: tools, focus: focus, settings: settings)
        // The router can speak without being spoken to (an auto-picked choice
        // lands well after its reply), but only this owns the bridges.
        router.deliver = { [weak self] reply, platform, channelID in
            await self?.push(reply, to: channelID, on: platform)
        }
        // Chat-bridge conversations go in the same log as the phone's, and the same
        // corrections come back out into the prompt. One log across every surface is the
        // point: a tally that quietly describes one of them is worse than no tally.
        router.feedbackLog = feedbackLog
        router.learning = learning
    }

    /// Shared with the app, so what you rate in Telegram and what you rate on the phone are
    /// the same record and teach the same agent.
    public let feedbackLog = FriendFeedbackLog()
    public let learning = FriendLearningStore()

    private func push(_ reply: RemoteReply, to channelID: String, on platform: RemotePlatform) async {
        switch platform {
        case .telegram: await telegram?.push(reply, to: channelID)
        case .discord: await discord?.push(reply, to: channelID)
        // Nothing to push to: the desktop conversation is synchronous, so its reply is the
        // return value of `ask`. This path is only reached by the router speaking unprompted
        // — an auto-picked choice landing after its reply — which the desktop transcript
        // cannot show retroactively. Dropping it is a known, small gap rather than a silent
        // one; see the note on `ask`.
        case .desktop: break
        }
    }

    /// Ask the music friend something from the app's own window, and get the reply back.
    ///
    /// The desktop conversation deliberately routes through the same `RemoteCommandRouter`
    /// as Telegram and Discord rather than growing a client of its own. Everything the
    /// bridges have earned comes with it: the command parser (so "pause" stays instant and
    /// free), the model fallback, the memory, the shared conversation log, and the feedback
    /// log that the Mac has been writing all along. A second implementation would be a
    /// second dialect of the same conversation, which is how the phone and the Mac drift.
    ///
    /// One known gap, stated rather than hidden: a reply the router produces *unprompted*
    /// (an auto-picked choice that resolves after the fact) has nowhere to go on the
    /// desktop, because this is a request/response call rather than a live channel. It is
    /// recorded in the conversation log either way.
    @discardableResult
    public func ask(_ text: String) async -> RemoteReply? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await router.handle(RemoteInbound(
            platform: .desktop,
            senderID: "desktop",
            senderName: "You",
            channelID: "desktop",
            text: trimmed
        ))
    }

    /// Erase every durable note about the owner. Wired to the Settings button,
    /// so leaving is as easy as arriving.
    public func forgetEverythingRemembered() {
        router.memory.forgetEverything()
    }

    /// Bring running bridges in line with the current settings.
    public func apply() {
        guard settings.isEnabled else { stopAll(); return }
        sync(.telegram)
        sync(.discord)
    }

    public func stopAll() {
        telegram?.stop(); telegram = nil
        discord?.stop(); discord = nil
        settings.state = [:]
    }

    /// Restart one platform — for the "Reconnect" button, and after a token edit
    /// (a live socket keeps using the token it authenticated with).
    public func restart(_ platform: RemotePlatform) {
        stop(platform)
        sync(platform)
    }

    // MARK: Private

    private func sync(_ platform: RemotePlatform) {
        let config = settings.config(for: platform)
        guard settings.isEnabled, config.isConfigured else { stop(platform); return }
        guard !isRunning(platform) else { return }

        let token = config.token
        let onStateChange: (RemoteConnectionState) -> Void = { [weak self] state in
            MainActor.assumeIsolated { self?.settings.state[platform] = state }
        }

        switch platform {
        // There is no bridge to start: the desktop friend is a function call from the app's
        // own window. Reached only if something iterates platforms to start them, which
        // `RemotePlatform.bridges` exists to prevent.
        case .desktop:
            return
        case .telegram:
            let bridge = TelegramBridge(token: token, router: router, onStateChange: onStateChange)
            telegram = bridge
            bridge.start()
        case .discord:
            let bridge = DiscordBridge(token: token, router: router, onStateChange: onStateChange)
            discord = bridge
            bridge.start()
        }
        remoteLog.notice("Started \(platform.rawValue, privacy: .public) bridge")
    }

    private func stop(_ platform: RemotePlatform) {
        switch platform {
        case .telegram: telegram?.stop(); telegram = nil
        case .discord: discord?.stop(); discord = nil
        // Nothing to stop; the desktop conversation holds no connection.
        case .desktop: break
        }
        settings.state[platform] = .off
    }

    private func isRunning(_ platform: RemotePlatform) -> Bool {
        switch platform {
        case .telegram: telegram != nil
        case .discord: discord != nil
        // Always available: it needs no connection to be usable, only a configured model.
        case .desktop: true
        }
    }
}
#endif
