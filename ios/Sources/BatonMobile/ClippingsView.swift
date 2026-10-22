import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import BatonSubsonicModels
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Not private: `MobileModel.deleteClippingsEverywhere` logs a gateway failure under the same
/// category, and two loggers for one subject is how their messages drift apart.
let clippingsLog = Logger(subsystem: "io.tonebox.baton", category: "Clippings")

/// **Clippings** on the phone: audio the Mac made, collected from the home gateway.
///
/// The card this came from proposed "its own small surface". That was the wrong shape and the
/// Mac proved it: a clipping's id is its own `file://` URL, which `MediaKind` calls
/// `.localFile` and `resolveStreamURL` resolves without a server, so it plays through the
/// ordinary player with the transport, the queue and the now-playing bar already attached. A
/// bespoke surface would have meant a second player path maintained forever for content that
/// needs none.
///
/// So this file is only a list. The store, the model and the playback are all shared code that
/// already existed and is already tested.
///
/// Books made from documents have their own Library section, Books (`BooksView`, TBX-11018);
/// Clippings keeps the plain readings, which play one after another.
struct ClippingsView: View {
    let model: MobileModel

    @State private var status: String?
    @State private var filter = ""

    private var store: ClippingStore { model.clippings }
    /// The readings, filtered by what is said and what they are called, through the shared
    /// search index (M8.9): case and accents are ignored, and typing is answered after a short
    /// pause. A book's chapters are in Books.
    private var readings: [ClippingStore.Item] {
        model.clippingSearch.filter(store.items).filter { !$0.clipping.isBookChapter }
    }

    private var hasReadings: Bool { store.items.contains { !$0.clipping.isBookChapter } }

    /// Only what can actually be played. A queue entry whose file has gone stalls with no
    /// explanation, which is worse than a row that visibly says it is unavailable. Readings
    /// only: a book plays as its own queue, from Books.
    private var playable: [NavidromeSong] { ClippingQueue.readings(readings) }

    private var source: StreamingPlaybackController.QueueSource {
        .init(label: "Clippings", kind: .liked, id: nil)
    }

    var body: some View {
        List {
            if !hasReadings {
                Section {
                    ContentUnavailableView(
                        "No clippings yet",
                        systemImage: "waveform.circle",
                        description: Text("On your Mac, read something aloud and choose "
                                          + "File → Keep Reading in Clippings. It arrives here "
                                          + "through your Baton server."
                                          + (model.documentsSwitch.isOn ? " Books made from documents are in Books." : ""))
                    )
                }
            } else {
                Section {
                    ForEach(readings) { item in
                        row(item)
                    }
                    .onDelete { offsets in
                        // Deliberately not a swipe-to-delete with no confirmation elsewhere in
                        // this app's idiom: a clipping is the only copy, so the alert below says
                        // so before anything is removed.
                        pendingDelete = offsets.compactMap { readings[$0].id }
                    }
                } footer: {
                    if let text = footerText { Text(text) }
                }
            }
        }
        .navigationTitle("Clippings")
        .searchable(text: $filter, prompt: "Filter clippings")
        .onChange(of: filter, initial: true) { _, text in
            model.clippingSearch.follow(store)
            model.clippingSearch.setQuery(text)
        }
        // Pulled by hand, so say what happened: a manual pull that silently achieves nothing is
        // indistinguishable from one that failed.
        .refreshable {
            if let message = await ClippingCollection.collect(model: model, announcing: true) { show(message) }
        }
        .task {
            store.loadIfNeeded()
            // Collect on open rather than on a timer. Polling is the wrong shape for a
            // local-first app, and "when you look at the screen" is both the moment you care
            // and a moment you chose.
            if let message = await ClippingCollection.collect(model: model) { show(message) }
        }
        .toolbar {
            // The sleep timer, here as well as in the full player, while something plays
            //: a run of clippings is exactly what people fall asleep to.
            if model.music.nowPlaying != nil || model.music.sleepTimerArmed {
                ToolbarItem(placement: .topBarTrailing) {
                    SleepTimerMenu(model: model) { SleepTimerLabel(model: model) }
                        .accessibilityValue(SleepTimerLabel.value(model))
                        .accessibilityIdentifier("clippings-sleep-timer")
                }
            }
            if !playable.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    // Pause / Resume while the clippings are what plays.
                    let state = model.music.collectionState(source)
                    Button {
                        if !model.music.toggleIfLoaded(source) { model.music.play(playable, source: source) }
                    } label: {
                        Image(systemName: state.symbol).contentTransition(.symbolEffect(.replace.downUp))
                    }
                        .accessibilityLabel(state == .idle ? "Play all clippings" : "\(state.title) clippings")
                }
            }
        }
        // The wording, and the choice it offers, now live in one modifier: the player's
        // long-press menu deletes a clipping too, and this dialog is the only thing telling
        // someone that one of these buttons destroys the last copy.
        .clippingDeleteConfirmation($pendingDelete, model: model) { message in show(message) }
        .overlay(alignment: .bottom) {
            if let status {
                Text(status)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: status)
    }

    @State private var pendingDelete: [String] = []

    // MARK: - Now playing

    /// Whether this clipping is the one loaded in the player, playing or paused.
    private func isCurrent(_ item: ClippingStore.Item?) -> Bool {
        item?.isLoaded(nowPlayingID: model.music.nowPlaying?.id) == true
    }

    /// Animated while it plays and still while paused, the way a music row's bars are.
    private var barsArePlaying: Bool { model.music.state == .playing }

    private var footerText: String? {
        let kept = store.items.filter { !$0.clipping.isBookChapter }
        guard !kept.isEmpty else { return nil }
        let bytes = kept.reduce(0) { total, item in
            total + ((try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int) ?? 0)
        }
        guard bytes > 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(Counted.phrase(kept.count, "clipping")), \(size). These play with no "
            + "server and no network."
    }

    @ViewBuilder
    private func row(_ item: ClippingStore.Item) -> some View {
        let current = isCurrent(item)
        Button {
            play(item)
        } label: {
            HStack(spacing: 12) {
                // Bars in place of the waveform while it is the one in the player, as a music
                // row marks its track.
                Group {
                    if current {
                        NowPlayingBars(isPlaying: barsArePlaying)
                    } else {
                        Image(systemName: item.isPresent ? "waveform" : "exclamationmark.triangle")
                            .foregroundStyle(item.isPresent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                }
                .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.clipping.title).lineLimit(1)
                        .foregroundStyle(current ? Color.accentColor : .primary)
                    HStack(spacing: 6) {
                        if let origin = item.clipping.source, !origin.isEmpty { Text(origin) }
                        Text(item.clipping.createdAt, style: .date)
                        if let seconds = item.clipping.durationSeconds, seconds > 0 {
                            Text(Self.durationText(seconds))
                        }
                        // Said plainly rather than discovered by pressing play.
                        if !item.isPresent {
                            Text("the audio file has gone").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.isPresent)
        .accessibilityValue(current ? (barsArePlaying ? "Now playing" : "Paused") : "")
    }

    /// Play from this clipping onwards, so the list behaves like every other list here. The
    /// readings after it, never a book's chapters.
    private func play(_ item: ClippingStore.Item) {
        let songs = ClippingQueue.readings(from: item, in: readings)
        guard !songs.isEmpty else { return }
        model.music.play(songs, source: source)
    }

    private func show(_ message: String) {
        status = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if status == message { status = nil }
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return minutes > 0 ? "\(minutes) min \(remainder)s" : "\(remainder)s"
    }
}

/// Collecting what the Mac kept from the gateway: kept readings, and the chapters of
/// books the Mac made. Clippings and Books both collect when they open.
@MainActor
enum ClippingCollection {
    private static var collecting = false

    /// Collect anything on the gateway this phone does not already have.
    ///
    /// Silent when no gateway is configured, which is the common case for someone who has not
    /// set one up: they should not be told about a feature they do not use. Failures say so
    /// only when the pull was asked for by hand, since an automatic collect that quietly
    /// achieves nothing is better than a banner on every visit.
    /// Returns what to tell the person, or nil for nothing worth saying. Clippings and Books
    /// both collect on open, so a second caller while one is collecting returns
    /// at once.
    static func collect(model: MobileModel, announcing announce: Bool = false) async -> String? {
        guard !collecting else { return nil }
        let store = model.clippings
        guard case let (url, token)? = model.bearerGateway() else { return nil }

        collecting = true
        defer { collecting = false }

        let files = GatewayFiles(gatewayURL: url, token: token)
        do {
            let remote = try await files.list()
            // What this phone already holds, by digest. Matching on the content hash rather than
            // on the name means the same reading collected twice is one clipping, and two
            // different readings that happen to share a title are two.
            // What this phone already holds, plus what it has deliberately thrown away. Without
            // the second set a delete undoes itself: removing a clipping takes its digest out of
            // `known`, and the next refresh downloads it straight back. See
            // `ClippingStore.dismissedDigests`.
            let known = Set(store.items.compactMap(\.clipping.sha256))
            // Two different statements, deliberately kept apart: "not on this device" and
            // "gone everywhere". Collection skips the union of both.
            let dismissed = store.dismissedDigests.union(store.ledger.removedDigests)
            let wanted = remote.filter { file in
                guard let digest = file.sha256 else { return false }
                return !known.contains(digest) && !dismissed.contains(digest)
            }
            guard !wanted.isEmpty else {
                return announce ? "Nothing new" : nil
            }

            var collected = 0
            for file in wanted {
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("clip-\(file.id).\(Self.extensionFor(file))")
                do {
                    // `download` verifies the digest and deletes the file on a mismatch, so a
                    // truncated transfer cannot become a silently short reading.
                    try await files.download(id: file.id, expecting: file.sha256, to: staged)
                    try store.adopt(staged, title: Self.title(for: file),
                                    sourceName: file.origin, sha256: file.sha256)
                    collected += 1
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    clippingsLog.error("could not collect \(file.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if collected > 0 { return "Collected \(Counted.phrase(collected, "clipping"))" }
            return announce ? "Nothing arrived" : nil
        } catch {
            clippingsLog.error("clipping collection failed: \(error.localizedDescription, privacy: .public)")
            return announce ? ((error as? LocalizedError)?.errorDescription ?? "Could not reach the Baton server") : nil
        }
    }

    /// A readable name. The gateway carries the Mac's filename, which is already
    /// "<app> <date> <time>", so it is used as-is minus the extension rather than reformatted
    /// into something that would disagree with what the Mac shows for the same clipping.
    static func title(for file: GatewayFiles.RemoteFile) -> String {
        let name = file.name
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[name.startIndex ..< dot])
    }

    /// Preserve the real extension so `ClippingStore` finds the file again after a relaunch,
    /// and so an older WAV clipping still plays.
    static func extensionFor(_ file: GatewayFiles.RemoteFile) -> String {
        if let dot = file.name.lastIndex(of: "."), dot < file.name.index(before: file.name.endIndex) {
            return String(file.name[file.name.index(after: dot)...])
        }
        return file.contentType.hasSuffix("wav") ? "wav" : "m4a"
    }
}

/// The moon, filled while a sleep timer is set, with what is left beside it: the minutes counting
/// down, or "End of chapter". Counting down by itself, so nothing here runs a clock.
/// Shared by the Clippings and Books screens.
struct SleepTimerLabel: View {
    let model: MobileModel

    var body: some View {
        let music = model.music
        HStack(spacing: 4) {
            Image(systemName: music.sleepTimerArmed ? "moon.zzz.fill" : "moon.zzz")
            if let endsAt = music.sleepTimerEndsAt {
                let now = Date()
                Text(timerInterval: now ... max(now, endsAt), countsDown: true)
                    .monospacedDigit()
                    .font(.footnote)
            } else if music.sleepAfterCurrentTrack {
                Text(SleepTimerOptions.endLabel(for: music.nowPlaying, isSpoken: music.isSpokenNowPlaying))
                    .font(.footnote)
            }
        }
        .foregroundStyle(music.sleepTimerArmed ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    /// What VoiceOver says for the moon.
    static func value(_ model: MobileModel) -> String {
        let music = model.music
        if let endsAt = music.sleepTimerEndsAt {
            let minutes = max(1, Int((endsAt.timeIntervalSinceNow / 60).rounded(.up)))
            return "Stops in \(Counted.phrase(minutes, "minute"))"
        }
        if music.sleepAfterCurrentTrack {
            return SleepTimerOptions.endLabel(for: music.nowPlaying, isSpoken: music.isSpokenNowPlaying)
        }
        return "Off"
    }
}
