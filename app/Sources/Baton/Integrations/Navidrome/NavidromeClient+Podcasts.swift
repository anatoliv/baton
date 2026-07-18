import Foundation
import OSLog

private let podcastLog = Logger(subsystem: "io.tonebox.macos", category: "NavidromePodcasts")

// MARK: - Domain types

//
// Podcast channels + episodes resolved from the Navidrome (Subsonic) library. Like the
// other domain types in `NavidromeModels.swift`, these expose only the fields the UI and
// playback path need — not the full Subsonic podcast schema.

/// A subscribed podcast channel (`getPodcasts` → `podcasts.channel[]`).
struct NavidromePodcastChannel: Identifiable, Hashable {
    let id: String
    let title: String
    /// Channel description / show notes, when the server provides one.
    let description: String?
    /// Cover-art id (feed to `coverArtURL(id:)`), when present.
    let coverArtID: String?
    /// The channel's original RSS feed URL, when the server reports it.
    let url: String?
    /// The channel's episodes, newest first. Populated only when the request asks for
    /// `includeEpisodes` (the plain channel list leaves it empty).
    var episodes: [NavidromePodcastEpisode] = []
}

/// One podcast episode (`podcasts.channel[].episode[]` / `getNewestPodcasts`).
struct NavidromePodcastEpisode: Identifiable, Hashable {
    /// The episode's own id. Note this is NOT the streamable media id — use `streamID`
    /// (Subsonic `streamId`) to play the episode; it maps to a `getSong` / `stream` id.
    let id: String
    let title: String
    /// Episode notes / description, when present.
    let description: String?
    /// Publish date as the server's raw ISO-8601 string, when present.
    let publishDate: String?
    /// Episode length in whole seconds, when the server reports it.
    let duration: Int?
    /// The media id to stream (Subsonic `streamId`). Only "completed"/downloaded
    /// episodes carry one; a nil `streamID` isn't yet playable.
    let streamID: String?
    /// Cover-art id (falls back to the channel's art in the UI when absent).
    let coverArtID: String?
    /// Server download status — e.g. "completed", "downloading", "skipped", "new".
    let status: String?

    /// Whether this episode has a streamable media id — the only ones that can play.
    var isPlayable: Bool { streamID != nil }
}

// MARK: - Podcast endpoints

extension NavidromeClient {
    /// Subscribed podcast channels (`getPodcasts`). Pass `includeEpisodes: true` to get
    /// each channel's episodes inline (newest first); the default returns channels only.
    func getPodcasts(includeEpisodes: Bool = false) async throws -> [NavidromePodcastChannel] {
        let response = try await performPodcastJSON("getPodcasts.view", query: [
            URLQueryItem(name: "includeEpisodes", value: includeEpisodes ? "true" : "false"),
        ])
        return (response.podcasts?.channel ?? []).map { $0.toDomain() }
    }

    /// One channel with its episodes (`getPodcasts` filtered to a single `id`,
    /// `includeEpisodes=true`). Returns nil if the server doesn't know the channel.
    func getPodcastChannel(id: String) async throws -> NavidromePodcastChannel? {
        let response = try await performPodcastJSON("getPodcasts.view", query: [
            URLQueryItem(name: "includeEpisodes", value: "true"),
            URLQueryItem(name: "id", value: id),
        ])
        return (response.podcasts?.channel ?? []).map { $0.toDomain() }.first
    }

    /// The most recently published episodes across all channels (`getNewestPodcasts`).
    func getNewestPodcasts(count: Int = 20) async throws -> [NavidromePodcastEpisode] {
        let response = try await performPodcastJSON("getNewestPodcasts.view", query: [
            URLQueryItem(name: "count", value: String(count)),
        ])
        return (response.newestPodcasts?.episode ?? []).map { $0.toDomain() }
    }

    // MARK: - Transport (podcast envelope)

    /// A copy of the client's JSON transport specialized to the podcast envelope. The
    /// shared `performJSON` decodes a fixed `SubsonicResponse` that (deliberately) doesn't
    /// carry the podcast bodies, so podcast requests decode into `PodcastSubsonicResponse`
    /// here instead. Same signing (`makeURL`), status/HTTP checks, and error mapping.
    private func performPodcastJSON(_ endpoint: String, query: [URLQueryItem] = []) async throws -> PodcastSubsonicResponse {
        let url = try makeURL(endpoint, query: query)
        var request = URLRequest(url: url)
        request.setValue("Tonebox (macOS; Navidrome-Integration)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            podcastLog.error("\(endpoint, privacy: .public) transport failed: \(error.localizedDescription, privacy: .public)")
            throw NavidromeError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NavidromeError.transport("Non-HTTP response")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw NavidromeError.http(status: http.statusCode)
        }

        let envelope: PodcastSubsonicEnvelope
        do {
            envelope = try JSONDecoder().decode(PodcastSubsonicEnvelope.self, from: data)
        } catch {
            podcastLog.error("\(endpoint, privacy: .public): decode failed: \(error.localizedDescription, privacy: .public)")
            throw NavidromeError.decoding(error.localizedDescription)
        }
        let subsonic = envelope.response
        guard subsonic.isOK else {
            let code = subsonic.error?.code ?? -1
            let message = subsonic.error?.message ?? "Unknown error"
            podcastLog.error("\(endpoint, privacy: .public): Subsonic error \(code, privacy: .public) — \(message, privacy: .public)")
            if code == 40 || code == 41 || code == 44 { throw NavidromeError.unauthorized }
            throw NavidromeError.subsonic(code: code, message: message)
        }
        return subsonic
    }
}

// MARK: - Wire types (podcast envelope)

//
// Podcast responses reuse the same `{ "subsonic-response": { ... } }` envelope but carry
// bodies (`podcasts`, `newestPodcasts`) absent from the shared `SubsonicResponse`. A
// parallel envelope keeps the podcast schema self-contained in this file — the disjoint
// constraint that podcast code only lives in new files — while sharing the `error`/`status`
// contract with the rest of the client.

struct PodcastSubsonicEnvelope: Decodable {
    let response: PodcastSubsonicResponse
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct PodcastSubsonicResponse: Decodable {
    let status: String
    let error: SubsonicWireError?
    let podcasts: PodcastsWire?
    let newestPodcasts: NewestPodcastsWire?

    var isOK: Bool { status == "ok" }
}

/// `getPodcasts` → `podcasts.channel[]`.
struct PodcastsWire: Decodable {
    let channel: [PodcastChannelWire]?
}

struct PodcastChannelWire: Decodable {
    let id: String
    let title: String?
    let description: String?
    let coverArt: String?
    let url: String?
    let episode: [PodcastEpisodeWire]?

    func toDomain() -> NavidromePodcastChannel {
        NavidromePodcastChannel(
            id: id,
            title: (title?.isEmpty == false ? title : nil) ?? "(untitled)",
            description: PodcastEpisodeWire.cleaned(description),
            coverArtID: coverArt,
            url: url,
            // Episodes newest first — servers order oldest→newest, so reverse to match
            // "getNewestPodcasts" and the UI's "latest at top" expectation.
            episodes: (episode ?? []).map { $0.toDomain() }.sorted { lhs, rhs in
                (lhs.publishDate ?? "") > (rhs.publishDate ?? "")
            }
        )
    }
}

/// `getNewestPodcasts` → `newestPodcasts.episode[]`.
struct NewestPodcastsWire: Decodable {
    let episode: [PodcastEpisodeWire]?
}

struct PodcastEpisodeWire: Decodable {
    let id: String
    let title: String?
    let description: String?
    let publishDate: String?
    let duration: Int?
    let streamId: String?
    let coverArt: String?
    let status: String?

    func toDomain() -> NavidromePodcastEpisode {
        NavidromePodcastEpisode(
            id: id,
            title: (title?.isEmpty == false ? title : nil) ?? "(untitled)",
            description: Self.cleaned(description),
            publishDate: publishDate,
            duration: duration,
            // Only completed episodes have a stream id; a blank one means "not playable".
            streamID: (streamId?.isEmpty == false) ? streamId : nil,
            coverArtID: coverArt,
            status: status
        )
    }

    /// Trims whitespace and treats an empty string as absent — show-notes fields are
    /// frequently present-but-blank.
    static func cleaned(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
