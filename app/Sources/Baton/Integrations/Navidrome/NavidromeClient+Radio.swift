import Foundation

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
struct NavidromeRadioStation: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let streamUrl: String
    let homepageUrl: String?

    /// The playable stream URL, or nil when the stored value isn't a valid URL.
    var streamURL: URL? {
        URL(string: streamUrl.trimmingCharacters(in: .whitespaces))
    }
}

extension NavidromeClient {
    /// All internet-radio stations saved on the server (`getInternetRadioStations`).
    func getInternetRadioStations() async throws -> [NavidromeRadioStation] {
        let response = try await performRadioJSON("getInternetRadioStations.view")
        return (response.internetRadioStations?.internetRadioStation ?? []).map { $0.toDomain() }
    }

    /// Creates a station (`createInternetRadioStation`). `streamUrl` + `name` are
    /// required; `homepageUrl` is optional. Subsonic returns an empty OK body, so
    /// callers refetch the list to pick up the server-assigned id.
    func createInternetRadioStation(name: String, streamUrl: String, homepageUrl: String? = nil) async throws {
        var query = [
            URLQueryItem(name: "streamUrl", value: streamUrl),
            URLQueryItem(name: "name", value: name),
        ]
        if let homepageUrl, !homepageUrl.isEmpty {
            query.append(URLQueryItem(name: "homepageUrl", value: homepageUrl))
        }
        _ = try await performRadioJSON("createInternetRadioStation.view", query: query)
    }

    /// Updates an existing station (`updateInternetRadioStation`). `id`, `streamUrl`
    /// and `name` are all required by the spec; `homepageUrl` is optional.
    func updateInternetRadioStation(
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
        _ = try await performRadioJSON("updateInternetRadioStation.view", query: query)
    }

    /// Deletes a station by id (`deleteInternetRadioStation`).
    func deleteInternetRadioStation(id: String) async throws {
        _ = try await performRadioJSON("deleteInternetRadioStation.view", query: [
            URLQueryItem(name: "id", value: id),
        ])
    }

    // MARK: - Transport

    /// Runs a signed JSON request and decodes it into the radio-specific envelope.
    ///
    /// The base `NavidromeClient` funnels its endpoints through a `private
    /// performJSON` that decodes into a shared `SubsonicResponse` — which doesn't
    /// carry the internet-radio body. Rather than widen that shared type, radio
    /// requests decode into their own `RadioSubsonicEnvelope` here, reusing the
    /// client's `makeURL` signing + `session` and applying the same error mapping
    /// (`unauthorized` for 40/41/44, `subsonic` otherwise).
    private func performRadioJSON(_ endpoint: String, query: [URLQueryItem] = []) async throws -> RadioSubsonicResponse {
        let url = try makeURL(endpoint, query: query)
        var request = URLRequest(url: url)
        request.setValue("Baton (macOS; Navidrome-Integration)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NavidromeError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NavidromeError.transport("Non-HTTP response")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw NavidromeError.http(status: http.statusCode)
        }

        let envelope: RadioSubsonicEnvelope
        do {
            envelope = try JSONDecoder().decode(RadioSubsonicEnvelope.self, from: data)
        } catch {
            throw NavidromeError.decoding(error.localizedDescription)
        }
        let subsonic = envelope.response
        guard subsonic.status == "ok" else {
            let code = subsonic.error?.code ?? -1
            let message = subsonic.error?.message ?? "Unknown error"
            if code == 40 || code == 41 || code == 44 {
                throw NavidromeError.unauthorized
            }
            throw NavidromeError.subsonic(code: code, message: message)
        }
        return subsonic
    }
}

// MARK: - Wire types

/// Radio-specific Subsonic envelope — a slim sibling of the shared `SubsonicEnvelope`
/// that carries only the internet-radio body (plus status/error). Kept local so the
/// shared response type doesn't need to grow a field for this feature.
struct RadioSubsonicEnvelope: Decodable {
    let response: RadioSubsonicResponse
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct RadioSubsonicResponse: Decodable {
    let status: String
    let error: SubsonicWireError?
    let internetRadioStations: InternetRadioStationsWire?
}

/// `getInternetRadioStations` → `internetRadioStations.internetRadioStation[]`.
struct InternetRadioStationsWire: Decodable {
    let internetRadioStation: [InternetRadioStationWire]?
}

struct InternetRadioStationWire: Decodable {
    let id: String
    let name: String?
    let streamUrl: String?
    /// Subsonic spec spells this `homePageUrl`; some servers send `homepageUrl`.
    /// Accept either so a station's website survives a round-trip.
    let homePageUrl: String?
    let homepageUrl: String?

    func toDomain() -> NavidromeRadioStation {
        NavidromeRadioStation(
            id: id,
            name: name ?? "(untitled station)",
            streamUrl: streamUrl ?? "",
            homepageUrl: homePageUrl ?? homepageUrl
        )
    }
}
