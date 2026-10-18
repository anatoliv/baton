import AVFoundation
import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

@MainActor
final class StoredM4ASeekTests: XCTestCase {
    func testSeekPastTheSpoolRetainsTheContainerIndexAndFetchesTheTarget() async throws {
        try await exerciseSeek(delivery: .rangeCapable(bytesPerSecond: 10_000))
    }

    func testIndexedSeekStillPlaysWhenTheServerIgnoresRange() async throws {
        try await exerciseSeek(delivery: .ignoresRange(bytesPerSecond: 100_000))
    }

    func testSeekingBackBeforeTheNewSpoolReusesTheIndexAgain() async throws {
        try await exerciseSeek(delivery: .rangeCapable(bytesPerSecond: 10_000), seekBack: true)
    }

    private func exerciseSeek(delivery: EngineHTTPServer.Delivery, seekBack: Bool = false) async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/stored-tone.m4a", withExtension: nil))
        let data = try Data(contentsOf: fixture)
        let server = try EngineHTTPServer(payload: data, delivery: delivery, contentType: "audio/mp4")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }
        var song = NavidromeSong(id: "stored-m4a", title: "tone", artist: "fixture", album: nil, duration: 80, coverArtID: nil)
        song.suffix = "m4a"
        harness.controller.play(.init(id: song.id, url: server.url, duration: 80, song: song, supportsTimeOffset: false))
        try await harness.waitUntil(timeout: 10) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 2
        }
        let source = try XCTUnwrap(harness.controller.sourceForTesting)
        let reachable = await source.reachableSeconds()?.upperBound ?? 0
        XCTAssertLessThan(reachable, 55, "the target must be beyond the downloaded prefix")
        harness.controller.seek(to: 55)
        try await harness.waitUntil(timeout: 5) { harness.controller.currentTime >= 55 }
        XCTAssertEqual(harness.controller.loadCountForTesting, 1, "retain the parsed M4A header instead of loading and decoding the entire prefix again")
        try await harness.waitUntil(timeout: 10) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1
        }
        let samples = try await harness.renderPaced(maxSeconds: 0.7)
        XCTAssertGreaterThan(EngineTestSignals.rms(samples), 0.001, "seek must render actual audio")
        XCTAssertTrue(server.requestedRangeStarts.contains { $0 > data.count / 2 }, "fetch the indexed target, not byte zero")
        XCTAssertGreaterThan(harness.controller.currentTime, 55.2)
        if seekBack {
            harness.controller.seek(to: 20)
            try await harness.waitUntil(timeout: 5) { abs(harness.controller.currentTime - 20) < 0.2 }
            XCTAssertEqual(harness.controller.loadCountForTesting, 1)
            try await harness.waitUntil(timeout: 10) {
                harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1
            }
            let backSamples = try await harness.renderPaced(maxSeconds: 0.7)
            XCTAssertGreaterThan(EngineTestSignals.rms(backSamples), 0.001)
            XCTAssertEqual(server.requestedRangeStarts.count, 2)
            XCTAssertLessThan(server.requestedRangeStarts[1], server.requestedRangeStarts[0])
        }
        harness.shutdown()
        try await harness.waitUntil(timeout: 5) { server.openConnections == 0 }
    }
}
