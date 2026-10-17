import AVFoundation
import BatonDocuments
import BatonPlaybackKit
import BatonShareKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// The app tools: books, clippings, podcasts, radio, Later, history, downloads,
/// shares, handoff, speed and settings, one family at a time. What every family keeps: a read
/// changes nothing; a delete, revoke, share or replace does nothing without `confirm: true` and
/// says what it would do; no answer carries a link, key, feed or stream address.
@MainActor
final class MCPAppToolsTests: XCTestCase {
    /// A source digest, as a real book's document id is (the cover store refuses anything else).
    private static let documentID = String(repeating: "ab", count: 32)
    private var root: URL!
    private var clippings: ClippingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-mcp-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"), defaults: ThrowawayDefaults.make("mcp-app"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private func tone(seconds: Double = 2) throws -> URL {
        let url = root.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(24_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    /// A two-chapter book and one reading, in Clippings.
    private func shelf() throws -> [BookShelf.Book] {
        for index in 0..<2 {
            try clippings.adopt(try tone(), title: "Chapter \(index + 1)", durationSeconds: 2, text: "Words \(index).",
                                chapter: .init(documentID: Self.documentID, documentTitle: "The Machine Stops", author: "E. M. Forster",
                                               chapterIndex: index, chapterTitle: "Chapter \(index + 1)"))
        }
        try clippings.adopt(try tone(), title: "A saved reading", durationSeconds: 2, text: "Read me.")
        var ledger = clippings.ledger
        ledger.setPosition(documentID: Self.documentID, chapterIndex: 1, seconds: 1.2)
        clippings.ledger = ledger
        return BookShelf.entries(items: clippings.items, jobs: [], ledger: clippings.ledger)
            .compactMap { if case let .book(book) = $0 { book } else { nil } }
    }

    // MARK: - Catalog

    func testEveryAppToolIsPublishedWithItsAnnotationsAndDestructiveOnesTakeConfirm() {
        let all = BatonMCPToolCatalog.definitions(includeDocuments: true)
        let byName = Dictionary(all.compactMap { def in (def["name"] as? String).map { ($0, def) } }, uniquingKeysWith: { a, _ in a })
        for name in BatonMCPAppTools.names {
            let def = try? XCTUnwrap(byName[name], "\(name) is not published")
            let annotations = def?["annotations"] as? [String: Any]
            XCTAssertEqual(annotations?["readOnlyHint"] as? Bool, BatonMCPAppTools.readOnlyNames.contains(name), name)
            XCTAssertEqual(annotations?["destructiveHint"] as? Bool, BatonMCPAppTools.destructiveNames.contains(name), name)
        }
        for name in BatonMCPAppTools.destructiveNames.union(["share_mixtape", "book_change_voice", "podcast_subscribe", "handoff_save_queue"]) {
            let properties = ((byName[name]?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            XCTAssertNotNil(properties["confirm"], "\(name) must take confirm")
        }
        XCTAssertTrue(BatonMCPAppTools.readOnlyNames.isDisjoint(with: BatonMCPAppTools.destructiveNames))
        // Book tools only while documents are on, like document_context.
        let withoutDocuments = Set(BatonMCPToolCatalog.definitions(includeDocuments: false).compactMap { $0["name"] as? String })
        XCTAssertTrue(withoutDocuments.isDisjoint(with: BatonMCPAppTools.bookTools))
        XCTAssertTrue(withoutDocuments.isSuperset(of: BatonMCPAppTools.names.subtracting(BatonMCPAppTools.bookTools)))
    }

    /// The chat and Siri keep the catalog they were measured with.
    func testTheChatSurfaceDoesNotOfferTheAppTools() async {
        let surface = MCPToolSurface(music: MusicModel(), focus: BatonAudioFocusRegistry())
        let offered = Set(surface.definitions().compactMap { $0["name"] as? String })
        XCTAssertTrue(offered.isDisjoint(with: BatonMCPAppTools.names))
        XCTAssertTrue(offered.contains("music_play"))
        let refused = await surface.run(name: "share_revoke", arguments: ["share_id": "x", "confirm": true], sessionID: nil)
        XCTAssertTrue(refused.isError)
    }

    // MARK: - Books

    func testBooksListAndChaptersSayWhereTheListenerIs() throws {
        let books = try shelf()
        let list = try object(BatonMCPAppTools.booksList(books, voices: { _ in VoicePlan(narrator: "openai:Aiden", characters: ["Kuno": "openai:Ryan"]) },
                                                         hasCover: { $0 == Self.documentID }))
        let row = try XCTUnwrap((list["books"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["title"] as? String, "The Machine Stops")
        XCTAssertEqual(row["chapters"] as? Int, 2)
        XCTAssertEqual(row["chapters_ready"] as? Int, 2)
        XCTAssertEqual((row["position"] as? [String: Any])?["chapter"] as? Int, 2)
        XCTAssertEqual(row["narrator"] as? String, "openai:Aiden")
        XCTAssertEqual(row["cast_size"] as? Int, 1)
        XCTAssertEqual(row["has_cover"] as? Bool, true)

        let chapters = try object(BatonMCPAppTools.bookChapters(["book": "machine"], books, nil))
        let rows = try XCTUnwrap(chapters["chapters"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["state"] as? String }, ["ready", "ready"])
        XCTAssertEqual(rows[1]["listener_is_here"] as? Int, 1)
        XCTAssertThrowsError(try BatonMCPAppTools.bookChapters(["book": "nothing like it"], books, nil))
    }

    func testBookPlayResumesOrStartsAChosenChapter() throws {
        let books = try shelf()
        let music = MusicModel()
        let resumed = try BatonMCPAppTools.bookPlay(["book": Self.documentID], books, music)
        XCTAssertTrue(resumed.contains("chapter 2, where the listener stopped"), resumed)
        XCTAssertEqual(music.music.nowPlaying?.title, "Chapter 2")
        _ = try BatonMCPAppTools.bookPlay(["book": Self.documentID, "chapter": 1], books, music)
        XCTAssertEqual(music.music.nowPlaying?.title, "Chapter 1")
        XCTAssertThrowsError(try BatonMCPAppTools.bookPlay(["book": Self.documentID, "chapter": 9], books, music))
    }

    func testTheCastAndTheChangesThatNeedConfirm() async throws {
        let books = try shelf()
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: DocumentLibraryTests.FakeKokoro(),
                                      retry: .init(initialDelay: 0.02, maximumDelay: 0.05), refreshInterval: .milliseconds(50))
        let book = books[0]
        let cast = try object(BatonMCPAppTools.castText(book, plan: VoicePlan(narrator: "kokoro:bf_emma", characters: ["Vashti": "kokoro:af_bella"]),
                                                        hasCast: true))
        XCTAssertEqual(cast["narrator"] as? String, "kokoro:bf_emma")
        XCTAssertEqual((cast["cast"] as? [[String: Any]])?.first?["character"] as? String, "Vashti")

        // A cover: a dry run changes nothing; with confirm it is made, then removed.
        let dry = try object(BatonMCPAppTools.bookCover(["book": Self.documentID, "action": "make"], books, library, playing: nil))
        XCTAssertEqual(dry["dry_run"] as? Bool, true)
        XCTAssertFalse(library.covers.hasCover(Self.documentID))
        _ = try BatonMCPAppTools.bookCover(["book": Self.documentID, "action": "make", "confirm": true], books, library, playing: nil)
        XCTAssertTrue(library.covers.hasCover(Self.documentID))
        let removeDry = try object(BatonMCPAppTools.bookCover(["book": Self.documentID, "action": "remove"], books, library, playing: nil))
        XCTAssertEqual(removeDry["dry_run"] as? Bool, true)
        XCTAssertTrue(library.covers.hasCover(Self.documentID))
        _ = try BatonMCPAppTools.bookCover(["book": Self.documentID, "action": "remove", "confirm": true], books, library, playing: nil)
        XCTAssertFalse(library.covers.hasCover(Self.documentID))

        // Change Voice: a book whose text this Mac does not have is refused before anything starts.
        do {
            _ = try await BatonMCPAppTools.bookChangeVoice(["book": Self.documentID, "voice": "kokoro:am_michael", "confirm": true], books, library, playing: nil)
            XCTFail("a book without its text here cannot change voice")
        } catch let error as BatonMCPToolError {
            XCTAssertTrue(error.message.contains("does not have its text"), error.message)
        }
    }

    // MARK: - Clippings

    func testClippingsListsReadingsOnlyAndDeleteNeedsConfirm() throws {
        _ = try shelf()
        let list = try object(BatonMCPAppTools.clippingsList([:], clippings.items))
        let rows = try XCTUnwrap(list["clippings"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["title"] as? String }, ["A saved reading"], "book chapters are not clippings")
        XCTAssertNil(rows[0]["url"])

        let dry = try object(BatonMCPAppTools.clippingDelete(["clipping": "A saved reading"], store: clippings))
        XCTAssertEqual(dry["dry_run"] as? Bool, true)
        XCTAssertEqual(BatonMCPAppTools.readings(clippings.items).count, 1)
        _ = try BatonMCPAppTools.clippingDelete(["clipping": "A saved reading", "confirm": true], store: clippings)
        XCTAssertTrue(BatonMCPAppTools.readings(clippings.items).isEmpty)
        XCTAssertEqual(clippings.chapters(ofDocument: Self.documentID).count, 2, "the book is untouched")
    }

    // MARK: - Podcasts

    func testPodcastsNeverShowAFeedOrEpisodeAddress() throws {
        let feed = URL(string: "https://private.example/feed?token=SECRET-TOKEN")!
        let audio = URL(string: "https://cdn.example/ep2.mp3?key=SECRET-AUDIO")!
        let channel = PodcastChannel(feedURL: feed, title: "Self-Hosted", episodes: [
            PodcastEpisode(id: "ep-2", title: "Episode Two", publishDate: Date(timeIntervalSince1970: 2_000), duration: 1_800, enclosureURL: audio),
            PodcastEpisode(id: "ep-1", title: "Episode One", publishDate: Date(timeIntervalSince1970: 1_000), duration: 1_700,
                           enclosureURL: URL(string: "https://cdn.example/ep1.mp3")!),
        ])
        let progress = PodcastProgressStore(directory: root.appendingPathComponent("progress"))
        progress.markPlayed(id: "https://cdn.example/ep1.mp3")
        _ = progress.record(id: audio.absoluteString, position: 900, duration: 1_800)

        let shows = BatonMCPAppTools.podcastsText([channel], progress: progress)
        let episodes = BatonMCPAppTools.episodesText(channel, limit: 10, progress: progress)
        for text in [shows, episodes] {
            XCTAssertFalse(text.contains("SECRET"), text)
            XCTAssertFalse(text.contains("example"), text)
        }
        let show = try XCTUnwrap((try object(shows)["shows"] as? [[String: Any]])?.first)
        XCTAssertEqual(show["unplayed"] as? Int, 1)
        XCTAssertEqual(try BatonMCPAppTools.show(["show": show["id"] as? String ?? ""], [channel]).title, "Self-Hosted")
        let rows = try XCTUnwrap(try object(episodes)["episodes"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["heard_percent"] as? Int, 50)
        XCTAssertEqual(rows[1]["played"] as? Bool, true)
    }

    // MARK: - Radio

    func testStationsAreListedWithoutTheirStreams() throws {
        let stations = [NavidromeRadioStation(id: "1", name: "Night Jazz", streamUrl: "https://stream.example/jazz?sid=SECRET", homepageUrl: nil)]
        let text = BatonMCPAppTools.stationsText(stations, onAir: "1")
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertEqual((try object(text)["stations"] as? [[String: Any]])?.first?["on_air"] as? Bool, true)
    }

    // MARK: - Later

    func testLaterListsAndRemovingNeedsConfirm() throws {
        let pins = PinStore(directory: root)
        let pin = PinnedItem.song(NavidromeSong(id: "s1", title: "Blue in Green", artist: "Miles Davis", album: "Kind of Blue",
                                                duration: 330, coverArtID: nil))
        pins.toggle(pin)
        let id = BatonMCPAppTools.laterID(pin)
        let list = try object(BatonMCPAppTools.laterList(pins))
        XCTAssertEqual((list["later"] as? [[String: Any]])?.first?["id"] as? String, id)
        XCTAssertEqual(try object(BatonMCPAppTools.laterRemove(["item": "Blue in Green"], pins: pins))["dry_run"] as? Bool, true)
        XCTAssertTrue(pins.isPinned("song:s1"))
        XCTAssertThrowsError(try BatonMCPAppTools.laterRemove(["item": "blue in", "confirm": true], pins: pins),
                             "a near title is never enough to remove")
        XCTAssertTrue(pins.isPinned("song:s1"))
        _ = try BatonMCPAppTools.laterRemove(["item": id, "confirm": true], pins: pins)
        XCTAssertFalse(pins.isPinned("song:s1"))
    }

    // MARK: - History

    func testHistoryRecentAndTopViews() throws {
        let history = MusicPlayHistory(defaults: ThrowawayDefaults.make("mcp-history"), directory: root)
        let now = Date()
        let song = NavidromeSong(id: "s1", title: "So What", artist: "Miles Davis", album: "Kind of Blue", duration: 545, coverArtID: nil)
        history.record(song, playedAt: now.addingTimeInterval(-7_200))
        history.record(song, playedAt: now.addingTimeInterval(-60))   // a minute apart or more: two plays
        let recent = try object(BatonMCPAppTools.history([:], history, now: now))
        XCTAssertEqual((recent["plays"] as? [[String: Any]])?.count, 2)
        let tracks = try object(BatonMCPAppTools.history(["view": "tracks", "days": 7], history, now: now))
        XCTAssertEqual((tracks["tracks"] as? [[String: Any]])?.first?["plays"] as? Int, 2)
        let artists = try object(BatonMCPAppTools.history(["view": "artists"], history, now: now))
        XCTAssertEqual((artists["artists"] as? [[String: Any]])?.first?["artist"] as? String, "Miles Davis")
        XCTAssertThrowsError(try BatonMCPAppTools.history(["view": "weekly"], history, now: now))
    }

    // MARK: - Downloads

    func testDownloadsUseOpaqueIdsAndRemovingNeedsConfirm() throws {
        let rows = [BatonMCPAppTools.DownloadRow(id: "https://cdn.example/ep.mp3?key=SECRET", title: "An Episode", artist: "A Show",
                                                 album: nil, bytes: 10_000),
                    BatonMCPAppTools.DownloadRow(id: "s1", title: "So What", artist: "Miles Davis", album: "Kind of Blue", bytes: 2_345)]
        let text = BatonMCPAppTools.downloadsList([:], items: rows, totalBytes: 12_345, offline: true)
        XCTAssertFalse(text.contains("http"), text)
        let reply = try object(text)
        XCTAssertEqual(reply["total_bytes"] as? Int, 12_345)
        XCTAssertEqual(reply["offline_mode"] as? Bool, true)
        let episodeID = try XCTUnwrap((reply["downloads"] as? [[String: Any]])?.first?["id"] as? String)

        var deleted: [String] = []
        let dry = try object(BatonMCPAppTools.downloadRemove(["ids": [episodeID]], items: rows, delete: { deleted.append($0) }))
        XCTAssertEqual(dry["dry_run"] as? Bool, true)
        XCTAssertFalse(String(describing: dry).contains("http"))
        XCTAssertEqual(deleted, [])
        _ = try BatonMCPAppTools.downloadRemove(["ids": [episodeID], "confirm": 1], items: rows, delete: { deleted.append($0) })
        XCTAssertEqual(deleted, [], "1 is not a confirmation")
        _ = try BatonMCPAppTools.downloadRemove(["ids": [episodeID], "confirm": true], items: rows, delete: { deleted.append($0) })
        XCTAssertEqual(deleted, ["https://cdn.example/ep.mp3?key=SECRET"], "the store's own id is what is removed")
        XCTAssertThrowsError(try BatonMCPAppTools.downloadRemove(["ids": ["nothing"]], items: rows, delete: { _ in }))
    }

    // MARK: - Shares

    func testSharesAreListedWithoutTheirLinks() throws {
        let records = [
            ShareLedger.Record(id: "sh1", link: "https://batonmusic.app/s/sh1#KEY-SECRET", songID: "s1", title: "So What",
                               artist: "Miles Davis", isPrivate: false, createdAt: Date(), expiresAt: Date().addingTimeInterval(86_400)),
            ShareLedger.Record(id: "mx1", link: "https://batonmusic.app/m/mx1#MIX-SECRET", songID: "", title: "Sunday",
                               artist: "", isPrivate: true, createdAt: Date(), expiresAt: Date().addingTimeInterval(-60),
                               kind: .mixtape, songIDs: ["a", "b", "c"]),
        ]
        let text = BatonMCPAppTools.sharesText(records)
        XCTAssertFalse(text.contains("SECRET"), text)
        XCTAssertFalse(text.contains("batonmusic.app"), text)
        let rows = try XCTUnwrap(try object(text)["shares"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["kind"] as? String }), ["song", "mixtape"])
        XCTAssertEqual(rows.first { $0["id"] as? String == "mx1" }?["tracks"] as? Int, 3)
        XCTAssertEqual(rows.first { $0["id"] as? String == "mx1" }?["plays_now"] as? Bool, false)
    }

    func testAMixtapeIsRefusedBeforeTheOwnerHasSharedOnce() async throws {
        do {
            _ = try await BatonMCPAppTools.shareMixtape(["song_ids": ["a", "b"], "title": "T", "confirm": true], MusicModel(),
                                                        hasSharedBefore: false)
            XCTFail("refused")
        } catch let error as BatonMCPToolError {
            XCTAssertEqual(error.message, SongSharing.consentRequiredMessage)
        }
    }

    // MARK: - Speed and settings

    func testSpeedReadsAndSetsTheSpokenRateOnly() throws {
        let music = MusicModel()
        let before = music.music.spokenRate
        defer { music.music.spokenRate = before }
        let read = try object(BatonMCPAppTools.playbackSpeed([:], music.music))
        XCTAssertEqual(read["spoken_rate"] as? Double, Double(before))
        _ = try BatonMCPAppTools.playbackSpeed(["rate": 1.5], music.music)
        XCTAssertEqual(music.music.spokenRate, 1.5)
        XCTAssertThrowsError(try BatonMCPAppTools.playbackSpeed(["rate": 3], music.music))
        XCTAssertThrowsError(try BatonMCPAppTools.playbackSpeed(["rate": "fast"], music.music))
    }

    func testSettingsCarryNoAddressOrKey() throws {
        let text = BatonMCPAppTools.settingsRead(MusicModel())
        let reply = try object(text)
        XCTAssertNotNil(reply["offline_mode"])
        XCTAssertNotNil(reply["voice_engine_for_books"])
        XCTAssertFalse(text.contains("http"), text)
    }

    func testADryRunSaysWhatAndChangesNothing() throws {
        let reply = try object(BatonMCPAppTools.dryRun("Do a thing."))
        XCTAssertEqual(reply["dry_run"] as? Bool, true)
        XCTAssertEqual(reply["would"] as? String, "Do a thing.")
    }

    /// Only a JSON boolean confirms or widens: 1, 1.0 and "true" do not, whether they arrive as
    /// Swift values or decoded from the wire, where Foundation hands 1 over as an NSNumber.
    func testOnlyAJSONBooleanConfirms() throws {
        for value: Any in [1, 1.0, "true", NSNumber(value: 1), NSNumber(value: 1.0)] {
            XCTAssertFalse(BatonMCPAppTools.confirmed(["confirm": value]), "\(value)")
        }
        XCTAssertTrue(BatonMCPAppTools.confirmed(["confirm": true]))
        XCTAssertFalse(BatonMCPAppTools.confirmed(["confirm": false]))
        for wire in [#"{"confirm": 1}"#, #"{"confirm": 1.0}"#, #"{"confirm": "true"}"#] {
            let args = try object(wire)
            XCTAssertFalse(BatonMCPAppTools.confirmed(args), wire)
        }
        XCTAssertTrue(BatonMCPAppTools.confirmed(try object(#"{"confirm": true}"#)))

        _ = try shelf()
        let one = try object(BatonMCPAppTools.clippingDelete(try object(#"{"clipping": "A saved reading", "confirm": 1}"#), store: clippings))
        XCTAssertEqual(one["dry_run"] as? Bool, true, "confirm 1 is a dry run")
        XCTAssertThrowsError(try BatonMCPAppTools.clippingDelete(
            try object(#"{"clipping": "A saved reading", "everywhere": 1, "confirm": true}"#), store: clippings),
                             "everywhere 1 must not widen a local delete")
        XCTAssertEqual(BatonMCPAppTools.readings(clippings.items).count, 1, "nothing was deleted")
    }

    /// A destructive tool takes the id or one exact title; several, or only near matches, are
    /// refused with the candidates and their ids.
    func testDestructiveToolsNeverGuess() throws {
        _ = try shelf()
        try clippings.adopt(try tone(), title: "A saved reading", durationSeconds: 2, text: "Again.")
        let readings = BatonMCPAppTools.readings(clippings.items)
        XCTAssertEqual(readings.count, 2)
        XCTAssertThrowsError(try BatonMCPAppTools.clippingDelete(["clipping": "A saved reading", "confirm": true], store: clippings)) { error in
            let message = (error as? BatonMCPToolError)?.message ?? ""
            XCTAssertTrue(message.contains("More than one clipping"), message)
            for item in readings { XCTAssertTrue(message.contains(item.id), message) }
        }
        XCTAssertThrowsError(try BatonMCPAppTools.clippingDelete(["clipping": "saved", "confirm": true], store: clippings)) { error in
            XCTAssertTrue(((error as? BatonMCPToolError)?.message ?? "").contains("exact title or the id"))
        }
        XCTAssertEqual(BatonMCPAppTools.readings(clippings.items).count, 2, "nothing was deleted")
        _ = try BatonMCPAppTools.clippingDelete(["clipping": readings[0].id, "confirm": true], store: clippings)
        XCTAssertEqual(BatonMCPAppTools.readings(clippings.items).count, 1)

        let shows = [PodcastChannel(feedURL: URL(string: "https://a.example/feed")!, title: "Daily"),
                     PodcastChannel(feedURL: URL(string: "https://b.example/feed")!, title: "Daily")]
        XCTAssertThrowsError(try BatonMCPAppTools.show(["show": "Daily"], shows, exactly: true))
        XCTAssertThrowsError(try BatonMCPAppTools.show(["show": "Dai"], shows, exactly: true))
        XCTAssertEqual(try BatonMCPAppTools.show(["show": BatonMCPAppTools.shortID(shows[1].id)], shows, exactly: true).feedURL, shows[1].feedURL)
    }

    /// No answer carries an address: Later's episodes, shows and stations, episodes whose guid is
    /// the audio address, downloads, clippings read from a page, podcasts, stations and shares.
    func testNoResponseCarriesAnAddress() throws {
        let audio = URL(string: "https://cdn.example/ep.mp3?key=SECRET")!
        let channel = PodcastChannel(feedURL: URL(string: "https://feeds.example/show?token=SECRET")!, title: "Show",
                                     episodes: [PodcastEpisode(id: audio.absoluteString, title: "Ep", enclosureURL: audio)])
        let pins = PinStore(directory: root)
        pins.toggle(PinnedItem.episode(channel.episodes[0], channel: channel))
        pins.toggle(PinnedItem.channel(channel))
        pins.toggle(PinnedItem.station(NavidromeRadioStation(id: "r1", name: "Night Jazz", streamUrl: "https://stream.example/live", homepageUrl: nil)))
        try clippings.adopt(try tone(), title: "From a page", sourceName: "https://news.example/story", durationSeconds: 2, text: "Read.")
        let progress = PodcastProgressStore(directory: root.appendingPathComponent("progress"))
        let responses = [
            BatonMCPAppTools.laterList(pins),
            BatonMCPAppTools.episodesText(channel, limit: 10, progress: progress),
            BatonMCPAppTools.podcastsText([channel], progress: progress),
            BatonMCPAppTools.clippingsList([:], clippings.items),
            BatonMCPAppTools.downloadsList([:], items: [.init(id: audio.absoluteString, title: "Ep", artist: nil, album: nil, bytes: 1)],
                                           totalBytes: 1, offline: false),
            BatonMCPAppTools.stationsText([NavidromeRadioStation(id: "r1", name: "Night Jazz", streamUrl: "https://stream.example/live", homepageUrl: nil)], onAir: nil),
            BatonMCPAppTools.sharesText([ShareLedger.Record(id: "sh1", link: "https://batonmusic.app/s/sh1#KEY", songID: "s1", title: "T",
                                                            artist: "A", isPrivate: false, createdAt: Date(), expiresAt: Date())]),
            BatonMCPAppTools.handoffSaveText(.sent),
        ]
        for text in responses { XCTAssertFalse(text.lowercased().contains("http"), text) }
        // The opaque ids still reach the item.
        let laterRows = try XCTUnwrap(try object(responses[0])["later"] as? [[String: Any]])
        let episodeRow = try XCTUnwrap(laterRows.first { $0["kind"] as? String == "episode" })
        XCTAssertEqual(try BatonMCPAppTools.laterItem(["item": episodeRow["id"] as? String ?? ""], pins).kind, .podcastEpisode)
        let episodeID = try XCTUnwrap((try object(responses[1])["episodes"] as? [[String: Any]])?.first?["id"] as? String)
        XCTAssertEqual(try BatonMCPAppTools.pick(channel.episodes, episodeID, id: { BatonMCPAppTools.shortID($0.id) },
                                                 title: \.title, what: "episode").title, "Ep")
    }

    func testHandoffSaySaysWhatActuallyHappened() throws {
        let sent = try object(BatonMCPAppTools.handoffSaveText(.sent))
        XCTAssertEqual(sent["scheduled"] as? Bool, true)
        XCTAssertTrue((sent["done"] as? String ?? "").hasPrefix("Scheduled to send"), "not reported as saved before the server answers")
        for outcome: QueueHandoff.SaveOutcome in [.emptyQueue, .unavailable, .unchanged] {
            let reply = try object(BatonMCPAppTools.handoffSaveText(outcome))
            XCTAssertEqual(reply["scheduled"] as? Bool, false, "\(outcome)")
            XCTAssertTrue((reply["done"] as? String ?? "").hasPrefix("Nothing was saved"), "\(outcome)")
        }
        XCTAssertTrue((try object(BatonMCPAppTools.handoffSaveText(.emptyQueue))["done"] as? String ?? "").contains("empty"))
    }

    /// A dry run on an empty queue says so, rather than offering to leave "0 tracks".
    func testHandoffDryRunOnAnEmptyQueueSaysItIsEmpty() throws {
        let reply = try object(BatonMCPAppTools.handoffSave([:], MusicModel()))
        XCTAssertEqual(reply["dry_run"] as? Bool, true)
        XCTAssertEqual(reply["queue_empty"] as? Bool, true)
        XCTAssertTrue((reply["would"] as? String ?? "").contains("empty"))
        XCTAssertFalse((reply["would"] as? String ?? "").contains("0 tracks"))
    }

    /// A confirmed cover change or Change Voice names its book exactly: a missing `book`, two
    /// titles sharing the words asked for, and a near title are refused with the ids, and nothing
    /// changes. An exact title or id works. A dry run may still find a book loosely.
    func testConfirmedBookChangesNameTheirBookExactly() async throws {
        _ = try shelf()
        let secondID = String(repeating: "cd", count: 32)
        for index in 0..<2 {
            try clippings.adopt(try tone(), title: "Chapter \(index + 1)", durationSeconds: 2, text: "More \(index).",
                                chapter: .init(documentID: secondID, documentTitle: "The Machine Stops Again", author: "E. M. Forster",
                                               chapterIndex: index, chapterTitle: "Chapter \(index + 1)"))
        }
        let books = BookShelf.entries(items: clippings.items, jobs: [], ledger: clippings.ledger)
            .compactMap { if case let .book(book) = $0 { book } else { nil } }
        XCTAssertEqual(books.count, 2)
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: DocumentLibraryTests.FakeKokoro(),
                                      retry: .init(initialDelay: 0.02, maximumDelay: 0.05), refreshInterval: .milliseconds(50))
        _ = try BatonMCPAppTools.bookCover(["book": Self.documentID, "action": "make", "confirm": true], books, library, playing: nil)
        _ = try BatonMCPAppTools.bookCover(["book": secondID, "action": "make", "confirm": true], books, library, playing: nil)

        func refused(_ args: [String: Any], _ expected: String) {
            XCTAssertThrowsError(try BatonMCPAppTools.bookCover(args, books, library, playing: nil), "\(args)") { error in
                let message = (error as? BatonMCPToolError)?.message ?? ""
                XCTAssertTrue(message.contains(expected), message)
                XCTAssertTrue(message.contains(Self.documentID) && message.contains(secondID), "the candidates come with their ids: \(message)")
            }
        }
        refused(["action": "remove", "confirm": true], "Name the `book`")
        refused(["book": "Machine", "action": "remove", "confirm": true], "exact title or the id")
        refused(["book": "machine stops", "action": "remove", "confirm": true], "exact title or the id")
        XCTAssertTrue(library.covers.hasCover(Self.documentID) && library.covers.hasCover(secondID), "nothing was removed")

        // A dry run may still find a book loosely, and changes nothing.
        let dry = try object(BatonMCPAppTools.bookCover(["book": "machine", "action": "remove"], books, library, playing: nil))
        XCTAssertEqual(dry["dry_run"] as? Bool, true)

        // Exactly, by full title (case ignored) or by id.
        _ = try BatonMCPAppTools.bookCover(["book": "the machine stops", "action": "remove", "confirm": true], books, library, playing: nil)
        XCTAssertFalse(library.covers.hasCover(Self.documentID))
        XCTAssertTrue(library.covers.hasCover(secondID), "only the named book")
        _ = try BatonMCPAppTools.bookCover(["book": secondID, "action": "remove", "confirm": true], books, library, playing: nil)
        XCTAssertFalse(library.covers.hasCover(secondID))

        // Change Voice keeps the same rule before anything else is checked.
        for args: [String: Any] in [["voice": "kokoro:am_michael", "confirm": true],
                                    ["book": "Machine", "voice": "kokoro:am_michael", "confirm": true]] {
            do {
                _ = try await BatonMCPAppTools.bookChangeVoice(args, books, library, playing: nil)
                XCTFail("refused: \(args)")
            } catch let error as BatonMCPToolError {
                XCTAssertTrue(error.message.contains("Name the `book`") || error.message.contains("exact title or the id"), error.message)
            }
        }
    }

    /// Settings → Remote → Test sends the provider what the chat sends: no app tools.
    func testTheRemoteTestSendsTheChatCatalog() {
        let names = Set(MCPToolSurface.chatDefinitions().compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isDisjoint(with: BatonMCPAppTools.names))
        XCTAssertTrue(names.contains("music_play"))
    }
}
