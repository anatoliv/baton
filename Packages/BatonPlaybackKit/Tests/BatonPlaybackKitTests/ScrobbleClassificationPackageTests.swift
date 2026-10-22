import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// A listen a service rejects outright (ListenBrainz answers 400 for a `listened_at` before
/// 2002 or an empty track name) is a definitive rejection, not a temporary one. Filed as
/// temporary it never burned an attempt, so the queue head was retried forever and every later
/// listen for that service waited behind it (TBX-1000000480 C2-8).
@MainActor
final class ScrobbleClassificationPackageTests: XCTestCase {
    func testA4xxOtherThanTimeoutAndRateLimitIsPermanent() {
        XCTAssertFalse(ScrobbleService.isTransient(ScrobbleError.http(400)))
        XCTAssertFalse(ScrobbleService.isTransient(ScrobbleError.http(404)))
        XCTAssertFalse(ScrobbleService.isTransient(ScrobbleError.http(422)))
        XCTAssertTrue(ScrobbleService.isTransient(ScrobbleError.http(408)))
        XCTAssertTrue(ScrobbleService.isTransient(ScrobbleError.http(429)))
        XCTAssertTrue(ScrobbleService.isTransient(ScrobbleError.http(503)))
    }

    /// A payload that cannot be encoded now cannot be encoded on any retry either.
    func testAPayloadThatCannotBeEncodedIsPermanent() {
        XCTAssertFalse(ScrobbleService.isTransient(ScrobbleError.service(MusicScrobbler.encodeFailure)))
        XCTAssertTrue(ScrobbleService.isTransient(ScrobbleError.service("Last.fm 16: Service temporarily unavailable")))
    }

    func testARejectedListenRetiresAndDoesNotBlockALaterOne() async {
        let defaults = ThrowawayDefaults.make("scrobble-classification")
        let listenBrainz = RejectingDestination(id: "listenbrainz", rejectedSongID: "bad")
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let service = ScrobbleService(
            listenBrainz: listenBrainz, lastfm: RejectingDestination(id: "lastfm", active: false),
            navidrome: RejectingDestination(id: "navidrome", active: false),
            queue: ScrobbleQueue(defaults: defaults), defaults: defaults,
            now: { clock }, monitorNetwork: false, autoFlush: false
        )
        service.completed(NavidromeSong(id: "bad", title: "Bad", artist: "A"), startedAt: clock)
        service.completed(NavidromeSong(id: "good", title: "Good", artist: "A"), startedAt: clock.addingTimeInterval(1))

        for _ in 0 ... ScrobbleQueue.maxAttempts {
            await service.flushAllAndWait()
            clock.addTimeInterval(3600) // past any backoff
        }

        XCTAssertEqual(listenBrainz.delivered, ["good"], "the rejected listen blocked the one behind it")
        XCTAssertEqual(service.pendingCount, 0)
    }

    /// ListenBrainz and Last.fm take 50 listens a batch. One refused listen must not spend the
    /// attempts of the other 49 and, after `maxAttempts`, retire them with it.
    func testOneRefusedListenInABatchChargesOnlyItself() async {
        let defaults = ThrowawayDefaults.make("scrobble-batch-isolation")
        let queue = ScrobbleQueue(defaults: defaults)
        let listenBrainz = RejectingDestination(id: "listenbrainz", rejectedSongID: "bad", maxBatch: 50)
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let service = ScrobbleService(
            listenBrainz: listenBrainz, lastfm: RejectingDestination(id: "lastfm", active: false),
            navidrome: RejectingDestination(id: "navidrome", active: false),
            queue: queue, defaults: defaults, now: { clock }, monitorNetwork: false, autoFlush: false
        )
        for (offset, id) in ["good-1", "bad", "good-2"].enumerated() {
            service.completed(NavidromeSong(id: id, title: id, artist: "A"), startedAt: clock.addingTimeInterval(Double(offset)))
        }

        await service.flushAllAndWait()

        XCTAssertEqual(listenBrainz.delivered, ["good-1", "good-2"], "the good listens in the refused batch were held back")
        XCTAssertEqual(queue.pending.map(\.scrobble.songID), ["bad"])
        XCTAssertEqual(queue.pending.first?.attempts, 1)
    }

    /// Last.fm can answer a 4xx whose body names a temporary condition (11 service offline,
    /// 16 temporarily unavailable, 29 rate limited). That stays temporary.
    func testALastFMTemporaryErrorUnderA4xxStaysTransient() throws {
        func failure(_ status: Int, _ body: String) throws -> ScrobbleError {
            try XCTUnwrap(MusicLastFM.failure(status: status, body: Data(body.utf8)))
        }
        XCTAssertTrue(ScrobbleService.isTransient(try failure(400, #"{"error":16,"message":"Service temporarily unavailable"}"#)))
        XCTAssertTrue(ScrobbleService.isTransient(try failure(403, #"{"error":29,"message":"Rate limit exceeded"}"#)))
        XCTAssertFalse(ScrobbleService.isTransient(try failure(403, #"{"error":9,"message":"Invalid session key"}"#)))
        XCTAssertFalse(ScrobbleService.isTransient(try failure(400, #"{"error":6,"message":"Invalid parameters"}"#)))
        XCTAssertFalse(ScrobbleService.isTransient(try failure(400, "not json")))
        XCTAssertTrue(ScrobbleService.isTransient(try failure(503, "")))
        XCTAssertNil(MusicLastFM.failure(status: 200, body: Data(#"{"scrobbles":{}}"#.utf8)))
    }
}

/// Answers 400 for any batch holding one song and accepts the rest.
// MARK: - TBX-1000000506

@MainActor
final class ScrobbleFollowUpPackageTests: XCTestCase {
    /// A credential rejection refuses the account, not one listen. Sent one by one, a batch of
    /// 50 made 50 refused requests every round (C2-8 note); it makes one now.
    func testACredentialRejectionStopsAfterOneRequest() async {
        let defaults = ThrowawayDefaults.make("scrobble-account-rejection")
        let queue = ScrobbleQueue(defaults: defaults)
        let lastfm = AccountRejectingDestination()
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let service = ScrobbleService(
            listenBrainz: RejectingDestination(id: "listenbrainz", active: false), lastfm: lastfm,
            navidrome: RejectingDestination(id: "navidrome", active: false),
            queue: queue, defaults: defaults, now: { clock }, monitorNetwork: false, autoFlush: false
        )
        for n in 0 ..< 10 {
            service.completed(NavidromeSong(id: "s\(n)", title: "s\(n)", artist: "A"), startedAt: clock.addingTimeInterval(Double(n)))
        }
        await service.flushAllAndWait()
        XCTAssertEqual(lastfm.requests, 2, "the batch, then one listen alone; not one request per listen")
        XCTAssertEqual(queue.pending.count, 10)
        XCTAssertEqual(Set(queue.pending.map(\.attempts)), [1], "each listen is charged one attempt")
    }

    /// A listen queued for one music server must not be delivered to another one (C2-21).
    func testAQueuedListenGoesOnlyToTheServerItWasHeardFrom() async {
        let defaults = ThrowawayDefaults.make("scrobble-server-scope")
        let queue = ScrobbleQueue(defaults: defaults)
        let server = ScopedDestination(scope: "server-a")
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let service = ScrobbleService(
            listenBrainz: RejectingDestination(id: "listenbrainz", active: false),
            lastfm: RejectingDestination(id: "lastfm", active: false), navidrome: server,
            queue: queue, defaults: defaults, now: { clock }, monitorNetwork: false, autoFlush: false
        )
        service.completed(NavidromeSong(id: "heard-on-a", title: "a", artist: "A"), startedAt: clock)
        server.scope = "server-b"
        service.completed(NavidromeSong(id: "heard-on-b", title: "b", artist: "A"), startedAt: clock.addingTimeInterval(1))
        await service.flushAllAndWait()
        XCTAssertEqual(server.delivered, ["heard-on-b"], "a listen from server A was credited to server B")
        XCTAssertEqual(queue.pending.map(\.scrobble.songID), ["heard-on-a"], "and it waits for server A")
    }
}

private final class AccountRejectingDestination: ScrobbleDestination {
    let destinationID = "lastfm"
    let isActive = true
    let maxBatch = 50
    private(set) var requests = 0
    func sendNowPlaying(_ scrobble: Scrobble) async {}
    func submit(_ batch: [Scrobble]) async throws {
        requests += 1
        throw ScrobbleError.http(401)
    }
}

private final class ScopedDestination: ScrobbleDestination {
    let destinationID = "navidrome"
    let isActive = true
    let maxBatch = 1
    var scope: String
    var queueScope: String? { scope }
    private(set) var delivered: [String] = []
    init(scope: String) { self.scope = scope }
    func sendNowPlaying(_ scrobble: Scrobble) async {}
    func submit(_ batch: [Scrobble]) async throws { delivered += batch.map(\.songID) }
}

private final class RejectingDestination: ScrobbleDestination {
    let destinationID: String
    let isActive: Bool
    let maxBatch: Int
    let rejectedSongID: String?
    private(set) var delivered: [String] = []

    init(id: String, active: Bool = true, rejectedSongID: String? = nil, maxBatch: Int = 1) {
        destinationID = id
        isActive = active
        self.rejectedSongID = rejectedSongID
        self.maxBatch = maxBatch
    }

    func sendNowPlaying(_ scrobble: Scrobble) async {}

    func submit(_ batch: [Scrobble]) async throws {
        if batch.contains(where: { $0.songID == rejectedSongID }) { throw ScrobbleError.http(400) }
        delivered += batch.map(\.songID)
    }
}
