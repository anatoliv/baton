import SwiftUI
import BatonPlaybackKit

/// The big Play button at the top of a collection: an album, artist, playlist, genre, mix
/// or folder.
///
/// It used to be `Label("Play", systemImage: "play.fill")` written out on each screen, and
/// it always called `play`: while the album played it still said "Play", and pressing it
/// started the album again from track one. Now it says what pressing it will do. Pause
/// while this collection plays, Resume while it is paused, Play otherwise, and Pause and
/// Resume act on the player in place. Which collection is "this one" is decided by
/// `CollectionPlayState`, the rule the Mac uses too.
///
/// The icon is drawn explicitly (`titleAndIcon`) so the Play button carries one just as the
/// Shuffle button beside it does, and it morphs between play and pause the way the
/// player's own control does, except under Reduce Motion.
struct CollectionPlayButton: View {
    let model: MobileModel
    let source: StreamingPlaybackController.QueueSource
    var disabled = false
    /// Starts the collection. Called only when it is not already the one in the player.
    let start: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = model.music.collectionState(source)
        Button {
            if !model.music.toggleIfLoaded(source) { start() }
        } label: {
            Label {
                Text(state.title)
            } icon: {
                Image(systemName: state.symbol)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: state)
        .disabled(disabled)
        .accessibilityLabel(state.title)
        .accessibilityIdentifier("collection-play")
    }
}

/// A context-menu Play item for a collection: Play, or Pause / Resume when it is the one in
/// the player, with the same rule as `CollectionPlayButton`.
struct CollectionPlayMenuItem: View {
    let model: MobileModel
    let source: StreamingPlaybackController.QueueSource
    let start: () -> Void

    var body: some View {
        let state = model.music.collectionState(source)
        Button(state.title, systemImage: state == .playing ? "pause" : "play") {
            if !model.music.toggleIfLoaded(source) { start() }
        }
    }
}

/// The Shuffle button beside a collection's Play, the same on every screen.
///
/// Lit only while *this* collection is the one shuffling (`isShuffling(source)`); it used to
/// light for shuffle mode alone, so every album's Shuffle glowed while some other album
/// shuffled. Pressing it while lit stops shuffling in place; otherwise it starts this
/// collection shuffled, with shuffle mode on. `songs` supplies the collection, fetching it
/// first where the screen has not loaded it.
struct CollectionShuffleButton: View {
    let model: MobileModel
    let source: StreamingPlaybackController.QueueSource
    var disabled = false
    let songs: () async -> [NavidromeSong]

    var body: some View {
        let lit = model.music.isShuffling(source)
        Button {
            if lit {
                model.music.toggleShuffle()
            } else {
                Task { model.music.playShuffled(await songs(), source: source) }
            }
        } label: {
            Label("Shuffle", systemImage: lit ? "shuffle.circle.fill" : "shuffle")
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        // A tint rather than `.borderedProminent`: that is Play's weight, and two prominent
        // buttons side by side stop saying that the primary action is Play.
        .tint(lit ? Color.accentColor : Color.secondary)
        .disabled(disabled)
        .accessibilityLabel(lit ? "Shuffle on" : "Shuffle")
        .accessibilityIdentifier("collection-shuffle")
    }
}
