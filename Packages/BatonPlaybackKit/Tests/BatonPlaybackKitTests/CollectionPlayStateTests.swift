import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// The shared "is this collection the one in the player" rule behind every collection Play
/// button on the Mac and the iPhone.
@MainActor
final class CollectionPlayStateTests: XCTestCase {
    typealias Source = StreamingPlaybackController.QueueSource

    private let goldberg = Source(label: "Goldberg Variations", kind: .album, id: "al-1")
    private let otherAlbum = Source(label: "Kind of Blue", kind: .album, id: "al-2")
    private let tracks: Set<String> = ["t1", "t2", "t3", "t4"]

    private func state(
        _ collection: Source, loaded: Source?, now: String? = "t1", members: Set<String>? = nil,
        player: StreamingPlaybackController.State = .playing, atEnd: Bool = false
    ) -> CollectionPlayState {
        CollectionPlayState.resolve(collection: collection, loaded: loaded, nowPlayingID: now,
                                    memberIDs: members ?? tracks, playerState: player, atEnd: atEnd)
    }

    // MARK: - The pure rule

    func testSameCollectionPlayingReadsPause() {
        XCTAssertEqual(state(goldberg, loaded: goldberg), .playing)
        XCTAssertEqual(CollectionPlayState.playing.title, "Pause")
        XCTAssertEqual(CollectionPlayState.playing.symbol, "pause.fill")
    }

    func testBufferingCountsAsPlaying() {
        XCTAssertEqual(state(goldberg, loaded: goldberg, player: .loading), .playing)
    }

    func testSameCollectionPausedReadsResume() {
        XCTAssertEqual(state(goldberg, loaded: goldberg, now: "t3", player: .paused), .paused)
        XCTAssertEqual(CollectionPlayState.paused.title, "Resume")
        XCTAssertEqual(CollectionPlayState.paused.symbol, "play.fill")
    }

    func testOtherCollectionPlayingReadsPlay() {
        XCTAssertEqual(state(goldberg, loaded: otherAlbum, now: "x1", members: ["x1"]), .idle)
        XCTAssertEqual(CollectionPlayState.idle.title, "Play")
    }

    func testNothingLoadedReadsPlay() {
        XCTAssertEqual(state(goldberg, loaded: nil, now: nil, player: .idle), .idle)
        XCTAssertEqual(state(goldberg, loaded: goldberg, now: nil, player: .idle), .idle)
    }

    /// Continuation, Play Next or Add to Queue carried the queue past the album's last
    /// track: the source is still the album, but the music is not.
    func testQueueMovedPastTheCollectionReadsPlay() {
        XCTAssertEqual(state(goldberg, loaded: goldberg, now: "similar-9"), .idle)
        XCTAssertEqual(state(goldberg, loaded: goldberg, now: "similar-9", player: .paused), .idle)
    }

    /// The album ran out and the player parked at the end of its last track: Play starts
    /// the album again rather than offering to "resume" a finished track.
    func testCollectionThatRanOutReadsPlay() {
        XCTAssertEqual(state(goldberg, loaded: goldberg, now: "t4", player: .idle, atEnd: true), .idle)
        XCTAssertEqual(state(goldberg, loaded: goldberg, now: "t4", player: .paused, atEnd: true), .idle)
    }

    /// Stop keeps the queue: that is still the album, waiting to resume.
    func testStoppedMidAlbumReadsResume() {
        XCTAssertEqual(state(goldberg, loaded: goldberg, now: "t2", player: .idle), .paused)
    }

    /// A track of the album started from search (or history, or as a single song) is not
    /// the album playing.
    func testAlbumTrackPlayedFromElsewhereIsNotTheAlbum() {
        let search = Source(label: "Search", kind: .search)
        XCTAssertEqual(state(goldberg, loaded: search, now: "t1", members: ["t1"]), .idle)
        let single = Source(label: "Variatio 4", kind: .song, id: "t1")
        XCTAssertEqual(state(goldberg, loaded: single, now: "t1", members: ["t1"]), .idle)
    }

    func testSameIdDifferentKindIsNotTheSameCollection() {
        let playlist = Source(label: "Goldberg Variations", kind: .playlist, id: "al-1")
        XCTAssertEqual(state(goldberg, loaded: playlist), .idle)
    }

    /// The label is only a display string: an album renamed or opened from a deep link
    /// ("Album") is still the same album.
    func testIdDecidesWhenPresentNotTheLabel() {
        XCTAssertEqual(state(goldberg, loaded: Source(label: "Album", kind: .album, id: "al-1")), .playing)
        XCTAssertEqual(state(goldberg, loaded: Source(label: "Goldberg Variations", kind: .album, id: nil)), .idle)
    }

    func testNoIdFallsBackToKindAndLabel() {
        let liked = Source(label: "Liked", kind: .liked)
        XCTAssertEqual(state(liked, loaded: Source(label: "Liked", kind: .liked)), .playing)
        XCTAssertEqual(state(liked, loaded: Source(label: "Liked Songs", kind: .liked)), .idle)
    }

    /// A station appends what follows by design; that is still the station playing.
    func testRadioIsOpenEnded() {
        let radio = Source(label: "Bach Radio", kind: .radio)
        XCTAssertEqual(state(radio, loaded: radio, now: "appended-7", members: ["seed"]), .playing)
    }

    /// A queue restored from a build that did not record its members: membership unknown,
    /// so the source alone decides.
    func testUnknownMembersFallBackToTheSource() {
        XCTAssertEqual(CollectionPlayState.resolve(collection: goldberg, loaded: goldberg, nowPlayingID: "t9",
                                                   memberIDs: nil, playerState: .paused, atEnd: false), .paused)
    }

    // MARK: - Through the controller

    private let suiteName = "io.tonebox.tests.collectionplaystate"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()
    private var dir: URL?

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func songs(_ ids: [String]) -> [NavidromeSong] {
        ids.map { NavidromeSong(id: $0, title: $0, artist: "Kimiko Ishizaka", album: "Goldberg Variations",
                                duration: 20, coverArtID: nil) }
    }

    private func makeController() throws -> StreamingPlaybackController {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tbx-11066-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
        let wav = dir.appendingPathComponent("tone.wav")
        try EngineTestSignals.sineWAV(frequency: 220, seconds: 20).write(to: wav)
        let c = StreamingPlaybackController(streamURLProvider: { _ in wav }, defaults: suite, systemNowPlaying: false)
        c.crossfadeSeconds = 0
        c.autoplayEnabled = false
        return c
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, _ what: String) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), what)
    }

    func testControllerTogglesInsteadOfRestarting() async throws {
        let c = try makeController()
        let album = songs(["t1", "t2", "t3", "t4"])
        c.play(album, startAt: 1, source: goldberg)
        await waitUntil({ c.state == .playing }, "album starts")
        XCTAssertEqual(c.collectionState(goldberg), .playing)
        XCTAssertEqual(c.collectionState(otherAlbum), .idle)

        XCTAssertTrue(c.toggleIfLoaded(goldberg), "loaded: the button pauses")
        XCTAssertEqual(c.state, .paused)
        XCTAssertEqual(c.collectionState(goldberg), .paused)

        XCTAssertTrue(c.toggleIfLoaded(goldberg), "paused: the button resumes")
        await waitUntil({ c.state == .playing }, "resumes")
        XCTAssertEqual(c.nowPlaying?.id, "t2", "resumed the same track, not track one")

        XCTAssertFalse(c.toggleIfLoaded(otherAlbum), "another album is not loaded: its caller starts it")
        XCTAssertEqual(c.state, .playing, "and asking did not disturb what plays")
        c.stop()
    }

    func testShuffledStartIsStillTheCollection() async throws {
        let c = try makeController()
        c.playShuffled(songs(["t1", "t2", "t3", "t4"]), source: goldberg)
        XCTAssertEqual(c.collectionState(goldberg), .playing)
        c.stop()
    }

    func testAnotherCollectionTakesOver() async throws {
        let c = try makeController()
        c.play(songs(["t1", "t2"]), source: goldberg)
        c.play(songs(["x1", "x2"]), source: otherAlbum)
        XCTAssertEqual(c.collectionState(goldberg), .idle)
        XCTAssertEqual(c.collectionState(otherAlbum), .playing)
        c.stop()
    }

    func testPlayNextOfAnotherTrackLeavesTheCollectionWhileItPlays() async throws {
        let c = try makeController()
        c.play(songs(["t1", "t2"]), source: goldberg)
        c.playNext(songs(["guest"]))
        c.next()
        XCTAssertEqual(c.nowPlaying?.id, "guest")
        XCTAssertEqual(c.collectionState(goldberg), .idle, "the inserted track is not the album")
        c.next()
        XCTAssertEqual(c.nowPlaying?.id, "t2")
        XCTAssertEqual(c.collectionState(goldberg), .playing, "back on the album's own track")
        c.stop()
    }

    func testMembersSurviveARelaunch() async throws {
        let c = try makeController()
        c.play(songs(["t1", "t2"]), source: goldberg)
        c.enqueue(songs(["later"]))
        c.pause()
        c.persistNow()
        let restored = StreamingPlaybackController(streamURLProvider: { _ in self.dir!.appendingPathComponent("tone.wav") },
                                                   defaults: suite, systemNowPlaying: false)
        restored.restoreQueue()
        XCTAssertEqual(restored.queueSourceSongIDs, ["t1", "t2"])
        XCTAssertEqual(restored.collectionState(goldberg), .paused, "restored paused on the album: Resume")
        c.stop()
        restored.stop()
    }

    func testClearingTheQueueForgetsTheCollection() async throws {
        let c = try makeController()
        c.play(songs(["t1"]), source: goldberg)
        c.clearQueue()
        XCTAssertNil(c.queueSourceSongIDs)
        XCTAssertEqual(c.collectionState(goldberg), .idle)
    }

    // MARK: - Pins

    private func pin(_ kind: PinnedItem.Kind, _ id: String, _ title: String = "Goldberg Variations") -> PinnedItem {
        PinnedItem(kind: kind, refID: id, title: title, subtitle: nil, artworkURL: nil, coverArtID: nil, pinnedAt: Date())
    }

    /// A pinned album is the album: it plays under the album's own source, so the Albums
    /// screen and Later agree on which album is playing.
    func testPinnedAlbumIsTheSameCollectionAsTheAlbum() async throws {
        let c = try makeController()
        let radio = InternetRadioStore()
        let pinned = pin(.album, "al-1")
        XCTAssertEqual(pinned.queueSource.kind, .album)
        XCTAssertTrue(pinned.queueSource.isSameCollection(as: goldberg))
        c.play(songs(["t1", "t2"]), source: goldberg)
        XCTAssertEqual(CollectionPlayState.of(pin: pinned, player: c, radio: radio), .playing)
        XCTAssertTrue(CollectionPlayState.toggleIfLoaded(pin: pinned, player: c, radio: radio))
        XCTAssertEqual(CollectionPlayState.of(pin: pin(.playlist, "al-1"), player: c, radio: radio), .idle,
                       "a playlist with the album's id is another collection")
        c.stop()
    }

    /// A pinned song is that track wherever it was started from.
    func testPinnedSongFollowsTheTrack() async throws {
        let c = try makeController()
        let radio = InternetRadioStore()
        c.play(songs(["t1", "t2"]), startAt: 1, source: goldberg)
        XCTAssertEqual(CollectionPlayState.of(pin: pin(.song, "t2", "t2"), player: c, radio: radio), .playing)
        XCTAssertEqual(CollectionPlayState.of(pin: pin(.song, "t1", "t1"), player: c, radio: radio), .idle)
        c.stop()
    }

    func testUnknownStationPinIsIdle() {
        let radio = InternetRadioStore()
        let c = StreamingPlaybackController(streamURLProvider: { _ in URL(fileURLWithPath: "/dev/null") },
                                            defaults: suite, systemNowPlaying: false)
        XCTAssertEqual(CollectionPlayState.of(pin: pin(.radioStation, "st-1", "Radio"), player: c, radio: radio), .idle)
        XCTAssertFalse(CollectionPlayState.toggleIfLoaded(pin: pin(.radioStation, "st-1", "Radio"), player: c, radio: radio))
    }
}

/// Play starts in order, Shuffle starts shuffled.
@MainActor
final class PlayAndShuffleRuleTests: XCTestCase {
    typealias Source = StreamingPlaybackController.QueueSource
    private let suiteName = "io.tonebox.tests.playshufflerule"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()
    private let album = Source(label: "Album", kind: .album, id: "al-1")
    private let other = Source(label: "Other", kind: .album, id: "al-2")

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// No stream URL, so nothing actually plays; the rule is about queue order and mode.
    private func controller() -> StreamingPlaybackController {
        StreamingPlaybackController(streamURLProvider: { _ in URL(fileURLWithPath: "/dev/null") },
                                    defaults: suite, systemNowPlaying: false)
    }

    private func songs(_ prefix: String, _ n: Int) -> [NavidromeSong] {
        (0 ..< n).map { NavidromeSong(id: "\(prefix)\($0)", title: "\(prefix) \($0)") }
    }

    func testPlayAfterShuffleStartsInOrderWithShuffleOff() {
        let c = controller()
        c.playShuffled(songs("a", 10), source: album)
        XCTAssertTrue(c.isShuffled)
        let list = songs("b", 6)
        c.play(list, source: other)
        XCTAssertFalse(c.isShuffled, "Play starts in order: the transport must not read Shuffle on")
        XCTAssertEqual(c.queue.map(\.id), list.map(\.id))
        XCTAssertFalse(suite.bool(forKey: StreamingPlaybackController.shuffleKey), "and the setting says so")
    }

    func testPlayedTrackRowStartsInOrderToo() {
        let c = controller()
        c.toggleShuffle()   // shuffle switched on from the transport, nothing queued
        let list = songs("a", 5)
        c.play(list, startAt: 2, source: album)
        XCTAssertFalse(c.isShuffled)
        XCTAssertEqual(c.queue.map(\.id), list.map(\.id))
        XCTAssertEqual(c.nowPlaying?.id, "a2")
    }

    /// Un-shuffling a shuffled start puts the collection back in its own order, around the
    /// current track; it used to restore the shuffled list itself.
    func testUnshufflingAShuffledStartRestoresTheCollectionOrder() {
        let c = controller()
        let list = songs("a", 12)
        c.playShuffled(list, source: album)
        XCTAssertEqual(Set(c.queue.map(\.id)), Set(list.map(\.id)))
        let current = c.nowPlaying?.id
        c.toggleShuffle()
        XCTAssertFalse(c.isShuffled)
        XCTAssertEqual(c.queue.map(\.id), list.map(\.id))
        XCTAssertEqual(c.nowPlaying?.id, current, "the music keeps going")
    }

    func testShuffleButtonLightsOnlyForTheShufflingCollection() {
        let c = controller()
        c.playShuffled(songs("a", 6), source: album)
        XCTAssertTrue(c.isShuffling(album))
        XCTAssertFalse(c.isShuffling(other))
        c.play(songs("a", 6), source: album)
        XCTAssertFalse(c.isShuffling(album), "played in order: not shuffling")
    }

    func testShuffleButtonOnAnotherCollectionStartsItShuffled() {
        let c = controller()
        c.playShuffleToggling(songs("a", 6), source: album)
        let list = songs("b", 20)
        c.playShuffleToggling(list, source: other)
        XCTAssertTrue(c.isShuffled)
        XCTAssertTrue(c.isShuffling(other))
        XCTAssertNotEqual(c.queue.map(\.id), list.map(\.id), "twenty tracks in their own order would be a 1 in 20! chance")
    }

    func testShuffleButtonSecondPressStopsInPlace() {
        let c = controller()
        let list = songs("a", 8)
        c.playShuffleToggling(list, source: album)
        c.next(); c.next()
        let current = c.nowPlaying?.id
        c.playShuffleToggling(list, source: album)
        XCTAssertFalse(c.isShuffled)
        XCTAssertEqual(c.nowPlaying?.id, current)
        XCTAssertEqual(c.queue.map(\.id), list.map(\.id))
    }
}

/// Adding to the queue and taking a handed-off queue are not fresh starts.
@MainActor
final class QueueAddAndAdoptTests: XCTestCase {
    typealias Source = StreamingPlaybackController.QueueSource
    private let suiteName = "io.tonebox.tests.queueaddadopt"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()
    private let album = Source(label: "Album", kind: .album, id: "al-1")

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func controller() -> StreamingPlaybackController {
        StreamingPlaybackController(streamURLProvider: { _ in URL(fileURLWithPath: "/dev/null") },
                                    defaults: suite, systemNowPlaying: false)
    }

    private func songs(_ prefix: String, _ n: Int) -> [NavidromeSong] {
        (0 ..< n).map { NavidromeSong(id: "\(prefix)\($0)", title: "\(prefix) \($0)") }
    }

    func testEnqueueKeepsShuffleSourceMembersAndTheUnshuffleOrder() {
        let c = controller()
        let tracks = songs("t", 8)
        c.playShuffled(tracks, source: album)
        c.enqueue(songs("x", 2))
        c.playNext(songs("n", 1))
        XCTAssertTrue(c.isShuffled)
        XCTAssertEqual(c.queueSource, album)
        XCTAssertEqual(c.queueSourceSongIDs, Set(tracks.map(\.id)))
        XCTAssertEqual(c.queue.count, 11)
        let current = c.nowPlaying?.id
        c.toggleShuffle()
        XCTAssertEqual(c.queue.count, 11, "turning shuffle off keeps the added songs")
        XCTAssertEqual(c.queue.suffix(2).map(\.id), ["x0", "x1"], "appended songs stay at the end")
        XCTAssertEqual(c.nowPlaying?.id, current)
        let i = c.queue.firstIndex { $0.id == current }!
        XCTAssertEqual(c.queue[i + 1].id, "n0", "Play Next stays right after the current track")
    }

    func testAHandedOffQueueKeepsTheListenersShuffleModeAndTheSendersOrder() {
        let c = controller()
        c.toggleShuffle()                                   // this device has shuffle on
        let sent = songs("s", 6)
        c.play(sent, startAt: 2, source: .init(label: "Continued", kind: .playlist), keepingShuffleMode: true)
        XCTAssertTrue(c.isShuffled, "a handoff does not switch shuffle off")
        XCTAssertEqual(c.queue.map(\.id), sent.map(\.id), "in the order the sender was playing")
        XCTAssertEqual(c.nowPlaying?.id, "s2")
        XCTAssertEqual(c.queueSourceSongIDs, Set(sent.map(\.id)))
    }
}

/// Removing, inserting and reordering while shuffled are kept in the order shuffle returns
/// to, by position, so a song queued twice is handled as the copy it is.
@MainActor
final class ShuffleRestoreOrderTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.shufflerestore"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func controller() -> StreamingPlaybackController {
        StreamingPlaybackController(streamURLProvider: { _ in URL(fileURLWithPath: "/dev/null") },
                                    defaults: suite, systemNowPlaying: false)
    }

    private func songs(_ ids: [String]) -> [NavidromeSong] { ids.map { NavidromeSong(id: $0, title: $0) } }

    func testATrackRemovedWhileShuffledStaysRemovedAfterUnshuffling() {
        let c = controller()
        c.playShuffled(songs(["a", "b", "c", "d", "e", "f"]))
        let current = c.nowPlaying?.id
        let victim = c.queue.indices.first { $0 != c.currentIndex }!
        let removedID = c.queue[victim].id
        c.removeFromQueue(at: IndexSet(integer: victim))
        c.toggleShuffle()
        XCTAssertEqual(c.queue.map(\.id), ["a", "b", "c", "d", "e", "f"].filter { $0 != removedID })
        XCTAssertEqual(c.nowPlaying?.id, current)
    }

    func testRemovingTheEarlierCopyOfARepeatedSongKeepsTheOneThatPlays() {
        let c = controller()
        c.play(songs(["a", "b", "a", "c"]), startAt: 2)     // the second "a" plays
        c.toggleShuffle()                                   // it moves to the front
        let firstA = c.queue.indices.first { $0 != c.currentIndex && c.queue[$0].id == "a" }!
        c.removeFromQueue(at: IndexSet(integer: firstA))
        c.toggleShuffle()
        XCTAssertEqual(c.queue.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(c.currentIndex, 1, "still on the copy that was playing")
    }

    func testPlayNextGoesAfterTheCopyThatIsPlaying() {
        let c = controller()
        c.play(songs(["a", "b", "a", "c"]), startAt: 2)     // the second "a" plays
        c.toggleShuffle()
        c.playNext(songs(["n"]))
        XCTAssertEqual(c.queue[c.currentIndex + 1].id, "n", "next while shuffled")
        c.toggleShuffle()
        XCTAssertEqual(c.queue.map(\.id), ["a", "b", "a", "n", "c"], "after the second a, not the first")
        XCTAssertEqual(c.currentIndex, 2, "and unshuffling lands on that same copy")
    }

    func testReorderingWhileShuffledKeepsTheRestoreOrderWhole() {
        let c = controller()
        c.playShuffled(songs(["a", "b", "c", "d"]))
        let current = c.nowPlaying?.id
        c.moveQueueItem(from: IndexSet(integer: 3), to: 1)
        c.removeFromQueue(at: IndexSet(integer: c.currentIndex == 2 ? 3 : 2))
        c.toggleShuffle()
        XCTAssertEqual(c.queue.count, 3)
        XCTAssertEqual(c.nowPlaying?.id, current)
        XCTAssertEqual(c.queue.map(\.id), ["a", "b", "c", "d"].filter { c.queue.map(\.id).contains($0) },
                       "the survivors in their own order")
    }
}
