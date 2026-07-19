import Foundation

// MARK: - Neutral podcast domain (client-side)

//
// Baton's *client-side* podcasts subscribe to RSS feeds directly, independent of the music
// server — this is how Navidrome users get podcasts at all, since Navidrome doesn't implement
// the Subsonic podcast API. These types deliberately carry *direct* enclosure/image URLs (not
// Subsonic ids), so an episode plays straight from its feed and cover art loads from the web —
// the opposite of the server-side `NavidromePodcast*` types, which resolve everything through
// the Subsonic client.

/// A subscribed podcast show, parsed from its RSS feed. Identity is the feed URL, so
/// re-subscribing to the same feed updates in place rather than duplicating.
struct PodcastChannel: Identifiable, Hashable, Codable {
    /// Stable identity = the feed URL string.
    var id: String { feedURL.absoluteString }
    let feedURL: URL
    var title: String
    var description: String?
    var imageURL: URL?
    var episodes: [PodcastEpisode]
    /// When the feed was last successfully fetched (for "Updated …" and refresh ordering).
    var lastRefreshed: Date?
}

/// One episode from a feed. Unlike the server-side type, every episode here is immediately
/// playable — it carries its own `enclosureURL` (the audio file) with no download step.
struct PodcastEpisode: Identifiable, Hashable, Codable {
    /// The feed's `<guid>`, falling back to the enclosure URL when a feed omits it.
    let id: String
    var title: String
    var description: String?
    var publishDate: Date?
    /// Episode length in whole seconds, when the feed reports `<itunes:duration>`.
    var duration: Int?
    /// The audio file to stream/download — played directly by `AVPlayer`.
    var enclosureURL: URL
    /// Episode-specific art (`<itunes:image>`); the UI falls back to the channel's when absent.
    var imageURL: URL?
}

// MARK: - Feed parsing

/// The channel-level metadata + episodes parsed out of an RSS document, before a `feedURL`
/// (identity) is attached by the subscription store.
struct ParsedPodcastFeed: Equatable {
    var title: String
    var description: String?
    var imageURL: URL?
    var episodes: [PodcastEpisode]
}

enum PodcastFeedError: Error, LocalizedError, Equatable {
    /// The document didn't parse as XML, or carried no `<channel>`/`<item>`s we could use.
    case invalidFeed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidFeed(detail): "That doesn't look like a podcast feed: \(detail)"
        }
    }
}

/// Parses an RSS 2.0 + iTunes-namespace podcast document into a `ParsedPodcastFeed`.
///
/// A streaming `XMLParser` (SAX) rather than a DOM: podcast feeds run to hundreds of episodes
/// and we only keep a handful of fields per item. Namespace processing is left *off* so
/// iTunes elements arrive as their qualified names (`itunes:duration`, `itunes:image`), which
/// is how feeds actually write them.
enum PodcastFeedParser {
    static func parse(_ data: Data) throws -> ParsedPodcastFeed {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw PodcastFeedError.invalidFeed(parser.parserError?.localizedDescription ?? "unparseable XML")
        }
        guard delegate.sawChannel else {
            throw PodcastFeedError.invalidFeed("no <channel> element")
        }
        return ParsedPodcastFeed(
            title: delegate.channelTitle.trimmedNonEmpty ?? "(untitled podcast)",
            description: delegate.channelDescription.trimmedNonEmpty,
            imageURL: delegate.channelImageURL,
            // Episodes without a playable enclosure can't be streamed — drop them. Newest first.
            episodes: delegate.episodes
                .compactMap { $0.build() }
                .sorted { ($0.publishDate ?? .distantPast) > ($1.publishDate ?? .distantPast) }
        )
    }

    // MARK: - SAX delegate

    /// A mutable episode under construction as the parser walks one `<item>`.
    private struct EpisodeDraft {
        var title = ""
        var description = ""
        var summary = ""
        var guid = ""
        var pubDate = ""
        var durationRaw = ""
        var enclosure: URL?
        var imageURL: URL?

        /// Materializes a `PodcastEpisode`, or nil when the item has no audio enclosure.
        func build() -> PodcastEpisode? {
            guard let enclosure else { return nil }
            let text = description.trimmedNonEmpty ?? summary.trimmedNonEmpty
            return PodcastEpisode(
                id: guid.trimmedNonEmpty ?? enclosure.absoluteString,
                title: title.trimmedNonEmpty ?? "(untitled episode)",
                description: text.map(stripHTML),
                publishDate: parseRFC822(pubDate),
                duration: parseDuration(durationRaw),
                enclosureURL: enclosure,
                imageURL: imageURL
            )
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var sawChannel = false
        var channelTitle = ""
        var channelDescription = ""
        var channelImageURL: URL?

        var episodes: [EpisodeDraft] = []

        /// Text accumulator for the element currently being read (reset on each start tag;
        /// XML may deliver character data in several callbacks).
        private var buffer = ""
        /// True between `<item>` and `</item>` — routes text/attrs to the current draft.
        private var inItem = false
        private var draft = EpisodeDraft()
        /// True inside the channel's `<image>` wrapper, so its `<url>` isn't mistaken for
        /// anything else.
        private var inChannelImage = false

        func parser(
            _ parser: XMLParser, didStartElement element: String,
            namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]
        ) {
            buffer = ""
            switch element {
            case "channel":
                sawChannel = true
            case "item":
                inItem = true
                draft = EpisodeDraft()
            case "image" where !inItem:
                inChannelImage = true
            case "enclosure":
                if inItem, let url = attrs["url"].flatMap(cleanURL) { draft.enclosure = url }
            case "itunes:image":
                if let url = attrs["href"].flatMap(cleanURL) {
                    if inItem { draft.imageURL = url } else if channelImageURL == nil { channelImageURL = url }
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let string = String(data: CDATABlock, encoding: .utf8) { buffer += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement element: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            let text = buffer
            if inItem {
                switch element {
                case "title": draft.title = text
                case "description", "content:encoded": draft.description = text
                case "itunes:summary": draft.summary = text
                case "guid": draft.guid = text
                case "pubDate": draft.pubDate = text
                case "itunes:duration": draft.durationRaw = text
                case "item":
                    episodes.append(draft)
                    inItem = false
                default: break
                }
            } else {
                switch element {
                case "title": if channelTitle.isEmpty { channelTitle = text }
                case "description": if channelDescription.isEmpty { channelDescription = text }
                case "url" where inChannelImage: if channelImageURL == nil { channelImageURL = cleanURL(text) }
                case "image": inChannelImage = false
                default: break
                }
            }
            buffer = ""
        }
    }
}

// MARK: - Field helpers

extension PodcastFeedParser {
    /// Parses `<itunes:duration>` — either whole seconds ("1830") or a clock string
    /// ("30:30" / "1:02:03"). Returns nil when neither shape fits.
    static func parseDuration(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":").map { Int($0) ?? -1 }
            guard !parts.contains(-1) else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        return Int(trimmed)
    }

    /// Parses an RFC-822 `<pubDate>` (the podcast standard, e.g. "Mon, 13 Jul 2026 09:00:00 GMT").
    static func parseRFC822(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Trims and validates an http(s) URL string; nil for anything else (mailto:, blank, …).
    static func cleanURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Lightweight tag strip so show-notes render as plain text (feeds embed HTML in
    /// descriptions). Collapses runs of whitespace left behind.
    static func stripHTML(_ raw: String) -> String {
        let noTags = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return decoded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    /// The trimmed string, or nil when it's empty after trimming.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? { self?.trimmedNonEmpty }
}
