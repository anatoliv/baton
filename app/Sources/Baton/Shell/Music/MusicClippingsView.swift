import BatonDocuments
import BatonPlaybackKit
import BatonSpeech
import BatonSubsonicKit
import BatonSubsonicModels
import SwiftUI

/// **Clippings** — audio Baton made and kept: a saved reading, and in time anything clipped out
/// of what is playing. Books made from documents have their own section, Books
/// (`MusicBooksView`, TBX-11018); Clippings keeps the plain readings, which play one after
/// another.
///
/// Built from `MusicBrowseHeader` and the same list rows as every other browse view, which is
/// what makes it *look and behave* like the rest rather than merely resemble it: the filter, the
/// filter history, the layout toggle, the mini transport and the sort control are all the shared
/// ones. Nothing here is a bespoke copy.
///
/// A clipping plays through the ordinary player. Its id is its file URL, which `MediaKind`
/// classifies as `.localFile` and `resolveStreamURL` resolves directly, so the transport, the
/// now-playing bar, the queue and the scrubber all work with no second playback path.
struct MusicClippingsView: View {
    @Environment(MusicModel.self) private var model

    @State private var filterText = ""
    @FocusState private var filterFocused: Bool
    @AppStorage(BrowseScreen.clipping.layoutKey) private var layout: MusicBrowseLayout = .list
    @State private var renaming: ClippingStore.Item?
    @State private var newTitle = ""
    @State private var pendingDelete: ClippingStore.Item?
    /// The kept reading whose voice is being changed.
    @State private var changingReading: ClippingStore.Item?
    private var revoicer: ClippingRevoicer { ClippingRevoicer.shared }

    private var store: ClippingStore { model.clippings }

    /// Where the "play all clippings" transport queues from, named as the other views name
    /// themselves.
    private var clippingsSource: StreamingPlaybackController.QueueSource {
        .init(label: "Clippings", kind: .liked, id: nil)
    }

    /// The readings, filtered by name, source **and text**, newest first. A book's chapters
    /// are in Books.
    ///
    /// Searching the words is the point: a clipping is the only thing in Baton that knows what is
    /// said inside it, so filtering by "the bit about notarization" finds the reading rather than
    /// requiring you to remember what you called it.
    ///
    /// Through the shared search index (M8.9), which ignores case and accents and answers a pause
    /// in typing rather than every keystroke.
    private var readings: [ClippingStore.Item] {
        search.filter(store.items)
            .filter { !$0.clipping.isBookChapter }
            .sorted { $0.clipping.createdAt > $1.clipping.createdAt }
    }

    private var search: ClippingSearch { model.clippingSearch }

    /// Only what can actually be played. A missing file in a queue is a track that stalls with no
    /// explanation, which is worse than one that is visibly unavailable in the list.
    private var playable: [NavidromeSong] { ClippingQueue.readings(readings) }

    /// The readings' size on disk; the books' is shown in Books and in Storage.
    private var totalSizeText: String {
        let bytes = store.items.filter { !$0.clipping.isBookChapter }.reduce(0) { total, item in
            total + ((try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int) ?? 0)
        }
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var hasReadings: Bool { store.items.contains { !$0.clipping.isBookChapter } }

    var body: some View {
        Group {
            if !hasReadings {
                empty
            } else {
                VStack(spacing: 0) {
                    MusicBrowseHeader(
                        title: "Clippings",
                        count: readings.count,
                        filter: $filterText,
                        filterPrompt: "Filter clippings",
                        filterFocused: $filterFocused,
                        filterHistoryKey: "clippings",
                        layout: $layout,
                        accessory: {
                            if !totalSizeText.isEmpty {
                                Text(totalSizeText).font(.caption).foregroundStyle(.secondary)
                            }
                        },
                        leading: {
                            MusicMiniTransport(
                                onPlayWhenIdle: { model.music.play(playable, source: clippingsSource) },
                                pageSource: clippingsSource,
                                onShuffleWhenIdle: { model.music.playShuffled(playable, source: clippingsSource) }
                            )
                        },
                        sortMenu: { EmptyView() }
                    )
                    list
                }
            }
        }
        .task { store.loadIfNeeded() }
        #if DEBUG
        // DEBUG only: `scripts/probe-change-voice.sh` opens Change Voice… for the
        // first kept reading with words, in place of a row's context menu. By environment, never
        // argv. A book's Change Voice is in Books.
        .task {
            guard ProcessInfo.processInfo.environment["BATON_DEBUG_OPEN_CHANGE_VOICE"] == "reading" else { return }
            for _ in 0..<240 {
                if let item = store.items.first(where: { !$0.clipping.isBookChapter && $0.clipping.text?.isEmpty == false }) {
                    changingReading = item
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        #endif
        .onChange(of: filterText, initial: true) { _, text in
            search.follow(store)
            search.setQuery(text)
        }
        .onAppear { store.reload() }
        .sheet(item: $changingReading) { item in
            ChangeVoiceSheet(target: .reading(item, store: store, revoicer: revoicer) { error in
                model.music.postToast("The reading keeps its voice: \(error)", symbol: "exclamationmark.triangle", seconds: 5)
            }) { changingReading = nil }
        }
        .alert("Rename clipping", isPresented: .init(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newTitle)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming, !newTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    // No `noteLocalChange` here on purpose. `PreferenceSync.startObservingChanges`
                    // watches UserDefaults and stamps any synced key that moves, and its own note
                    // says hand-placed calls had drifted to covering 3 of 16 keys — every setting
                    // somebody forgot to instrument silently stopped syncing. The ledger lives in
                    // UserDefaults, so the observer already has it.
                    store.rename(id: renaming.id, to: newTitle)
                }
                renaming = nil
            }
        }
        // Two outcomes, in the same words the iPhone uses. A single "Delete" had to
        // pick one of them silently, and either choice is wrong half the time: deleting only
        // here leaves it on your phone for ever, and deleting everywhere destroys a copy you may
        // have wanted to keep. Only the person knows which they mean.
        .confirmationDialog("Delete this clipping?", isPresented: .init(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Remove from This Mac", role: .destructive) {
                if let pendingDelete {
                    // Off the speakers and out of the queue before the file goes. Deleting told
                    // the player nothing, and on Darwin an open file outlives its directory
                    // entry, so a deleted clipping played on to the end of something that no
                    // longer existed.
                    model.music.dropFromQueue(ids: [pendingDelete.asSong.id])
                    store.remove(id: pendingDelete.id)
                }
                pendingDelete = nil
            }
            Button("Delete Everywhere", role: .destructive) {
                if let item = pendingDelete { deleteEverywhere(item) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Baton made this audio and there is no other copy of it. Removing it here leaves "
                 + "whatever is on your iPhone. Deleting everywhere also removes it from your "
                 + "Baton server and from your other devices.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(readings) { item in
                    row(item)
                    Divider().padding(.leading, 52)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func row(_ item: ClippingStore.Item) -> some View {
        let isCurrent = isCurrent(item)
        let isPlaying = isCurrent && model.music.isPlaying
        return HStack(spacing: 12) {
            // Bars while it plays, as on a music row; the waveform is the clipping's resting
            // icon, not a state.
            Group {
                if isPlaying {
                    NowPlayingBars(isPlaying: true)
                } else {
                    Image(systemName: item.isPresent ? "waveform" : "exclamationmark.triangle")
                        .foregroundStyle(item.isPresent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.clipping.title).lineLimit(1)
                    .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                HStack(spacing: 6) {
                    if let source = item.clipping.source, !source.isEmpty {
                        Text(source)
                    }
                    Text(item.clipping.createdAt, style: .date)
                    if let seconds = item.clipping.durationSeconds, seconds > 0 {
                        Text(Self.durationText(seconds))
                    }
                    // Said plainly rather than shown as a silent failure at play time.
                    if !item.isPresent {
                        Text("the audio file has gone").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let progress = revoicer.running[item.id] {
                    Text(Self.remakingLine(progress))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: progress.fraction).controlSize(.mini).frame(maxWidth: 240)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // The current clipping keeps its tint while paused; the bars and the accent title are
        // the extra "playing now" cue and go when it pauses, the rule every music row keeps.
        .background(isCurrent ? Color.nowPlayingRowTint() : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play(item) }
        .opacity(item.isPresent ? 1 : 0.6)
        .contextMenu {
            Button("Play") { play(item) }.disabled(!item.isPresent)
            Button("Play Next") {
                model.music.playNext([item.asSong])
            }.disabled(!item.isPresent)
            Divider()
            Button("Rename…") {
                newTitle = item.clipping.title
                renaming = item
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }.disabled(!item.isPresent)
            if revoicer.running[item.id] != nil {
                Button("Stop Making Again") { revoicer.cancel(item.id) }
            } else if item.clipping.text?.isEmpty == false {
                Button("Change Voice…") { changingReading = item }
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = item }
        }
    }

    /// Delete here, state it in the shared ledger, and remove the shared copy.
    ///
    /// The ledger write is what reaches the other device; the gateway delete is what stops it
    /// being collected afresh by a device that has never seen it. Both are needed, and the ledger
    /// is the one that must not fail silently — a gateway that is unreachable still leaves a
    /// tombstone that will be honoured the next time anything syncs.
    private func deleteEverywhere(_ item: ClippingStore.Item) {
        let digest = item.clipping.sha256
        model.music.dropFromQueue(ids: [item.asSong.id])
        store.remove(id: item.id, everywhere: true)

        guard let digest else { return }        // never travelled; nothing shared to remove
        ClippingSharedCopy.remove(digest, music: model.music)
    }

    /// Whether this clipping is the one loaded in the player, playing or paused.
    private func isCurrent(_ item: ClippingStore.Item?) -> Bool {
        item?.isLoaded(nowPlayingID: model.music.nowPlaying?.id) == true
    }

    /// Play from this clipping onwards, so the list behaves like every other list here rather
    /// than playing one item and stopping.
    /// The readings after it, never a book's chapters.
    private func play(_ item: ClippingStore.Item) {
        let songs = ClippingQueue.readings(from: item, in: readings)
        guard !songs.isEmpty else { return }
        model.music.play(songs, source: clippingsSource)
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return minutes > 0 ? "\(minutes) min \(remainder)s" : "\(remainder)s"
    }

    /// "Making again in af_sky on Kokoro… 40%", for a kept reading read again.
    static func remakingLine(_ progress: ClippingRevoicer.Progress) -> String {
        "Making again in \(BookVoiceChanges.voiceLabel(progress.voice))… \(Int((progress.fraction * 100).rounded()))%"
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No clippings yet").font(.headline)
            Text("Read something aloud, then choose File → Keep Reading in Clippings. It is kept "
                 + "here, plays like anything else, and works with no server and no network."
                 + (model.documentsSwitch.isOn ? " Books made from documents are in Books." : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Baton server's shared copy of a clipping or a book chapter, removed by its digest when
/// something is deleted everywhere. Clippings and Books both delete through it.
@MainActor
enum ClippingSharedCopy {
    static func remove(_ digest: String, music: StreamingPlaybackController) {
        let raw = (BatonStorage.defaults.string(forKey: "baton.agent.gatewayURL") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let token = (NavidromeKeychain.secret(account: "baton.agent.gatewayToken") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !token.isEmpty, let url = URL(string: raw), url.host != nil else { return }

        Task {
            do {
                try await GatewayFiles(gatewayURL: url, token: token).delete(id: digest)
            } catch {
                // Named rather than swallowed: the clipping is gone from this Mac either way,
                // and the tombstone still travels, so this is "the shared copy outlived the
                // request" rather than a failed delete.
                music.postToast("Deleted here; the shared copy is still on the Baton server",
                                symbol: "exclamationmark.triangle", seconds: 4)
            }
        }
    }
}
