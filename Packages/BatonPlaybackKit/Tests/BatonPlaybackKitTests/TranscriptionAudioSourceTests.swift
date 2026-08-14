import XCTest
@testable import BatonPlaybackKit
import BatonSubsonicModels

/// Where transcription gets its bytes: a download if there is one, the enclosure URL for a
/// client-side episode (no server involved), the original file for a library track.
/// See `specs/track-transcription.md`.
@MainActor
final class TranscriptionAudioSourceTests: XCTestCase {
    private func song(id: String, title: String = "Episode") -> NavidromeSong {
        NavidromeSong(id: id, title: title, artist: "Show", album: nil, duration: 3600)
    }

    func testAClientSidePodcastEpisodeResolvesToItsOwnEnclosureURL() throws {
        let url = "https://feeds.example.com/show/ep-42.mp3"
        let source = try TranscriptionAudioSource.resolve(
            song: song(id: url), downloads: MusicDownloadStore(), client: nil
        )
        XCTAssertEqual(source, .remote(URL(string: url)!), "the id IS the audio address — no server round trip")
    }

    func testALocalFileResolvesToItself() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("demo.mp3")
        let source = try TranscriptionAudioSource.resolve(
            song: song(id: file.absoluteString), downloads: MusicDownloadStore(), client: nil
        )
        XCTAssertEqual(source, .local(file))
    }

    /// A library track needs the server to build a signed URL, so without one this must fail
    /// with something a person can act on rather than silently producing nothing.
    func testALibraryTrackWithoutAServerFailsWithAReadableReason() {
        XCTAssertThrowsError(
            try TranscriptionAudioSource.resolve(
                song: song(id: "abc123"), downloads: MusicDownloadStore(), client: nil
            )
        ) { error in
            let message = (error as? TranscriptionAudioSource.ResolveError)?.message ?? ""
            XCTAssertTrue(message.contains("Not connected"), "got: \(message)")
        }
    }

    func testMaterializingALocalSourceDoesNotClaimOwnershipOfTheFile() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-audio-\(UUID().uuidString).mp3")
        try Data(repeating: 0x41, count: 16).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let (url, isTemporary) = try await TranscriptionAudioSource.local(file).materialize()
        XCTAssertEqual(url, file)
        XCTAssertFalse(isTemporary, "a download the user chose to keep is not ours to delete")
    }

    func testMaterializingAMissingLocalFileFailsRatherThanUploadingNothing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-not-here-\(UUID().uuidString).mp3")
        do {
            _ = try await TranscriptionAudioSource.local(missing).materialize()
            XCTFail("a missing file should throw")
        } catch let error as TranscriptionAudioSource.ResolveError {
            XCTAssertTrue(error.message.contains("missing"), "got: \(error.message)")
        } catch {
            XCTFail("expected ResolveError, got \(error)")
        }
    }
}
