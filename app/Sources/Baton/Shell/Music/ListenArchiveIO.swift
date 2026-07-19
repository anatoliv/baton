import Foundation

/// Something the scrobble pipeline can hand a completed listen to for **local** logging — the
/// private, on-device archive (no network). Implemented by `MusicPlayHistory`.
@MainActor
protocol LocalListenRecording: AnyObject {
    func record(_ song: NavidromeSong, playedAt: Date)
}

/// One listen in the portable **ListenBrainz-compatible** wire shape. This is exactly the
/// object ListenBrainz uses in its listen exports/imports, so a file Baton writes can be fed to
/// ListenBrainz (and vice-versa) — your history stays private but never trapped.
struct PortableListen: Codable, Equatable {
    var listened_at: Int
    var track_metadata: Meta

    struct Meta: Codable, Equatable {
        var artist_name: String
        var track_name: String
        var release_name: String?
    }

    var artist: String { track_metadata.artist_name }
    var track: String { track_metadata.track_name }
    var album: String? { track_metadata.release_name }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(listened_at)) }
}

/// Reads and writes the local listen archive in portable formats. Pure functions (no I/O, no
/// UI) so the encode/decode is unit-testable; the views own the actual file dialogs.
enum ListenArchiveIO {
    // MARK: - Export

    /// A ListenBrainz-compatible JSON array (most-recent first), ready to write to a `.json` file.
    static func exportJSON(_ listens: [PortableListen]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(listens)) ?? Data("[]".utf8)
    }

    /// A spreadsheet-friendly CSV: `artist,track,album,listened_at` (ISO-8601 timestamps).
    static func exportCSV(_ listens: [PortableListen]) -> String {
        let formatter = ISO8601DateFormatter()
        var out = "artist,track,album,listened_at\n"
        for listen in listens {
            let cells = [listen.artist, listen.track, listen.album ?? "", formatter.string(from: listen.date)]
            out += cells.map(csvEscape).joined(separator: ",") + "\n"
        }
        return out
    }

    /// Quote a CSV cell only when it contains a comma, quote, or newline (doubling inner quotes).
    private static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Import

    /// Parse a ListenBrainz-style export back into listens. Accepts either a JSON **array** of
    /// listens or **JSONL** (one listen object per line) — both shapes ListenBrainz emits. Entries
    /// missing an artist/track are skipped. Returns `[]` on unrecognised input.
    static func parse(_ data: Data) -> [PortableListen] {
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([PortableListen].self, from: data) {
            return array.filter(isUsable)
        }
        // JSONL fallback: decode line by line, tolerating blank/garbage lines.
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [PortableListen] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let listen = try? decoder.decode(PortableListen.self, from: lineData),
                  isUsable(listen) else { continue }
            out.append(listen)
        }
        return out
    }

    private static func isUsable(_ listen: PortableListen) -> Bool {
        !listen.artist.trimmingCharacters(in: .whitespaces).isEmpty
            && !listen.track.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A stable synthetic id for an imported listen, so tracks bucket correctly in the stats even
    /// though we don't know the server's real media id. `\u{1}` can't occur in a name, so it's a
    /// safe field separator.
    static func syntheticID(artist: String, track: String) -> String {
        "import:\(artist)\u{1}\(track)"
    }
}
