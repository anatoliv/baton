import AppIntents
import Foundation

/// Transport actions, in a file both the app and the widget extension compile.
///
/// A widget's `Button(intent:)` needs the intent *type* to exist in the widget process,
/// but an `AudioPlaybackIntent` is *performed* in the app. The intents used to live in
/// `Sources/BatonMobile`, which the widget target does not compile, so the widget could
/// not offer them at all — the only way to skip a track from the home screen was to open
/// the app and skip it there, next to a widget showing you the track.
///
/// The work itself is reached through `TransportIntentHandler`, which the app fills in at
/// launch and the widget leaves empty. That keeps this file free of the app's composition
/// root while still running against the live engine, which is the point: Siri, the widget
/// and the UI must not drift into three different ideas of what "next" means.
@MainActor
public enum TransportIntentHandler {
    public static var resume: (() -> Void)?
    public static var pause: (() -> Void)?
    public static var togglePlayPause: (() -> Void)?
    public static var next: (() -> Void)?
    public static var previous: (() -> Void)?
    public static var toggleLike: (() -> Void)?
}

public struct PlayMusicIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Play music"
    public static let description = IntentDescription("Resume playback in Baton.")
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        TransportIntentHandler.resume?()
        return .result()
    }
}

public struct PauseMusicIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Pause music"
    public static let description = IntentDescription("Pause playback in Baton.")
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        TransportIntentHandler.pause?()
        return .result()
    }
}

/// One button, not two.
///
/// A widget cannot swap which intent a button carries between timeline reloads reliably —
/// and more to the point, a play button that has become a pause button is one control in
/// every music app anyone has used.
public struct TogglePlayPauseIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Play or pause"
    public static let description = IntentDescription("Toggle playback in Baton.")
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        TransportIntentHandler.togglePlayPause?()
        return .result()
    }
}

public struct NextTrackIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Next track"
    public static let description = IntentDescription("Skip to the next track in Baton.")
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        TransportIntentHandler.next?()
        return .result()
    }
}

public struct PreviousTrackIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Previous track"
    public static let description = IntentDescription("Go back a track in Baton.")
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        TransportIntentHandler.previous?()
        return .result()
    }
}

/// Like what is playing, without looking at the screen.
///
/// The gesture people actually want from a lock screen or a widget: the song is good, say
/// so, keep walking. It is also the highest-value signal the mixes and the music friend
/// have, and until now it could only be given by opening the app.
public struct LikeCurrentTrackIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Like the current track"
    public static let description = IntentDescription("Like what Baton is playing.")
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        TransportIntentHandler.toggleLike?()
        return .result()
    }
}
