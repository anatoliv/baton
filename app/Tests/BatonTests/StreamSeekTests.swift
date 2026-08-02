import XCTest
@testable import Baton

/// Covers the pure decisions behind seeking a stream that may not support it.
///
/// **The bug these exist for.** Clicking the playbar partway into a long set skipped to the next
/// track. Navidrome serves a transcode as it encodes it: while encoding is still in progress the
/// response is `Transfer-Encoding: chunked` with `Accept-Ranges: none`, and a `Range` request is
/// answered `200` from byte zero rather than `206`. An AVPlayer seek past the buffered region
/// therefore cannot land — the item reports end-of-stream instead, and `handleEnded()` advanced
/// the queue.
///
/// It looked flaky because it is time-dependent, not position-dependent: encoding a long set took
/// 29–108 s against this library, and once warm the same track seeks perfectly. Short tracks
/// encode fast enough that the window is never noticed.
final class StreamSeekTests: XCTestCase {

    // MARK: - Choosing a strategy

    func testReachableTargetSeeksDirectly() {
        // A warm/native stream reports the whole asset as seekable — no reload, no re-buffer.
        XCTAssertEqual(
            StreamSeek.strategy(target: 2400, seekableRanges: [0...4524]),
            .direct)
    }

    func testTargetBeyondWhatTheStreamCanReachReloads() {
        // The reported bug: 40 minutes into a 75-minute set, of which the server has produced 10.
        XCTAssertEqual(
            StreamSeek.strategy(target: 2400, seekableRanges: [0...600]),
            .reload(offset: 2400))
    }

    func testShortTracksNeverNeedAReload() {
        // Why this was only ever seen on long tracks: a 4-minute track is fully encoded almost
        // immediately, so every target is inside the seekable range.
        XCTAssertEqual(
            StreamSeek.strategy(target: 200, seekableRanges: [0...240]),
            .direct)
    }

    func testUnknownSeekabilityReloadsRatherThanGuessing() {
        // No ranges = no evidence the target is reachable. A wrong `.direct` is the bug; a wrong
        // `.reload` only re-buffers, so the unknown case takes the recoverable side.
        XCTAssertEqual(
            StreamSeek.strategy(target: 900, seekableRanges: []),
            .reload(offset: 900))
    }

    func testSeekingBackBeforeAnOffsetStreamsStartReloads() {
        // Already streaming from 30:00; the listener drags back to 10:00. That audio was never in
        // this stream, however much of it has buffered.
        XCTAssertEqual(
            StreamSeek.strategy(target: 600, seekableRanges: [0...1200], streamStartOffset: 1800),
            .reload(offset: 600))
    }

    func testWithinAnOffsetStreamSeeksDirectly() {
        // Streaming from 30:00 with 20 min buffered: 35:00 is stream-local 300 s — reachable.
        XCTAssertEqual(
            StreamSeek.strategy(target: 2100, seekableRanges: [0...1200], streamStartOffset: 1800),
            .direct)
    }

    func testOffsetIsClampedToZero() {
        // A negative target must never become a negative `timeOffset` in a URL.
        XCTAssertEqual(
            StreamSeek.strategy(target: -50, seekableRanges: [], streamStartOffset: 0),
            .reload(offset: 0))
    }

    func testEdgeOfARangeCountsAsReachable() {
        // Exactly at the buffered edge, and a hair past it, are both fine — the tolerance exists
        // so a scrub to the very end of what's loaded doesn't trigger a pointless reload.
        XCTAssertEqual(StreamSeek.strategy(target: 600, seekableRanges: [0...600]), .direct)
        XCTAssertEqual(StreamSeek.strategy(target: 600.4, seekableRanges: [0...600]), .direct)
        XCTAssertEqual(StreamSeek.strategy(target: 620, seekableRanges: [0...600]),
                       .reload(offset: 620))
    }

    // MARK: - Telling a real end from a failed seek

    func testEndAtTheEndIsGenuine() {
        XCTAssertTrue(StreamSeek.isGenuineEnd(currentTime: 4524, duration: 4524))
        XCTAssertTrue(StreamSeek.isGenuineEnd(currentTime: 4521, duration: 4524))
    }

    func testEndInTheMiddleOfATrackIsNotGenuine() {
        // The exact failure: EOF reported 40 minutes into a 75-minute set. Advancing here is the
        // bug — the listener asked to move within the track, not to leave it.
        XCTAssertFalse(StreamSeek.isGenuineEnd(currentTime: 2400, duration: 4524))
    }

    func testUnknownDurationTrustsTheEnd() {
        // A live stream / indeterminate transcode has no end to compare against. Refusing to
        // advance would strand the queue, which is worse than the failure being guarded.
        XCTAssertTrue(StreamSeek.isGenuineEnd(currentTime: 30, duration: 0))
    }

    func testToleranceIsLooseEnoughForTranscodeClockDrift() {
        // A transcode's clock drifts a little from the metadata duration, so a real end can land
        // a couple of seconds short. That must still count as an end, or playback stalls.
        XCTAssertTrue(StreamSeek.isGenuineEnd(currentTime: 4520, duration: 4524))
        XCTAssertGreaterThanOrEqual(StreamSeek.spuriousEndTolerance, 2)
    }

    // MARK: - Which formats can skip the transcode

    func testNativeFormatsSkipTheTranscode() {
        // 28% of this library is MP3 — those stream as stored, so they are byte-range seekable
        // from the first play and never enter the failure window at all.
        XCTAssertFalse(StreamSeek.needsTranscode(suffix: "mp3"))
        XCTAssertFalse(StreamSeek.needsTranscode(suffix: "MP3"))
        XCTAssertFalse(StreamSeek.needsTranscode(suffix: "m4a"))
    }

    func testOpusIsTranscoded() {
        // The other 72%. AVFoundation does not decode Opus, and the failure is silence with no
        // error rather than an error — so this must stay transcoded.
        XCTAssertTrue(StreamSeek.needsTranscode(suffix: "opus"))
        XCTAssertTrue(StreamSeek.needsTranscode(suffix: "ogg"))
        XCTAssertTrue(StreamSeek.needsTranscode(suffix: "wma"))
    }

    func testUnknownFormatTakesTheSafeSide() {
        // Transcoding needlessly costs CPU; not transcoding when required costs silent playback.
        XCTAssertTrue(StreamSeek.needsTranscode(suffix: nil))
        XCTAssertTrue(StreamSeek.needsTranscode(suffix: ""))
    }

    func testFlacStaysTranscodedDespiteUsuallyWorking() {
        // Deliberate: AVFoundation has FLAC edge cases that play as silence, and nothing in this
        // library is FLAC, so there is no upside to the risk.
        XCTAssertTrue(StreamSeek.needsTranscode(suffix: "flac"))
    }

    // MARK: - Which duration to trust

    func testAnOffsetStreamsOwnDurationIsIgnored() {
        // The 0.11.3 regression, from the live log. A `timeOffset` stream reports the WHOLE
        // track, not the remainder, so adding the offset back inflated the track every seek:
        // a 4798 s set read 5502 s after one seek (4798 + 704) and 6325 s after two (4798 + 1527).
        XCTAssertEqual(
            StreamSeek.logicalDuration(assetSeconds: 4798, metadata: 4798, streamStartOffset: 704),
            4798)
        XCTAssertEqual(
            StreamSeek.logicalDuration(assetSeconds: 4798, metadata: 4798, streamStartOffset: 1527),
            4798)
    }

    func testRepeatedSeeksNeverGrowTheTrack() {
        // The property that actually matters: no sequence of seeks may change the track's length.
        // A scrubber that rescales under the listener sends the next click somewhere they didn't
        // aim, and eventually past the real end — where it reads as a skip.
        var duration = 4798.0
        for offset in [704.0, 1527, 3591, 4000] {
            duration = StreamSeek.logicalDuration(assetSeconds: duration, metadata: 4798,
                                                  streamStartOffset: offset)
            XCTAssertEqual(duration, 4798, "seek to \(offset) changed the track length")
        }
    }

    func testANormalLoadStillRefinesFromTheAsset() {
        // At offset 0 the asset is the whole track, and it is more accurate than metadata —
        // that refinement is why the scrubber isn't stuck at the server's rounded seconds.
        XCTAssertEqual(
            StreamSeek.logicalDuration(assetSeconds: 4797.6, metadata: 4798, streamStartOffset: 0),
            4797.6)
    }

    func testUnusableAssetDurationFallsBackToMetadata() {
        // A cold chunked transcode has no determinable duration; the metadata seed is what keeps
        // the scrubber from sitting at 0:00.
        XCTAssertEqual(StreamSeek.logicalDuration(assetSeconds: nil, metadata: 4798, streamStartOffset: 0), 4798)
        XCTAssertEqual(StreamSeek.logicalDuration(assetSeconds: .infinity, metadata: 4798, streamStartOffset: 0), 4798)
        XCTAssertEqual(StreamSeek.logicalDuration(assetSeconds: 0, metadata: 4798, streamStartOffset: 0), 4798)
    }

    // MARK: - Building the stream URL

    private let base = URL(string: "https://n.example/rest/stream.view?id=abc&format=mp3&u=x")!

    func testOffsetIsAddedAsWholeSeconds() {
        let url = StreamSeek.streamURL(base, offset: 2400.7)
        XCTAssertTrue(url.absoluteString.contains("timeOffset=2400"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("format=mp3"))
    }

    func testZeroOffsetLeavesTheURLAlone() {
        XCTAssertFalse(StreamSeek.streamURL(base, offset: 0).absoluteString.contains("timeOffset"))
        // Sub-second offsets aren't worth a reload and can't be expressed anyway.
        XCTAssertFalse(StreamSeek.streamURL(base, offset: 0.4).absoluteString.contains("timeOffset"))
    }

    func testAnExistingOffsetIsReplacedNotAppended() {
        // Subsonic takes the first occurrence of a parameter, so appending would silently pin
        // every later seek to wherever the first one went.
        let once = StreamSeek.streamURL(base, offset: 600)
        let twice = StreamSeek.streamURL(once, offset: 1800)
        XCTAssertEqual(twice.absoluteString.components(separatedBy: "timeOffset=").count - 1, 1)
        XCTAssertTrue(twice.absoluteString.contains("timeOffset=1800"))
        XCTAssertFalse(twice.absoluteString.contains("timeOffset=600"))
    }

    func testNativePassthroughDropsTheFormatParameter() {
        // `format=mp3` is what forces the transcode; without it Navidrome serves the stored file.
        let url = StreamSeek.streamURL(base, transcode: false)
        XCTAssertFalse(url.absoluteString.contains("format="))
        XCTAssertTrue(url.absoluteString.contains("id=abc"))
        XCTAssertTrue(url.absoluteString.contains("u=x"))
    }

    func testTranscodeIsKeptByDefault() {
        XCTAssertTrue(StreamSeek.streamURL(base).absoluteString.contains("format=mp3"))
    }

    func testProvenanceAnnotationSurvivesTheRewrite() {
        // `playedFrom` is the only record of which playlist a play came from — every judgement
        // about whether a playlist works is made from it. A seek must not strip it.
        let annotated = URL(string: base.absoluteString + "&playedFrom=playlist:abc123")!
        let url = StreamSeek.streamURL(annotated, offset: 900)
        XCTAssertTrue(url.absoluteString.contains("playedFrom=playlist:abc123"), url.absoluteString)
    }
}
