import Foundation

private let radioLog = Logger(subsystem: "io.tonebox.baton", category: "NavidromeRadio")

// MARK: - Internet radio (Subsonic)

//
// Subsonic exposes a handful of internet-radio endpoints that let a user keep a
// list of raw stream URLs on the server (ICY/MP3/AAC shoutcast-style streams),
// separate from the music library. Unlike a `stream.view` URL, a station's
// `streamUrl` is played directly by an audio player — there's no song id and no
// per-request signing (the stream is the station's own public/authenticated URL).
//
// These mirror the existing `NavidromeClient` idiom: signed JSON requests through
// `performJSON`, small `Codable`/domain value types, `async/await` throughout.

/// One internet-radio station kept on the Navidrome server. `streamUrl` is a raw
/// audio stream (not a Subsonic `stream.view` URL), played directly by an audio
/// player. `homepageUrl` is the optional station website.
public struct NavidromeRadioStation: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let streamUrl: String
    public let homepageUrl: String?

    public init(id: String, name: String, streamUrl: String, homepageUrl: String? = nil) {
        self.id = id
        self.name = name
        self.streamUrl = streamUrl
        self.homepageUrl = homepageUrl
    }

    /// The playable stream URL, or nil when the stored value isn't a valid URL.
    public var streamURL: URL? {
        URL(string: streamUrl.trimmingCharacters(in: .whitespaces))
    }
}

extension NavidromeClient {
    /// All internet-radio stations saved on the server (`getInternetRadioStations`).
    public func getInternetRadioStations() async throws -> [NavidromeRadioStation] {
        let response = try await performRadioJSON("getInternetRadioStations.view", retry: true)
        return (response.internetRadioStations?.internetRadioStation ?? []).map { $0.toDomain() }
    }

    /// Creates a station (`createInternetRadioStation`). `streamUrl` + `name` are
    /// required; `homepageUrl` is optional. Subsonic returns an empty OK body, so
    /// callers refetch the list to pick up the server-assigned id.
    public func createInternetRadioStation(name: String, streamUrl: String, homepageUrl: String? = nil) async throws {
        var query = [
            URLQueryItem(name: "streamUrl", value: streamUrl),
            URLQueryItem(name: "name", value: name),
        ]
        if let homepageUrl, !homepageUrl.isEmpty {
            query.append(URLQueryItem(name: "homepageUrl", value: homepageUrl))
        }
        _ = try await performRadioJSON("createInternetRadioStation.view", retry: false, query: query)
    }

    /// Updates an existing station (`updateInternetRadioStation`). `id`, `streamUrl`
    /// and `name` are all required by the spec; `homepageUrl` is optional.
    public func updateInternetRadioStation(
        id: String,
        name: String,
        streamUrl: String,
        homepageUrl: String? = nil
    ) async throws {
        var query = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "streamUrl", value: streamUrl),
            URLQueryItem(name: "name", value: name),
        ]
        if let homepageUrl, !homepageUrl.isEmpty {
            query.append(URLQueryItem(name: "homepageUrl", value: homepageUrl))
        }
        _ = try await performRadioJSON("updateInternetRadioStation.view", retry: false, query: query)
    }

    /// Deletes a station by id (`deleteInternetRadioStation`).
    public func deleteInternetRadioStation(id: String) async throws {
        _ = try await performRadioJSON("deleteInternetRadioStation.view", retry: false, query: [
            URLQueryItem(name: "id", value: id),
        ])
    }

    // MARK: - Transport

    /// The shared transport, decoding into the radio-specific envelope.
    ///
    /// Was a hand-copied transport that had lost the 401/403 mapping to `.unauthorized` and the
    /// single retry, exactly as the podcast copy had: the Radio tab said "The music server
    /// returned HTTP 401" where every other screen said to check the credentials, and it alone
    /// failed on a LAN blip. Only the envelope was ever radio-specific.
    private func performRadioJSON(_ endpoint: String, retry: Bool,
                                  query: [URLQueryItem] = []) async throws -> RadioSubsonicResponse {
        try await performEnvelope(endpoint, retry: retry, query: query,
                                  as: RadioSubsonicEnvelope.self, log: radioLog)
    }
}

// MARK: - Wire types

/// Radio-specific Subsonic envelope — a slim sibling of the shared `SubsonicEnvelope`
/// that carries only the internet-radio body (plus status/error). Kept local so the
/// shared response type doesn't need to grow a field for this feature.
public struct RadioSubsonicEnvelope: SubsonicEnvelopeWire {
    public let response: RadioSubsonicResponse
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

public struct RadioSubsonicResponse: SubsonicResponseWire {
    public let status: String
    public let error: SubsonicWireError?
    public let internetRadioStations: InternetRadioStationsWire?
}

/// `getInternetRadioStations` → `internetRadioStations.internetRadioStation[]`.
public struct InternetRadioStationsWire: Decodable {
    public let internetRadioStation: [InternetRadioStationWire]?
}

public struct InternetRadioStationWire: Decodable {
    public let id: String
    public let name: String?
    public let streamUrl: String?
    /// Subsonic spec spells this `homePageUrl`; some servers send `homepageUrl`.
    /// Accept either so a station's website survives a round-trip.
    public let homePageUrl: String?
    public let homepageUrl: String?

    public func toDomain() -> NavidromeRadioStation {
        NavidromeRadioStation(
            id: id,
            name: name ?? "(untitled station)",
            streamUrl: streamUrl ?? "",
            homepageUrl: homePageUrl ?? homepageUrl
        )
    }
}
