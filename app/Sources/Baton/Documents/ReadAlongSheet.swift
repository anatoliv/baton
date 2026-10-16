import BatonDocuments
import BatonPlaybackKit
import SwiftUI

/// Read Along from a book in Clippings: the shared `ReadAlongPanel` for one chapter,
/// with a chapter picker. It opens on the chapter playing when this book plays, else on the
/// chapter the listener is up to, and follows the player from one chapter to the next.
///
/// Tapping a sentence in the chapter that is playing seeks there. In any other chapter it
/// starts the book there: the position is set in the shared ledger and the ordinary Play picks
/// it up, so there is no second way of starting a book.
struct ReadAlongSheet: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let book: BookShelf.Book
    /// Play the book from this chapter, at the position the ledger holds for it.
    let play: (Int) -> Void

    @State private var chapterIndex: Int?

    private var items: [ClippingStore.Item] {
        book.chapters.compactMap(\.item).filter(\.isPresent)
    }

    /// The chapter of this book now in the player, if one is.
    private var playingChapter: Int? {
        guard let id = model.music.nowPlaying?.id, let item = model.clippings.item(forSongID: id),
              item.clipping.documentID == book.documentID else { return nil }
        return item.clipping.chapterIndex
    }

    private var shownItem: ClippingStore.Item? {
        let index = chapterIndex ?? playingChapter ?? book.position?.chapterIndex
        return items.first { $0.clipping.chapterIndex == index } ?? items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.headline).lineLimit(1)
                    if let author = book.author, !author.isEmpty {
                        Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if items.count > 1, let shown = shownItem {
                    Picker("Chapter", selection: Binding(
                        get: { shown.clipping.chapterIndex ?? 0 },
                        set: { chapterIndex = $0 }
                    )) {
                        ForEach(items) { item in
                            let index = item.clipping.chapterIndex ?? 0
                            Text("\(index + 1). \(item.clipping.chapterTitle ?? item.clipping.title)").tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if let item = shownItem {
                let isPlaying = playingChapter != nil && playingChapter == item.clipping.chapterIndex
                ReadAlongPanel(
                    item: item,
                    currentTime: isPlaying ? model.music.currentTime : nil,
                    loadTiming: { await model.documents.readAlongTiming(for: $0) },
                    onSeek: { seconds in seek(item, to: seconds, isPlaying: isPlaying) }
                )
            } else {
                Text("None of this book's chapters are on this Mac.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 460, idealHeight: 640)
        // Follow the book from chapter to chapter while it plays.
        .onChange(of: playingChapter) { _, new in
            if let new { chapterIndex = new }
        }
    }

    private func seek(_ item: ClippingStore.Item, to seconds: Double, isPlaying: Bool) {
        if isPlaying {
            model.music.seek(to: seconds)
            return
        }
        guard let documentID = item.clipping.documentID, let index = item.clipping.chapterIndex else { return }
        var ledger = model.clippings.ledger
        ledger.setPosition(documentID: documentID, chapterIndex: index, seconds: seconds)
        model.clippings.ledger = ledger
        chapterIndex = index
        play(index)
    }
}

extension DocumentLibrary {
    /// A chapter's read-along timing: the copy kept with Clippings, else the one
    /// beside the render job when this Mac made the book, else the home server's.
    func readAlongTiming(for item: ClippingStore.Item) async -> ReadAlongTiming? {
        if let kept = homeServer.readAlong.load(forAudio: item.clipping.sha256) { return kept }
        if let documentID = item.clipping.documentID, let index = item.clipping.chapterIndex,
           let job = job(forDocument: documentID), job.renderer == .thisMac,
           let timing = store.chapterTiming(job.id, file: "chapter-\(index + 1).m4a") {
            // The job's timing belongs to this audio only when the job made it.
            guard let sha = item.clipping.sha256, let stored = store.load(job.id),
                  stored.chapters.indices.contains(index),
                  case let .ready(_, _, _, digest) = stored.chapters[index], digest == sha else { return nil }
            try? homeServer.readAlong.save(timing, forAudio: sha)
            return timing
        }
        return await homeServer.readAlongTiming(for: item)
    }
}
