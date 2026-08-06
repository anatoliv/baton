import XCTest
@testable import BatonAgentKit
import BatonPlaybackKit
import BatonSubsonicKit
import BatonSubsonicModels

/// What reaches the model decides what it can say. Measured against a real
/// library, two thirds of the taste signal was being discarded before the model
/// saw it, and what did arrive ended mid-object.
@MainActor
final class RemoteAgentResultsTests: XCTestCase {
    /// One song as the catalog actually serializes it — 483 characters, of
    /// which roughly half is engineering telemetry.
    private func song(_ id: Int) -> String {
        """
        {"album":"YT Mix","artist":"DIDO","bit_depth":0,"bit_rate_kbps":136,"bpm":0,\
        "channels":2,"comment":"https://www.youtube.com/watch?v=WQOGD6FqB0Y",\
        "content_type":"audio/ogg","duration_seconds":414,"format":"opus",\
        "genres":["Music"],"id":"s\(id)","last_played":"2026-08-02T22:25:24Z",\
        "liked":true,"musicbrainz_id":"","play_count":3,"quality":"OPUS 136",\
        "rating":5,"sampling_rate_hz":48000,"size_bytes":7321665,\
        "title":"Evermore (Original Mix)","track":6649,"year":2026}
        """
    }

    private func liked(count: Int) -> String {
        #"{"songs":[\#((1 ... count).map(song).joined(separator: ","))],"total_liked_songs":65}"#
    }

    func testTelemetryIsStrippedFromEverySong() throws {
        let shaped = RemoteAgentResults.shape(liked(count: 1))
        for key in RemoteAgentResults.noiseKeys {
            XCTAssertFalse(shaped.contains("\"\(key)\""), "\(key) is not about music")
        }
        // The facts a conversation about music actually turns on.
        for key in ["title", "artist", "album", "play_count", "rating", "liked", "last_played", "year"] {
            XCTAssertTrue(shaped.contains("\"\(key)\""), "\(key) must survive")
        }
    }

    /// The headline measurement: 40 liked songs used to arrive as 12 plus a
    /// fragment. Stripping the noise roughly doubles what fits.
    func testStrippingMoreThanDoublesWhatFitsInTheBudget() throws {
        let shaped = RemoteAgentResults.shape(liked(count: 40))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(shaped.utf8)) as? [String: Any])
        let songs = try XCTUnwrap(json["songs"] as? [[String: Any]])

        XCTAssertGreaterThan(songs.count, 24, "should fit far more than the old 12")
        XCTAssertLessThanOrEqual(shaped.count, 6000)
    }

    /// The old clamp cut the string, so the model received a JSON fragment and
    /// a note apologising for it. Trimming by item keeps it parseable at every
    /// size — which is the difference between "26 of your 65 liked songs" and
    /// unparseable text.
    func testAnOversizedResultStaysValidJSON() throws {
        let shaped = RemoteAgentResults.shape(liked(count: 200))
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(shaped.utf8)),
            "a trimmed result must still parse"
        )
        XCTAssertLessThanOrEqual(shaped.count, 6000)
    }

    /// And it must say what it left out, so the model can tell the person it is
    /// summarising rather than reporting the whole library.
    func testWhatWasLeftOutIsStated() throws {
        let shaped = RemoteAgentResults.shape(liked(count: 200))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(shaped.utf8)) as? [String: Any])
        let omitted = try XCTUnwrap(json["omitted"] as? String)
        XCTAssertTrue(omitted.contains("songs"), omitted)
    }

    /// Small results must come back untouched apart from the noise — no
    /// trimming, no omission note.
    func testASmallResultIsLeftAlone() throws {
        let shaped = RemoteAgentResults.shape(liked(count: 2))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(shaped.utf8)) as? [String: Any])
        XCTAssertEqual((json["songs"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(json["omitted"])
        XCTAssertEqual(json["total_liked_songs"] as? Int, 65)
    }

    /// Several tools answer with a plain sentence rather than JSON.
    func testPlainSentencesPassThrough() {
        XCTAssertEqual(
            RemoteAgentResults.shape("Music volume set to 70."), "Music volume set to 70.")
    }
}
