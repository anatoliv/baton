import BatonDocuments
import BatonPlaybackKit
import SwiftUI

/// Read Along on the phone: the shared `ReadAlongPanel` for the book chapter in the
/// player, opened from the full player. It follows the player from one chapter to the next, and
/// a tapped sentence seeks there.
struct MobileReadAlongSheet: View {
    let model: MobileModel
    @Environment(\.dismiss) private var dismiss

    /// The chapter in the player, while one is.
    private var chapter: ClippingStore.Item? {
        guard let id = model.music.nowPlaying?.id, let item = model.clippings.item(forSongID: id),
              item.clipping.isBookChapter else { return nil }
        return item
    }

    var body: some View {
        NavigationStack {
            Group {
                if let chapter {
                    ReadAlongPanel(item: chapter, currentTime: model.music.currentTime,
                                   loadTiming: { await model.books.readAlongTiming(for: $0) },
                                   onSeek: { model.music.seek(to: $0) })
                } else {
                    ContentUnavailableView("No book playing", systemImage: "book.closed")
                }
            }
            .navigationTitle(chapter?.clipping.documentTitle ?? "Read Along")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The sleep timer, as in the full player this sheet covers: reading
                // along in bed is when it is wanted, and closing the text to find the moon is
                // what the owner asked not to do. The same menu and choices as everywhere else.
                if model.music.nowPlaying != nil || model.music.sleepTimerArmed {
                    ToolbarItem(placement: .topBarLeading) {
                        SleepTimerMenu(model: model) { SleepTimerLabel(model: model) }
                            .accessibilityValue(SleepTimerLabel.value(model))
                            .accessibilityIdentifier("readalong-sleep-timer")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension MobileModel {
    /// Whether the player holds a chapter of a book, which is when Read Along is offered.
    var isPlayingBookChapter: Bool {
        guard let id = music.nowPlaying?.id else { return false }
        return clippings.item(forSongID: id)?.clipping.isBookChapter == true
    }
}
