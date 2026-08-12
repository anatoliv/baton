import XCTest
@testable import BatonPlaybackKit

/// Parsing lyrics nobody wrote for us.
///
/// The LRC format is decades old and produced by dozens of tools, so the input is not
/// trustworthy — which makes the *failure* behaviour the interesting part: a malformed
/// timestamp must not delete its line, and metadata tags must not become lyrics.
final class LRCLIBLyricsTests: XCTestCase {
    func testSyncedLyricsCarryTheirTimestamps() throws {
        let lines = try XCTUnwrap(LRCLIBLyrics.parseLRC("""
        [00:12.00]First line
        [00:17.20]Second line
        [01:02.50]Third line
        """))
        XCTAssertEqual(lines.map(\.text), ["First line", "Second line", "Third line"])
        XCTAssertEqual(lines[0].start, 12)
        XCTAssertEqual(lines[1].start ?? 0, 17.2, accuracy: 0.001)
        XCTAssertEqual(lines[2].start ?? 0, 62.5, accuracy: 0.001)
    }

    /// `[ar: …]`, `[length: …]` and friends are metadata. Rendering them as the first two
    /// lines of a song is the classic LRC parsing bug.
    func testMetadataTagsAreNotLyrics() throws {
        let lines = try XCTUnwrap(LRCLIBLyrics.parseLRC("""
        [ar:Some Artist]
        [length:03:21]
        [00:10.00]Actual words
        """))
        XCTAssertEqual(lines.map(\.text), ["Actual words"])
    }

    func testPlainLyricsAreUsedWhenThereAreNoSyncedOnes() throws {
        let json = #"{"plainLyrics":"one\ntwo","syncedLyrics":null}"#.data(using: .utf8)!
        let parsed = try XCTUnwrap(LRCLIBLyrics.parse(json))
        XCTAssertFalse(parsed.synced)
        XCTAssertEqual(parsed.lines.map(\.text), ["one", "two"])
    }

    /// Synced beats plain when both are offered — the scroll-along is the point.
    func testSyncedIsPreferredOverPlain() throws {
        let json = #"{"plainLyrics":"flat","syncedLyrics":"[00:01.00]timed"}"#.data(using: .utf8)!
        let parsed = try XCTUnwrap(LRCLIBLyrics.parse(json))
        XCTAssertTrue(parsed.synced)
        XCTAssertEqual(parsed.lines.map(\.text), ["timed"])
    }

    func testAnEmptyOrUselessResponseIsNothingRatherThanBlankLyrics() {
        XCTAssertNil(LRCLIBLyrics.parse(#"{"plainLyrics":"","syncedLyrics":""}"#.data(using: .utf8)!))
        XCTAssertNil(LRCLIBLyrics.parse(Data("not json".utf8)))
    }

    /// Off unless asked for. This is the one lookup that leaves the user's own server.
    func testTheFallbackIsOptInByDefault() {
        UserDefaults.standard.removeObject(forKey: LRCLIBLyrics.enabledKey)
        XCTAssertFalse(LRCLIBLyrics.isEnabled)
    }
}

/// Finding the record at all.
///
/// `/api/get` is an exact match, and tags are not exact. These pin the cleaning and the
/// duration gate that let the fuzzy `/api/search` hop stand in without ever handing back
/// the wrong song's words.
final class LRCLIBSearchMatchTests: XCTestCase {
    // MARK: Cleaning tags into something a lyrics database recognises

    func testTheRemixSuffixComesOffTheTitle() {
        XCTAssertEqual(LRCLIBLyrics.searchableTitle("Wearing My Shoes (Louis Bailar's radio Chillout)"),
                       "Wearing My Shoes")
        XCTAssertEqual(LRCLIBLyrics.searchableTitle("Song [Extended Mix]"), "Song")
    }

    /// The dash form only gives up its tail to a word that actually marks a variant, so a
    /// title whose real name contains a dash survives intact.
    func testADashTailIsCutOnlyWhenItNamesAVariant() {
        XCTAssertEqual(LRCLIBLyrics.searchableTitle("Heroes - 2017 Remaster"), "Heroes")
        XCTAssertEqual(LRCLIBLyrics.searchableTitle("Ashes - Part One"), "Ashes - Part One")
    }

    func testTheGuestCreditComesOffTheArtist() {
        XCTAssertEqual(LRCLIBLyrics.searchableArtist("Aura feat. Dani Senior"), "Aura")
        XCTAssertEqual(LRCLIBLyrics.searchableArtist("Aura Ft Danielle Senior"), "Aura")
        XCTAssertEqual(LRCLIBLyrics.searchableArtist("Calvin Harris featuring Rihanna"), "Calvin Harris")
    }

    /// `with` reads as a credit in the middle of a name and as a word at the start of one.
    func testATitleThatOpensWithWithKeepsIt() {
        XCTAssertEqual(LRCLIBLyrics.searchableTitle("With or Without You"), "With or Without You")
        XCTAssertEqual(LRCLIBLyrics.searchableArtist("Santana with Rob Thomas"), "Santana")
    }

    /// A title that is nothing but a variant marker would otherwise clean itself away to
    /// an empty query, which matches everything.
    func testCleaningNeverReturnsNothing() {
        // Cleaned away to nothing, so the raw title stands — a bad query beats no query.
        XCTAssertEqual(LRCLIBLyrics.searchableTitle("(Remix)"), "(Remix)")
        XCTAssertEqual(LRCLIBLyrics.searchableArtist("feat. Someone"), "feat. Someone")
    }

    // MARK: Choosing among fuzzy hits

    /// The evidence case, as the live API actually answers it: LRCLIB holds this recording
    /// under a differently-worded remix suffix and without the guest, and a second, longer
    /// mix under the same title. Duration is the only thing that tells them apart.
    func testTheRightMixIsPickedByDuration() throws {
        let results = Self.decode("""
        [{"trackName":"Wearing My Shoes (Louis Bailar's Chillout Radio Mix)","artistName":"Aura",
          "duration":205.0,"instrumental":false,"plainLyrics":"the radio mix words","syncedLyrics":null},
         {"trackName":"Wearing My Shoes (Louis Bailar Chillout Mix)","artistName":"Aura Ft Danielle Senior",
          "duration":341.368163,"instrumental":false,"plainLyrics":"the club mix words","syncedLyrics":null}]
        """)
        let match = try XCTUnwrap(LRCLIBLyrics.bestMatch(in: results,
                                                         title: "Wearing My Shoes (Louis Bailar's radio Chillout)",
                                                         artist: "Aura feat. Dani Senior",
                                                         durationSeconds: 205))
        XCTAssertEqual(match.lines.map(\.text), ["the radio mix words"])
    }

    /// The same list, playing the long mix. Nothing about the words changes — only which
    /// sheet is the right one.
    func testTheOtherMixIsPickedWhenItIsTheOnePlaying() throws {
        let results = Self.decode("""
        [{"trackName":"Wearing My Shoes (Louis Bailar's Chillout Radio Mix)","artistName":"Aura",
          "duration":205.0,"instrumental":false,"plainLyrics":"the radio mix words","syncedLyrics":null},
         {"trackName":"Wearing My Shoes (Louis Bailar Chillout Mix)","artistName":"Aura",
          "duration":341.368163,"instrumental":false,"plainLyrics":"the club mix words","syncedLyrics":null}]
        """)
        let match = try XCTUnwrap(LRCLIBLyrics.bestMatch(in: results, title: "Wearing My Shoes",
                                                         artist: "Aura", durationSeconds: 341))
        XCTAssertEqual(match.lines.map(\.text), ["the club mix words"])
    }

    /// The whole point of the gate. A right-titled, right-artisted, wrong-length record is
    /// a different recording, and its words would scroll against nothing.
    func testADurationThatDoesNotAgreeIsRejectedOutright() {
        let results = Self.decode("""
        [{"trackName":"Bohemian Rhapsody","artistName":"Queen","duration":351.0,
          "instrumental":false,"plainLyrics":"is this the real life","syncedLyrics":null}]
        """)
        XCTAssertNil(LRCLIBLyrics.bestMatch(in: results, title: "Bohemian Rhapsody",
                                            artist: "Queen", durationSeconds: 317))
    }

    /// Databases round; tags round differently. A couple of seconds is the same recording.
    func testASecondOrTwoOfDriftIsStillTheSameRecording() {
        let results = Self.decode("""
        [{"trackName":"Bohemian Rhapsody","artistName":"Queen","duration":354.2,
          "instrumental":false,"plainLyrics":"is this the real life","syncedLyrics":null}]
        """)
        XCTAssertNotNil(LRCLIBLyrics.bestMatch(in: results, title: "Bohemian Rhapsody",
                                               artist: "Queen", durationSeconds: 352))
    }

    /// A different song that happens to run the same length must not sneak through on
    /// duration alone.
    func testADifferentSongOfTheSameLengthIsNotAMatch() {
        let results = Self.decode("""
        [{"trackName":"Something Else Entirely","artistName":"Another Band","duration":205.0,
          "instrumental":false,"plainLyrics":"wrong words","syncedLyrics":null}]
        """)
        XCTAssertNil(LRCLIBLyrics.bestMatch(in: results, title: "Wearing My Shoes",
                                            artist: "Aura", durationSeconds: 205))
    }

    /// Right title, right length, someone else's record of it.
    func testACoverByAnotherArtistIsNotAMatch() {
        let results = Self.decode("""
        [{"trackName":"Wearing My Shoes","artistName":"A Tribute Band","duration":205.0,
          "instrumental":false,"plainLyrics":"wrong words","syncedLyrics":null}]
        """)
        XCTAssertNil(LRCLIBLyrics.bestMatch(in: results, title: "Wearing My Shoes",
                                            artist: "Aura", durationSeconds: 205))
    }

    /// An artist filed twice over is still the same artist.
    func testARepeatedArtistNameStillAgrees() {
        let results = Self.decode("""
        [{"trackName":"Smells Like Teen Spirit","artistName":"Nirvana - Nirvana","duration":301.0,
          "instrumental":false,"plainLyrics":"load up on guns","syncedLyrics":null}]
        """)
        XCTAssertNotNil(LRCLIBLyrics.bestMatch(in: results, title: "Smells like Teen Spirit",
                                               artist: "Nirvana", durationSeconds: 301))
    }

    /// An instrumental record is a correct answer to "what are the lyrics" — the answer is
    /// none — so it must not be handed back as a sheet.
    func testAnInstrumentalRecordIsNotLyrics() {
        let results = Self.decode("""
        [{"trackName":"Wearing My Shoes","artistName":"Aura","duration":205.0,
          "instrumental":true,"plainLyrics":"","syncedLyrics":null}]
        """)
        XCTAssertNil(LRCLIBLyrics.bestMatch(in: results, title: "Wearing My Shoes",
                                            artist: "Aura", durationSeconds: 205))
    }

    func testSyncedIsStillPreferredAmongSearchHits() throws {
        let results = Self.decode("""
        [{"trackName":"Song","artistName":"Band","duration":200.0,"instrumental":false,
          "plainLyrics":"flat","syncedLyrics":"[00:01.00]timed"}]
        """)
        let match = try XCTUnwrap(LRCLIBLyrics.bestMatch(in: results, title: "Song",
                                                         artist: "Band", durationSeconds: 200))
        XCTAssertTrue(match.synced)
    }

    func testAMalformedSearchResponseIsAnEmptyListRatherThanACrash() {
        XCTAssertTrue(LRCLIBLyrics.parseSearchResults(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(LRCLIBLyrics.parseSearchResults(Data("{}".utf8)).isEmpty)
    }

    // MARK: Content that has no lyrics to find

    func testLongMixesAreRecognisedRatherThanLookedUp() {
        XCTAssertTrue(LRCLIBLyrics.isLikelyLyricless(durationSeconds: 3 * 60 * 60))
        XCTAssertTrue(LRCLIBLyrics.isLikelyLyricless(durationSeconds: 25 * 60))
        XCTAssertFalse(LRCLIBLyrics.isLikelyLyricless(durationSeconds: 205))
        // A prog epic is long, not a set.
        XCTAssertFalse(LRCLIBLyrics.isLikelyLyricless(durationSeconds: 18 * 60))
        XCTAssertFalse(LRCLIBLyrics.isLikelyLyricless(durationSeconds: nil))
    }

    private static func decode(_ json: String) -> [LRCLIBLyrics.SearchResult] {
        LRCLIBLyrics.parseSearchResults(Data(json.utf8))
    }
}
