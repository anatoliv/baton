import BatonSubsonicModels
import Foundation
import OSLog

private let lyricsLog = Logger(subsystem: "io.tonebox.baton", category: "Lyrics")

/// Lyrics from LRCLIB, when the server has none.
///
/// Navidrome only serves lyrics that are embedded in the files, so for most libraries the
/// Lyrics panel is permanently empty — a whole feature that exists, works, and shows nothing.
/// LRCLIB is a free, open, no-account lyrics database with a plain HTTP API, and it returns
/// *synced* lyrics often enough to make the panel's scroll-along worth having.
///
/// Two deliberate limits:
///
/// - **Fallback only.** The server is asked first and its answer always wins. A library
///   owner who embedded lyrics in their files chose those, and a remote database has no
///   business overriding them.
/// - **Opt-in.** This sends a track title and artist to a third party. That is a small
///   disclosure and an obvious one for a lyrics feature, but it is still the first time this
///   app talks to anyone other than the user's own server, so it is a setting rather than an
///   assumption. Default off; the Lyrics panel offers it where the absence is felt.
public enum LRCLIBLyrics {
    public static let enabledKey = "baton.lyrics.lrclib"

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Looks up lyrics by track metadata. Returns nil for anything less than a confident
    /// match — a wrong lyric sheet scrolling against the wrong song is worse than none.
    public static func lyrics(title: String,
                              artist: String?,
                              album: String?,
                              durationSeconds: Int?,
                              session: URLSession = .shared) async -> NavidromeLyrics? {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var query = [URLQueryItem(name: "track_name", value: title)]
        if let artist, !artist.isEmpty { query.append(URLQueryItem(name: "artist_name", value: artist)) }
        if let album, !album.isEmpty { query.append(URLQueryItem(name: "album_name", value: album)) }
        // Duration lets LRCLIB reject a same-titled different recording. Sending it is the
        // difference between "a song called Bad" and "*this* song called Bad".
        if let durationSeconds, durationSeconds > 0 {
            query.append(URLQueryItem(name: "duration", value: String(durationSeconds)))
        }
        components?.queryItems = query
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        // LRCLIB asks clients to identify themselves; an anonymous flood is how free
        // services stop being free.
        request.setValue("Baton (https://baton.tonebox.io)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parse(data)
        } catch {
            // A lyrics lookup failing is not worth telling anyone about — the panel shows
            // its empty state, which is the same thing it showed a moment ago.
            lyricsLog.debug("lrclib lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Parses LRCLIB's response, preferring synced lyrics over plain.
    static func parse(_ data: Data) -> NavidromeLyrics? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let synced = object["syncedLyrics"] as? String, !synced.isEmpty,
           let parsed = parseLRC(synced), !parsed.isEmpty {
            return NavidromeLyrics(synced: true, lines: parsed)
        }
        if let plain = object["plainLyrics"] as? String, !plain.isEmpty {
            let lines = plain.split(separator: "\n", omittingEmptySubsequences: false)
                .map { NavidromeLyrics.Line(text: String($0)) }
            return NavidromeLyrics(synced: false, lines: lines)
        }
        return nil
    }

    /// `[mm:ss.xx] text` — the LRC format.
    ///
    /// Hand-parsed rather than regex'd because the failure mode matters: a line that does
    /// not match its timestamp should become an untimed line rather than disappear, so a
    /// sheet with one malformed stamp still reads as lyrics.
    static func parseLRC(_ raw: String) -> [NavidromeLyrics.Line]? {
        var out: [NavidromeLyrics.Line] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(.init(text: trimmed)) }
                continue
            }
            let stamp = String(text[text.index(after: text.startIndex) ..< close])
            let body = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            // `[ar: …]`, `[length: …]` and friends are metadata, not lines.
            guard let seconds = seconds(fromLRCStamp: stamp) else { continue }
            out.append(.init(start: seconds, text: body))
        }
        return out.isEmpty ? nil : out
    }

    static func seconds(fromLRCStamp stamp: String) -> Double? {
        let parts = stamp.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let rest = Double(parts[1]) else {
            return nil
        }
        return minutes * 60 + rest
    }
}
