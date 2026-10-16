import BatonShareKit

/// The platform owner admits playback, delivers lifecycle events, and returns a release
/// callback. Registration happens when Play is preparing to start, never when a link opens.
@MainActor
struct IncomingShareAudioSession {
    let activate: (@escaping @MainActor (ReceivedAudioEvent) -> Void) throws -> (@MainActor () -> Void)
    static let unmanaged = IncomingShareAudioSession(activate: { _ in {} })
}
