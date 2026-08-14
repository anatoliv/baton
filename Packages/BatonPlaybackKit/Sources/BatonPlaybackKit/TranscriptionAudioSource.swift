import Foundation
import OSLog
import BatonSubsonicKit
import BatonSubsonicModels

/// Where the bytes to transcribe come from for a given track.
///
/// Three cases, and the order matters: a downloaded file costs nothing, a client-side podcast
/// episode already carries its own remote URL as its id (so it needs no server round trip at
/// all), and only a library track has to be resolved through the Navidrome client.
///
/// See `specs/track-transcription.md`.
public enum TranscriptionAudioSource: Equatable, Sendable {
    /// Already a file on this device — a download, or the bundled demo library. Nothing to fetch.
    case local(URL)
    /// Must be fetched before it can be uploaded.
    case remote(URL)

    public struct ResolveError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// Resolve a track to its audio.
    ///
    /// Asks for the **original file** (`download.view`) rather than the stream, for the same
    /// reason offline downloads do: `streamURL` transcodes to MP3 at the server's default
    /// bitrate, and there is no sense feeding a recognizer a lossy re-encode when the source
    /// is right there.
    @MainActor
    public static func resolve(
        song: NavidromeSong,
        downloads: MusicDownloadStore = .shared,
        client: NavidromeClient?
    ) throws -> TranscriptionAudioSource {
        if let local = downloads.localURL(for: song.id) {
            return .local(local)
        }
        switch song.mediaKind {
        case .localFile:
            guard let url = URL(string: song.id), url.isFileURL else {
                throw ResolveError(message: "This track's file couldn't be located on disk.")
            }
            return .local(url)
        case .podcastEpisode:
            // The id IS the enclosure URL — no server involved.
            guard let url = URL(string: song.id) else {
                throw ResolveError(message: "This episode's audio address is malformed.")
            }
            return .remote(url)
        case .libraryTrack:
            guard let client else {
                throw ResolveError(message: "Not connected to a server, so this track's audio can't be fetched.")
            }
            do {
                return .remote(try client.downloadURL(songID: song.id))
            } catch {
                throw ResolveError(message: "Couldn't build a download URL for this track: \(error.localizedDescription)")
            }
        }
    }

    /// Produce a local file to hand the recognizer, fetching first if necessary.
    ///
    /// The returned flag says whether the caller owns the file and must delete it. A download
    /// the user chose to keep is not ours to clean up; a temporary fetch is.
    public func materialize(session: URLSession = .shared) async throws -> (url: URL, isTemporary: Bool) {
        switch self {
        case let .local(url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ResolveError(message: "The downloaded file for this track has gone missing.")
            }
            return (url, false)
        case let .remote(url):
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("baton-transcribe-source-\(UUID().uuidString)")
                .appendingPathExtension(url.pathExtension.isEmpty ? "audio" : url.pathExtension)
            do {
                // `download` streams to disk rather than holding an hour of audio in memory.
                let (downloaded, response) = try await session.download(from: url)
                if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: downloaded)
                    throw ResolveError(message: "Fetching the audio failed (HTTP \(http.statusCode)).")
                }
                try? FileManager.default.removeItem(at: temp)
                try FileManager.default.moveItem(at: downloaded, to: temp)
            } catch let error as ResolveError {
                throw error
            } catch {
                throw ResolveError(message: "Couldn't fetch this track's audio: \(error.localizedDescription)")
            }
            return (temp, true)
        }
    }
}
