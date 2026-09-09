import BatonPlaybackKit
import SwiftUI

/// "Scrobbling is set up" and "your plays are actually arriving" are different claims, and
/// only the phone could tell them apart. The Mac had no pending count and no manual flush,
/// so a Last.fm session revoked from a browser looked identical to a healthy one: the badge
/// said connected, every submission was refused, and the queue filled to its cap and began
/// dropping the oldest listens with nothing on screen to say so.
///
/// Same two controls the phone's scrobble settings have shown for versions, so a person
/// with both is not learning a second layout for the same answer.
struct ScrobbleQueueControls: View {
    let scrobbler: ScrobbleService

    var body: some View {
        LabeledContent("Waiting to send") {
            HStack(spacing: 10) {
                Text("\(scrobbler.pendingCount)")
                    .monospacedDigit()
                Button("Send now") { scrobbler.flushAll() }
                    .disabled(scrobbler.pendingCount == 0)
            }
        }
        Text("Plays are queued while you're offline or while a service is down, and sent when it comes back. If this number only ever grows, the account is refusing them: re-check the connection above.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
