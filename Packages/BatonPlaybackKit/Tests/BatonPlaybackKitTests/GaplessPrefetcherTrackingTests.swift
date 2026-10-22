import XCTest
@testable import BatonPlaybackKit

/// A prefetch reaped and started again for the same song: the first one finishing used to
/// remove the second's entry, so the second was no longer tracked, reaped or cancelled
/// (TBX-1000000506, C1-21).
@MainActor
final class GaplessPrefetcherTrackingTests: XCTestCase {
    func testAnOlderPrefetchFinishingDoesNotForgetTheNewerOne() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prefetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var calls = 0
        let prefetcher = GaplessPrefetcher(cache: MusicGaplessCache(directory: dir)) { url, _ in
            calls += 1
            let wait: Duration = calls == 1 ? .milliseconds(100) : .milliseconds(1_500)
            try? await Task.sleep(for: wait)
            return nil
        }
        let url = URL(string: "https://music.example/rest/stream.view?id=s")!
        prefetcher.prefetch(songID: "s", from: url, index: 1) { _, _, _ in }
        prefetcher.reap(keeping: nil)
        prefetcher.prefetch(songID: "s", from: url, index: 1) { _, _, _ in }
        try await Task.sleep(for: .milliseconds(500))   // the first has finished, the second has not
        XCTAssertTrue(prefetcher.isPrefetching("s"), "the running prefetch was forgotten")
        prefetcher.cancelAll()
    }
}
