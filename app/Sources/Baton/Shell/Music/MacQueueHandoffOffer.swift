import BatonPlaybackKit
import SwiftUI

/// The Mac half of cross-device queue handoff.
///
/// The Mac has published its queue to the server's play-queue slot since handoff shipped,
/// and never once read the slot back: `checkForHandoff`, `acceptOffer` and `declineOffer`
/// were called from the phone's root view and from nowhere in `app/`. So the phone could
/// pick up the Mac's queue and the Mac could never pick up the phone's, which is half of
/// a feature whose whole point is that it works both ways.
///
/// The offer is the same two buttons the phone shows, worded the same, because a person
/// moving between the two apps is being asked one question and should be asked it once.
struct MacQueueHandoffOffer: ViewModifier {
    let model: MusicModel

    func body(content: Content) -> some View {
        content
            .task {
                // Once, when the window comes up. The engine has already restored the
                // local queue by now, so this is genuinely "and there is another one".
                guard !BatonEnvironment.current.isTesting else { return }
                await model.queueHandoff.checkForHandoff()
            }
            .alert(
                "Continue where you left off?",
                isPresented: Binding(
                    get: { model.queueHandoff.offer != nil },
                    set: { if !$0 { model.queueHandoff.declineOffer() } }
                )
            ) {
                Button("Continue") { model.queueHandoff.acceptOffer() }
                Button("Not now", role: .cancel) { model.queueHandoff.declineOffer() }
            } message: {
                if let title = model.queueHandoff.offer?.currentTitle {
                    Text("Another Baton saved a queue at \u{201C}\(title)\u{201D}.")
                }
            }
    }
}

extension View {
    /// Ask the server once whether another Baton left a queue, and offer it.
    func macQueueHandoffOffer(model: MusicModel) -> some View {
        modifier(MacQueueHandoffOffer(model: model))
    }
}
