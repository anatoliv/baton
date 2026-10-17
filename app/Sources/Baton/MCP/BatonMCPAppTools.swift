import BatonDocuments
import BatonPlaybackKit
import BatonShareKit
import BatonSubsonicKit
import Foundation

/// The rest of the app for an agent: books, clippings, podcasts, internet radio,
/// Later, history, downloads, shared links and mixtapes, handoff, spoken speed and a read of the
/// settings. `specs/mcp-coverage.md` maps every user-facing function to the tool that reaches it.
///
/// The rules every tool here keeps:
/// - **Read first.** Most tools only read. Those that change something say so in their
///   annotations, and the ones that delete, revoke, send outside this Mac or change the owner's
///   data take `confirm: true`: without it they change nothing and answer with what they would do.
/// - **Nothing secret leaves.** No share key, link fragment, token, feed or stream address, file
///   path or server address is in any answer. The one exception is `share_mixtape`, which returns
///   the link it has just made to the caller that asked for it, as `music_share` does.
/// - **MCP only.** These are published on the MCP server. The in-app chat and Siri keep the
///   catalog they were measured with (`MCPToolSurface` leaves these out).
@MainActor
enum BatonMCPAppTools {
    // MARK: - Names

    static let bookTools: Set<String> = ["books_list", "book_chapters", "book_play", "book_cast", "book_change_voice", "book_cover"]

    static let readOnlyNames: Set<String> = [
        "books_list", "book_chapters", "book_cast", "clippings_list", "podcasts_list", "podcast_episodes",
        "radio_list_stations", "later_list", "history", "downloads_list", "shares_list", "handoff_status",
        "settings_read",
    ]

    /// Delete, revoke or replace something the owner has: each takes `confirm: true`.
    static let destructiveNames: Set<String> = [
        "clipping_delete", "later_remove", "download_remove", "share_revoke", "book_cover", "podcast_unsubscribe",
    ]

    /// Reach past this Mac: the music server, a feed, the share service, the Baton server.
    static let openWorldNames: Set<String> = [
        "radio_list_stations", "radio_play_station", "podcast_subscribe", "download_songs", "share_revoke",
        "share_mixtape", "handoff_status", "handoff_save_queue", "handoff_accept", "book_change_voice",
        "later_add",
    ]

    static let names: Set<String> = Set(definitions(includeBooks: true).compactMap { $0["name"] as? String })

    // MARK: - Definitions

    static func definitions(includeBooks: Bool) -> [[String: Any]] {
        var defs: [[String: Any]] = []
        if includeBooks {
            defs += [
                tool("books_list", "The books in Books: title, author, chapters made and to come, where the listener is (chapter and seconds), finished, where each was made, its narrator and whether it has a cover and a cast. Read-only.", [:]),
                tool("book_chapters", "One book's chapters: number, title, whether it is ready, being made or failed, and its length. Read-only.", ["book": bookArg]),
                tool("book_play", "Play a book in Books from where the listener is, or from a chosen chapter. Replaces the queue, as the book's Play does.", [
                    "book": bookArg,
                    "chapter": ["type": "integer", "description": "Chapter number (1-based) to start from. Omit to resume from the listener's place."],
                ]),
                tool("book_cast", "Who reads a book: its narrator's voice, and for a book whose dialogue is voiced, each character and their voice. Read-only.", ["book": bookArg]),
                tool("book_change_voice", "Make a book again in another narrator's voice (Change Voice…). The chapters already made keep playing until each new one is ready. Without confirm:true it only says what it would do.", [
                    "book": bookArg,
                    "voice": ["type": "string", "description": "The new narrator, an \"engine:voice\" spec such as kokoro:bf_emma."],
                    "confirm": confirmArg,
                ], required: ["voice"]),
                tool("book_cover", "Make a cover for a book from its title and author, or remove its cover. Either replaces what the book shows on every device. Without confirm:true it only says what it would do.", [
                    "book": bookArg,
                    "action": ["type": "string", "enum": ["make", "remove"], "description": "make: draw one from the title and author. remove: take the cover off."],
                    "confirm": confirmArg,
                ], required: ["action"]),
            ]
        }
        defs += [
            tool("clippings_list", "The saved readings in Clippings (not book chapters): title, where it came from, length, when it was saved, and whether its words are kept. Read-only.", [
                "limit": ["type": "integer", "description": "Most to return, newest first (default 50, max 200)."],
            ]),
            tool("clipping_play", "Play one clipping.", ["clipping": clippingArg], required: ["clipping"]),
            tool("clipping_delete", "Delete a clipping from this Mac, or from every device with everywhere:true. Without confirm:true it only says what it would do.", [
                "clipping": clippingArg,
                "everywhere": ["type": "boolean", "description": "Also delete the copy on the owner's other devices."],
                "confirm": confirmArg,
            ], required: ["clipping"]),
            tool("podcasts_list", "The podcasts the owner follows by feed, with how many episodes are unplayed. Read-only.", [:]),
            tool("podcast_episodes", "A show's episodes, newest first, with length, date and how far the owner got. Read-only.", [
                "show": showArg,
                "limit": ["type": "integer", "description": "Most to return (default 20, max 100)."],
            ], required: ["show"]),
            tool("podcast_play_episode", "Play an episode of a followed show. Without `episode`, the newest one not yet played.", [
                "show": showArg,
                "episode": ["type": "string", "description": "The episode's id from podcast_episodes, or part of its title."],
            ], required: ["show"]),
            tool("podcast_subscribe", "Follow a podcast by its RSS feed address. Its feed is fetched, and the show appears on the owner's other devices too. Without confirm:true it only says what it would do.", [
                "feed_url": ["type": "string", "description": "The show's RSS feed address (http or https)."],
                "confirm": confirmArg,
            ], required: ["feed_url"]),
            tool("podcast_unsubscribe", "Stop following a show, on every device. Without confirm:true it only says what it would do.", [
                "show": showArg, "confirm": confirmArg,
            ], required: ["show"]),
            tool("radio_list_stations", "The internet radio stations saved on the music server, and which one is on air. Read-only.", [:]),
            tool("radio_play_station", "Play an internet radio station by name or id.", [
                "station": ["type": "string", "description": "The station's name (or part of it) or id."],
            ], required: ["station"]),
            tool("later_list", "Later: the songs, albums, artists, playlists, episodes, shows and stations the owner saved to get to. Read-only.", [:]),
            tool("later_add", "Save a song to Later. Without `query`, the song playing now.", [
                "query": ["type": "string", "description": "Song to save; the top search match is used. Omit for the current track."],
            ]),
            tool("later_remove", "Take something off Later. Without confirm:true it only says what it would do.", [
                "item": laterArg, "confirm": confirmArg,
            ], required: ["item"]),
            tool("later_play", "Play something on Later: a song, episode or station at once; an album, artist, playlist or show from its first track.", [
                "item": laterArg,
            ], required: ["item"]),
            tool("history", "What the owner has played in Baton: the latest plays, or the most-played tracks, albums or artists over a span. Read-only.", [
                "view": ["type": "string", "enum": ["recent", "tracks", "albums", "artists"], "description": "recent (default), or the top tracks, albums or artists."],
                "days": ["type": "integer", "description": "For tracks, albums and artists: how many days back (default 30; 0 for all time)."],
                "limit": ["type": "integer", "description": "Most to return (default 25, max 200)."],
            ]),
            tool("downloads_list", "The songs and episodes downloaded to this Mac, the space they take, and whether offline mode is on. Read-only.", [
                "limit": ["type": "integer", "description": "Most to list (default 50, max 500). The totals always count everything."],
            ]),
            tool("download_songs", "Download songs to this Mac for offline listening: the given ids, a search, or the song playing now.", [
                "song_ids": ["type": "array", "items": ["type": "string"], "description": "Exact song ids."],
                "query": ["type": "string", "description": "Download what this search finds (at most `limit`)."],
                "limit": ["type": "integer", "description": "Most songs for a search (default 10, max 50)."],
            ]),
            tool("download_remove", "Remove downloads from this Mac (the songs stay on the music server). Without confirm:true it only says what it would do.", [
                "ids": ["type": "array", "items": ["type": "string"], "description": "Ids from downloads_list."],
                "confirm": confirmArg,
            ], required: ["ids"]),
            tool("shares_list", "The song links and mixtapes the owner has shared from this Mac: what, when, until when, and whether they still play. Never the links themselves. Read-only.", [:]),
            tool("share_revoke", "Stop a shared song link or mixtape from playing, for everyone who has it. Cannot be undone. Without confirm:true it only says what it would do.", [
                "share_id": ["type": "string", "description": "The share's id from shares_list."],
                "confirm": confirmArg,
            ], required: ["share_id"]),
            tool("share_mixtape", "Share 2 to 12 songs (up to 20 minutes) as one mixtape link a friend can play in a browser. Encrypted on this Mac and uploaded to Baton's share service; returns the link to send. Refuses until the owner has shared once from Baton itself. Without confirm:true it only says what it would do.", [
                "song_ids": ["type": "array", "items": ["type": "string"], "description": "The songs, in order."],
                "title": ["type": "string", "description": "The mixtape's title."],
                "note": ["type": "string", "description": "A short note shown with it, up to 280 characters."],
                "expires_days": ["type": "integer", "description": "1, 7 (default) or 30 days."],
                "hide_details": ["type": "boolean", "description": "Encrypt the titles too, so link previews only say a mixtape was sent."],
                "confirm": confirmArg,
            ], required: ["song_ids", "title"]),
            tool("handoff_status", "Whether another device left a queue to pick up here, and the devices linked to this Mac (names only). Read-only.", [:]),
            tool("handoff_accept", "Pick up the queue another device left, where it stopped. Replaces the queue here.", [:]),
            tool("handoff_save_queue", "Leave this Mac's queue on the music server, so the owner's other device can pick it up where this one is. Without confirm:true it only says what it would do.", [
                "confirm": confirmArg,
            ]),
            tool("playback_speed", "Read or set the speed podcasts and books play at (0.75 to 2, pitch kept). Music always plays at its own speed. Without `rate`, only reads.", [
                "rate": ["type": "number", "description": "The new speed, 0.75 to 2. Omit to read it."],
            ]),
            tool("settings_read", "A read of Baton's settings that matter to an agent: what is set up, offline mode, crossfade, the equalizer, spoken speed, books and speech choices. Never an address, a name or a key. Read-only.", [:]),
        ]
        return defs
    }

    private static let confirmArg: [String: Any] = ["type": "boolean", "description": "Set true to do it. Without it, nothing changes and the answer says what would happen."]
    private static let bookArg: [String: Any] = ["type": "string", "description": "The book's title (or part of it) or its document id. Omit for the book playing, else the one last played."]
    private static let clippingArg: [String: Any] = ["type": "string", "description": "The clipping's id from clippings_list, or its title (exactly, to delete it)."]
    private static let showArg: [String: Any] = ["type": "string", "description": "The show's id from podcasts_list, or its title (exactly, to unfollow it)."]
    private static let laterArg: [String: Any] = ["type": "string", "description": "The item's id from later_list, or its title (exactly, to remove it)."]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    // MARK: - Dispatch

    /// The answer for one of these tools, or nil when `name` is not one of them.
    static func run(_ name: String, _ args: [String: Any], music: MusicModel) async throws -> String? {
        switch name {
        case "books_list": return booksList(try books(music), music: music)
        case "book_chapters": return try bookChapters(args, books(music), music)
        case "book_play": return try bookPlay(args, books(music), music)
        case "book_cast": return try bookCast(args, books(music), music.documents, playing: music)
        case "book_change_voice": return try await bookChangeVoice(args, books(music), music.documents, playing: music)
        case "book_cover": return try bookCover(args, books(music), music.documents, playing: music)
        case "clippings_list": return clippingsList(args, music.clippings.items)
        case "clipping_play": return try clippingPlay(args, music)
        case "clipping_delete": return try clippingDelete(args, store: music.clippings)
        case "podcasts_list": return await podcastsList(music)
        case "podcast_episodes": return try await podcastEpisodes(args, music)
        case "podcast_play_episode": return try await podcastPlay(args, music)
        case "podcast_subscribe": return try await podcastSubscribe(args, music)
        case "podcast_unsubscribe": return try await podcastUnsubscribe(args, music)
        case "radio_list_stations": return await radioList(music)
        case "radio_play_station": return try await radioPlay(args, music)
        case "later_list": return laterList(music.pins)
        case "later_add": return try await laterAdd(args, music)
        case "later_remove": return try laterRemove(args, pins: music.pins)
        case "later_play": return try laterPlay(args, music)
        case "history": return try history(args, music.musicHistory)
        case "downloads_list": return downloadsList(args, items: MusicDownloadStore.shared.downloadedItems().map(DownloadRow.init),
                                                    totalBytes: MusicDownloadStore.shared.totalBytes(),
                                                    offline: StreamingPlaybackController.isOfflineMode)
        case "download_songs": return try await downloadSongs(args, music)
        case "download_remove": return try downloadRemove(args, items: MusicDownloadStore.shared.downloadedItems().map(DownloadRow.init),
                                                          delete: { MusicDownloadStore.shared.delete($0) })
        case "shares_list": return await sharesList(refreshing: SongSharing.shared)
        case "share_revoke": return try await shareRevoke(args, sharing: SongSharing.shared)
        case "share_mixtape": return try await shareMixtape(args, music)
        case "handoff_status": return await handoffStatus(music)
        case "handoff_accept": return try handoffAccept(music)
        case "handoff_save_queue": return handoffSave(args, music)
        case "playback_speed": return try playbackSpeed(args, music.music)
        case "settings_read": return settingsRead(music)
        default: return nil
        }
    }

    // MARK: - Shared pieces

    /// Only a JSON boolean `true` confirms. `1`, `1.0` and `"true"` do not: Foundation hands a
    /// JSON number 1 over as an NSNumber that `as? Bool` would read as true.
    static func confirmed(_ args: [String: Any]) -> Bool { strictBool(args["confirm"]) == true }

    /// A JSON boolean, or nil for anything else, numbers included.
    static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// What a tool would do, changing nothing.
    static func dryRun(_ would: String, _ extra: [String: Any] = [:]) -> String {
        var out = extra
        out["dry_run"] = true
        out["would"] = would
        out["to_proceed"] = "Nothing has changed. Call again with confirm: true to do it."
        return BatonMCPToolCatalog.jsonText(out)
    }

    static func done(_ did: String, _ extra: [String: Any] = [:]) -> String {
        var out = extra
        out["done"] = did
        return BatonMCPToolCatalog.jsonText(out)
    }

    static func string(_ args: [String: Any], _ key: String) -> String? {
        guard let value = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? NSNumber { return value.intValue }
        if let value = args[key] as? String { return Int(value) }
        return nil
    }

    static func strings(_ args: [String: Any], _ key: String) -> [String] {
        ((args[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func limit(_ args: [String: Any], default value: Int, max top: Int) -> Int {
        min(top, max(1, int(args, "limit") ?? value))
    }

    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ value: Date?) -> Any { value.map { iso.string(from: $0) } ?? NSNull() }

    /// A stable short id for something whose real key must not be shown (a feed address).
    static func shortID(_ key: String) -> String { String(SHA256Digest.hex(of: Data(key.utf8)).prefix(12)) }

    /// The first of `items` named by `wanted`: an exact id, then an exact title, then a title
    /// containing it. Case is ignored.
    static func pick<T>(_ items: [T], _ wanted: String, id: (T) -> String, title: (T) -> String, what: String) throws -> T {
        if let match = items.first(where: { id($0) == wanted }) { return match }
        let query = wanted.lowercased()
        if let match = items.first(where: { title($0).lowercased() == query }) ?? items.first(where: { title($0).lowercased().contains(query) }) {
            return match
        }
        let known = items.prefix(20).map(title).joined(separator: "; ")
        throw BatonMCPToolError(message: "No \(what) matches \"\(wanted)\".\(known.isEmpty ? "" : " Known: \(known).")")
    }

    /// For a tool that deletes or removes: the item with exactly this id, or the one item with
    /// exactly this title (case ignored). Several with that title, or only near matches, are
    /// refused with the candidates and their ids, as `music_delete_playlist` refuses
    /// (`exactPlaylistToDelete`): a destructive tool never guesses.
    static func pickExactly<T>(_ items: [T], _ wanted: String, id: (T) -> String, title: (T) -> String, what: String) throws -> T {
        if let match = items.first(where: { id($0) == wanted }) { return match }
        let query = wanted.lowercased()
        let exact = items.filter { title($0).lowercased() == query }
        if exact.count == 1 { return exact[0] }
        func list(_ found: [T]) -> String { found.prefix(20).map { "\(title($0)) [\(id($0))]" }.joined(separator: ", ") }
        if exact.count > 1 {
            throw BatonMCPToolError(message: "More than one \(what) is titled \"\(wanted)\". Pass the id to choose: \(list(exact)).")
        }
        let near = items.filter { title($0).lowercased().contains(query) }
        guard !near.isEmpty else { throw BatonMCPToolError(message: "No \(what) matches \"\(wanted)\".") }
        throw BatonMCPToolError(message: "No \(what) is titled exactly \"\(wanted)\". This needs an exact title or the id. Did you mean: \(list(near))?")
    }

    // MARK: - Books

    static func books(_ music: MusicModel) throws -> [BookShelf.Book] {
        guard DocumentLibrary.isEnabled() else {
            throw BatonMCPToolError(message: "Document import is not switched on in this Baton.")
        }
        music.documents.start()
        return music.documents.shelf
    }

    static func resolve(_ args: [String: Any], _ books: [BookShelf.Book], _ music: MusicModel?) throws -> BookShelf.Book {
        guard !books.isEmpty else { throw BatonMCPToolError(message: "There are no books yet. Import a document to make one.") }
        let playingID = music?.music.nowPlaying.flatMap { music?.clippings.item(forSongID: $0.id)?.clipping.documentID }
        return try BatonMCPBookTools.resolveBook(args, books: books, playingDocumentID: playingID,
                                                 ledger: music?.clippings.ledger ?? ClippingLedger())
    }

    /// The book a state-changing call acts on. With `confirm: true` the book must be named, by
    /// its document id or its full title, and only one may match: a confirmed Change Voice
    /// re-renders a whole book, and a removed cover is gone on every device for good, so neither
    /// may fall back to the book playing or take the first near title. A dry run keeps the
    /// friendlier lookup, since it changes nothing and says which book it found.
    static func resolveForChange(_ args: [String: Any], _ books: [BookShelf.Book], _ music: MusicModel?) throws -> BookShelf.Book {
        guard confirmed(args) else { return try resolve(args, books, music) }
        guard let wanted = string(args, "book") else {
            let known = books.prefix(20).map { "\($0.title) [\($0.documentID)]" }.joined(separator: ", ")
            throw BatonMCPToolError(message: "Name the `book` (its document id or full title) to make this change. Books: \(known).")
        }
        return try pickExactly(books, wanted, id: \.documentID, title: \.title, what: "book")
    }

    static func chapterState(_ state: BookShelf.Chapter.State) -> String {
        switch state {
        case .ready: "ready"
        case .queued: "waiting"
        case let .rendering(progress): "being made (\(Int((progress * 100).rounded()))%)"
        case .encoding: "finishing"
        case let .failed(why): "failed: \(why)"
        case .removed: "removed from this Mac"
        }
    }

    static func booksList(_ books: [BookShelf.Book], voices: (BookShelf.Book) -> VoicePlan? = { _ in nil },
                          hasCover: (String) -> Bool = { _ in false }) -> String {
        let rows: [[String: Any]] = books.map { book in
            var row: [String: Any] = [
                "document_id": book.documentID,
                "title": book.title,
                "author": book.author ?? "",
                "chapters": book.chapters.count,
                "chapters_ready": book.chapters.filter { $0.item?.isPresent == true }.count,
                "finished": book.finished,
                "made_on": book.madeOn == .homeServer ? "the Baton server" : "this Mac",
                "being_made": book.isRendering,
                "has_cover": hasCover(book.documentID),
                "added": iso.string(from: book.createdAt),
            ]
            if let position = book.position {
                row["position"] = ["chapter": position.chapterIndex + 1, "seconds": Int(position.seconds)]
            }
            if let paused = book.pauseReason { row["paused"] = paused }
            if let failure = book.failure { row["failed"] = failure }
            if let remaking = book.remaking { row["changing_voice"] = remaking }
            if let plan = voices(book) {
                row["narrator"] = plan.narrator
                row["cast_size"] = plan.characters.count
            }
            return row
        }
        return BatonMCPToolCatalog.jsonText(["count": rows.count, "books": rows])
    }

    private static func booksList(_ books: [BookShelf.Book], music: MusicModel) -> String {
        booksList(books, voices: { music.documents.voices(of: $0)?.plan },
                  hasCover: { music.documents.covers.hasCover($0) })
    }

    static func bookChapters(_ args: [String: Any], _ books: [BookShelf.Book], _ music: MusicModel?) throws -> String {
        let book = try resolve(args, books, music)
        let rows: [[String: Any]] = book.chapters.map { chapter in
            var row: [String: Any] = ["chapter": chapter.index + 1, "title": chapter.title, "state": chapterState(chapter.state)]
            if let seconds = chapter.item?.clipping.durationSeconds { row["seconds"] = Int(seconds.rounded()) }
            if let position = book.position, position.chapterIndex == chapter.index { row["listener_is_here"] = Int(position.seconds) }
            return row
        }
        return BatonMCPToolCatalog.jsonText(["document_id": book.documentID, "title": book.title, "finished": book.finished, "chapters": rows])
    }

    static func bookPlay(_ args: [String: Any], _ books: [BookShelf.Book], _ music: MusicModel) throws -> String {
        let book = try resolve(args, books, music)
        var index: Int?
        if let chapter = int(args, "chapter") {
            guard book.chapters.indices.contains(chapter - 1) else {
                throw BatonMCPToolError(message: "\"\(book.title)\" has chapters 1 to \(book.chapters.count).")
            }
            index = chapter - 1
        }
        let (songs, start) = BookPlayback.queue(for: book, fromChapter: index)
        guard !songs.isEmpty else {
            throw BatonMCPToolError(message: "No chapter of \"\(book.title)\" is on this Mac yet\(book.isRendering ? "; it is still being made" : "").")
        }
        music.music.play(songs, startAt: start, source: MusicBooksView.source(book))
        let from = index.map { "chapter \($0 + 1)" } ?? (book.position.map { "chapter \($0.chapterIndex + 1), where the listener stopped" } ?? "the start")
        return done("Playing \"\(book.title)\" from \(from).")
    }

    static func bookCast(_ args: [String: Any], _ books: [BookShelf.Book], _ library: DocumentLibrary,
                         playing music: MusicModel?) throws -> String {
        let book = try resolve(args, books, music)
        guard let voices = library.voices(of: book) else {
            throw BatonMCPToolError(message: "This Mac does not have \"\(book.title)\"'s text, so its voices are not known here.")
        }
        return castText(book, plan: voices.plan, hasCast: voices.hasCast)
    }

    static func castText(_ book: BookShelf.Book, plan: VoicePlan, hasCast: Bool) -> String {
        BatonMCPToolCatalog.jsonText([
            "document_id": book.documentID, "title": book.title, "narrator": plan.narrator,
            "dialogue_voiced": hasCast,
            "cast": plan.characters.sorted { $0.key < $1.key }.map { ["character": $0.key, "voice": $0.value] },
        ])
    }

    static func bookChangeVoice(_ args: [String: Any], _ books: [BookShelf.Book], _ library: DocumentLibrary,
                                playing music: MusicModel?) async throws -> String {
        let book = try resolveForChange(args, books, music)
        guard let voice = string(args, "voice"), voice.contains(":") else {
            throw BatonMCPToolError(message: "Give `voice` as an \"engine:voice\" spec, such as kokoro:bf_emma.")
        }
        guard library.canChangeVoice(book) else {
            throw BatonMCPToolError(message: "\"\(book.title)\" cannot be made in another voice here: this Mac does not have its text.")
        }
        let current = library.voices(of: book)?.plan.narrator
        guard current != voice else { throw BatonMCPToolError(message: "\"\(book.title)\" is already read by \(voice).") }
        let would = "Make \"\(book.title)\" again, \(book.chapters.count) chapters, read by \(voice) instead of \(current ?? "its narrator")."
        guard confirmed(args) else { return dryRun(would) }
        try await library.changeVoice(book, to: voice)
        return done("Started: \(would) Each chapter switches as it is ready.")
    }

    static func bookCover(_ args: [String: Any], _ books: [BookShelf.Book], _ library: DocumentLibrary,
                          playing music: MusicModel?) throws -> String {
        let book = try resolveForChange(args, books, music)
        let covers = library.covers
        switch string(args, "action") {
        case "make":
            if let refusal = covers.makeRefusal(title: book.title, author: book.author) { throw BatonMCPToolError(message: refusal) }
            let would = "Draw a cover for \"\(book.title)\" from its title and author\(covers.hasCover(book.documentID) ? ", replacing the one it has" : ""), on every device."
            guard confirmed(args) else { return dryRun(would) }
            try covers.make(documentID: book.documentID, title: book.title, author: book.author)
            return done(would)
        case "remove":
            guard covers.hasCover(book.documentID) else { return done("\"\(book.title)\" has no cover; nothing to remove.") }
            let would = "Remove the cover of \"\(book.title)\" on every device."
            guard confirmed(args) else { return dryRun(would) }
            covers.remove(documentID: book.documentID)
            return done(would)
        default:
            throw BatonMCPToolError(message: "Give `action`: make or remove.")
        }
    }

    // MARK: - Clippings

    static func readings(_ items: [ClippingStore.Item]) -> [ClippingStore.Item] {
        items.filter { !$0.clipping.isBookChapter }.sorted { $0.clipping.createdAt > $1.clipping.createdAt }
    }

    static func clippingsList(_ args: [String: Any], _ items: [ClippingStore.Item]) -> String {
        let all = readings(items)
        let rows: [[String: Any]] = all.prefix(limit(args, default: 50, max: 200)).map { item in
            var row: [String: Any] = [
                "id": item.id, "title": item.clipping.title, "saved": iso.string(from: item.clipping.createdAt),
                "words_kept": item.clipping.text?.isEmpty == false, "file_present": item.isPresent,
            ]
            // Where it came from, unless that is an address (a page read aloud).
            if let source = item.clipping.source, !source.contains("://") { row["from"] = source }
            if let seconds = item.clipping.durationSeconds { row["seconds"] = Int(seconds.rounded()) }
            return row
        }
        return BatonMCPToolCatalog.jsonText(["count": all.count, "clippings": rows])
    }

    static func clipping(_ args: [String: Any], _ items: [ClippingStore.Item], exactly: Bool = false) throws -> ClippingStore.Item {
        guard let wanted = string(args, "clipping") else { throw BatonMCPToolError(message: "Give `clipping`: its id or title.") }
        return exactly
            ? try pickExactly(readings(items), wanted, id: \.id, title: \.clipping.title, what: "clipping")
            : try pick(readings(items), wanted, id: \.id, title: \.clipping.title, what: "clipping")
    }

    static func clippingPlay(_ args: [String: Any], _ music: MusicModel) throws -> String {
        let item = try clipping(args, music.clippings.items)
        guard item.isPresent else { throw BatonMCPToolError(message: "\"\(item.clipping.title)\"'s audio file has gone from this Mac.") }
        music.music.play([item.asSong])
        return done("Playing \"\(item.clipping.title)\".")
    }

    static func clippingDelete(_ args: [String: Any], store: ClippingStore) throws -> String {
        let item = try clipping(args, store.items, exactly: true)
        // A JSON boolean only: `1` must not widen a delete on this Mac to every device.
        guard args["everywhere"] == nil || strictBool(args["everywhere"]) != nil else {
            throw BatonMCPToolError(message: "`everywhere` is true or false.")
        }
        let everywhere = strictBool(args["everywhere"]) ?? false
        let would = "Delete the clipping \"\(item.clipping.title)\" from \(everywhere ? "every device" : "this Mac")."
        guard confirmed(args) else { return dryRun(would) }
        store.remove(id: item.id, everywhere: everywhere)
        return done(would)
    }

    // MARK: - Podcasts

    static func podcastsList(_ music: MusicModel) async -> String {
        await music.podcastSubscriptions.loadIfNeeded()
        return podcastsText(music.podcastSubscriptions.channels, progress: music.podcastProgress)
    }

    static func podcastsText(_ channels: [PodcastChannel], progress: PodcastProgressStore) -> String {
        let rows: [[String: Any]] = channels.map { channel in
            let unplayed = channel.episodes.filter { !progress.isPlayed(id: episodeSongID(channel, $0)) }.count
            return ["id": shortID(channel.id), "title": channel.title, "episodes": channel.episodes.count, "unplayed": unplayed,
                    "latest": date(channel.episodes.compactMap(\.publishDate).max())]
        }
        return BatonMCPToolCatalog.jsonText(["count": rows.count, "shows": rows])
    }

    static func episodeSongID(_ channel: PodcastChannel, _ episode: PodcastEpisode) -> String { episode.enclosureURL.absoluteString }

    static func show(_ args: [String: Any], _ channels: [PodcastChannel], exactly: Bool = false) throws -> PodcastChannel {
        guard let wanted = string(args, "show") else { throw BatonMCPToolError(message: "Give `show`: its id or title.") }
        return exactly
            ? try pickExactly(channels, wanted, id: { shortID($0.id) }, title: \.title, what: "followed show")
            : try pick(channels, wanted, id: { shortID($0.id) }, title: \.title, what: "followed show")
    }

    static func podcastEpisodes(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        await music.podcastSubscriptions.loadIfNeeded()
        let channel = try show(args, music.podcastSubscriptions.channels)
        return episodesText(channel, limit: limit(args, default: 20, max: 100), progress: music.podcastProgress)
    }

    static func episodesText(_ channel: PodcastChannel, limit: Int, progress: PodcastProgressStore) -> String {
        let rows: [[String: Any]] = channel.episodes.prefix(limit).map { episode in
            let id = episodeSongID(channel, episode)
            // The guid can be the audio address, so the id is opaque.
            var row: [String: Any] = ["id": shortID(episode.id), "title": episode.title, "published": date(episode.publishDate),
                                      "played": progress.isPlayed(id: id)]
            if let seconds = episode.duration { row["seconds"] = seconds }
            if let fraction = progress.fraction(id: id), fraction > 0, fraction < 1 { row["heard_percent"] = Int((fraction * 100).rounded()) }
            return row
        }
        return BatonMCPToolCatalog.jsonText(["show": channel.title, "episodes": rows])
    }

    static func podcastPlay(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        await music.podcastSubscriptions.loadIfNeeded()
        let channel = try show(args, music.podcastSubscriptions.channels)
        let episode: PodcastEpisode
        if let wanted = string(args, "episode") {
            episode = try pick(channel.episodes, wanted, id: { shortID($0.id) }, title: \.title, what: "episode of \(channel.title)")
        } else if let unplayed = channel.episodes.first(where: { !music.podcastProgress.isPlayed(id: episodeSongID(channel, $0)) }) {
            episode = unplayed
        } else {
            throw BatonMCPToolError(message: "Every episode of \(channel.title) has been played. Name one with `episode`.")
        }
        let song = episode.asSong(channelTitle: channel.title, artwork: episode.imageURL ?? channel.imageURL)
        music.music.play([song], source: PinnedItem.episode(episode, channel: channel).queueSource)
        return done("Playing \"\(episode.title)\" from \(channel.title).")
    }

    static func podcastSubscribe(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        guard let text = string(args, "feed_url"), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            throw BatonMCPToolError(message: "Give `feed_url` as the show's http or https feed address.")
        }
        await music.podcastSubscriptions.loadIfNeeded()
        if let existing = music.podcastSubscriptions.channels.first(where: { $0.feedURL == url }) {
            return done("Already following \(existing.title).", ["id": shortID(existing.id)])
        }
        guard confirmed(args) else { return dryRun("Fetch this feed and follow the show on every device.") }
        let channel = try await music.podcastSubscriptions.subscribe(to: url)
        return done("Following \(channel.title).", ["id": shortID(channel.id), "episodes": channel.episodes.count])
    }

    static func podcastUnsubscribe(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        await music.podcastSubscriptions.loadIfNeeded()
        let channel = try show(args, music.podcastSubscriptions.channels, exactly: true)
        let would = "Stop following \(channel.title) on every device."
        guard confirmed(args) else { return dryRun(would) }
        music.podcastSubscriptions.unsubscribe(channel)
        return done(would)
    }

    // MARK: - Internet radio

    static func radioList(_ music: MusicModel) async -> String {
        await music.internetRadio.loadIfNeeded()
        let radio = music.internetRadio
        if let error = radio.loadError, radio.stations.isEmpty { return BatonMCPToolCatalog.jsonText(["error": error, "stations": []]) }
        return stationsText(radio.stations, onAir: radio.onAirStation?.id)
    }

    static func stationsText(_ stations: [NavidromeRadioStation], onAir: String?) -> String {
        BatonMCPToolCatalog.jsonText([
            "count": stations.count,
            "stations": stations.map { ["id": $0.id, "name": $0.name, "on_air": $0.id == onAir] as [String: Any] },
        ])
    }

    static func radioPlay(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        await music.internetRadio.loadIfNeeded()
        guard let wanted = string(args, "station") else { throw BatonMCPToolError(message: "Give `station`: its name or id.") }
        let station = try pick(music.internetRadio.stations, wanted, id: \.id, title: \.name, what: "station")
        music.internetRadio.play(station)
        return done("Playing \(station.name).")
    }

    // MARK: - Later

    /// A Later item's id for an agent: opaque, since an episode's or show's own id is its audio or
    /// feed address.
    static func laterID(_ pin: PinnedItem) -> String { shortID(pin.id) }

    static func laterList(_ pins: PinStore) -> String {
        pins.loadIfNeeded()
        let rows: [[String: Any]] = pins.ordered.map { pin in
            var row: [String: Any] = ["id": laterID(pin), "kind": pin.kind.label.lowercased(), "title": pin.title,
                                      "saved": iso.string(from: pin.pinnedAt)]
            // A station's subtitle is its stream's host; the others are names (an artist, a show).
            if pin.kind != .radioStation, let subtitle = pin.subtitle { row["subtitle"] = subtitle }
            return row
        }
        return BatonMCPToolCatalog.jsonText(["count": rows.count, "later": rows])
    }

    static func laterItem(_ args: [String: Any], _ pins: PinStore, exactly: Bool = false) throws -> PinnedItem {
        pins.loadIfNeeded()
        guard let wanted = string(args, "item") else { throw BatonMCPToolError(message: "Give `item`: its id or title.") }
        return exactly
            ? try pickExactly(pins.ordered, wanted, id: laterID, title: \.title, what: "item on Later")
            : try pick(pins.ordered, wanted, id: laterID, title: \.title, what: "item on Later")
    }

    static func laterAdd(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let song = try await BatonMCPToolCatalog.resolveMusicSong(args, music)
        let item = PinnedItem.song(song)
        music.pins.loadIfNeeded()
        guard !music.pins.isPinned(item.id) else { return done("\(song.displayLine) is already on Later.") }
        music.pins.toggle(item)
        return done("Saved \(song.displayLine) to Later.", ["id": laterID(item)])
    }

    static func laterRemove(_ args: [String: Any], pins: PinStore) throws -> String {
        let item = try laterItem(args, pins, exactly: true)
        let would = "Take \(item.kind.label.lowercased()) \"\(item.title)\" off Later."
        guard confirmed(args) else { return dryRun(would) }
        pins.unpin(id: item.id)
        return done(would)
    }

    static func laterPlay(_ args: [String: Any], _ music: MusicModel) throws -> String {
        let item = try laterItem(args, music.pins)
        PinPlayback.play(item, music)
        return done("Playing \(item.kind.label.lowercased()) \"\(item.title)\" from Later.")
    }

    // MARK: - History

    static func history(_ args: [String: Any], _ history: MusicPlayHistory, now: Date = Date()) throws -> String {
        let limit = limit(args, default: 25, max: 200)
        let days = max(0, int(args, "days") ?? 30)
        let since = days == 0 ? Date.distantPast : now.addingTimeInterval(-Double(days) * 86_400)
        switch string(args, "view") ?? "recent" {
        case "recent":
            let rows: [[String: Any]] = history.listenLog(limit: limit).map {
                ["id": $0.song.id, "title": $0.song.title, "artist": $0.song.displayArtistName ?? "", "album": $0.song.album ?? "",
                 "played": iso.string(from: $0.playedAt)]
            }
            return BatonMCPToolCatalog.jsonText(["view": "recent", "plays_all_time": history.lifetimeCount, "plays": rows])
        case "tracks":
            return BatonMCPToolCatalog.jsonText(["view": "tracks", "days": days, "tracks": history.topTracks(since: since, limit: limit).map {
                ["id": $0.song.id, "title": $0.song.title, "artist": $0.song.displayArtistName ?? "", "plays": $0.count] as [String: Any]
            }])
        case "albums":
            return BatonMCPToolCatalog.jsonText(["view": "albums", "days": days, "albums": history.topAlbums(since: since, limit: limit).map {
                ["album": $0.album, "artist": $0.artwork.displayArtistName ?? "", "plays": $0.count] as [String: Any]
            }])
        case "artists":
            return BatonMCPToolCatalog.jsonText(["view": "artists", "days": days, "artists": history.topArtists(since: since, limit: limit).map {
                ["artist": $0.artist, "plays": $0.count] as [String: Any]
            }])
        default:
            throw BatonMCPToolError(message: "`view` is recent, tracks, albums or artists.")
        }
    }

    // MARK: - Downloads

    /// What a download shows an agent. `id` is the store's own (a song id, or a podcast episode's
    /// audio address); the list shows only `shortID` of it.
    struct DownloadRow: Equatable {
        var id: String
        var title: String
        var artist: String?
        var album: String?
        var bytes: Int64

        init(id: String, title: String, artist: String?, album: String?, bytes: Int64) {
            (self.id, self.title, self.artist, self.album, self.bytes) = (id, title, artist, album, bytes)
        }

        init(_ item: MusicDownloadStore.DownloadItem) {
            self.init(id: item.id, title: item.title, artist: item.artist, album: item.album, bytes: item.byteSize)
        }
    }

    static func downloadsList(_ args: [String: Any], items: [DownloadRow], totalBytes: Int64, offline: Bool) -> String {
        let rows: [[String: Any]] = items.prefix(limit(args, default: 50, max: 500)).map { item in
            ["id": shortID(item.id), "title": item.title, "artist": item.artist ?? "", "album": item.album ?? "", "bytes": item.bytes]
        }
        return BatonMCPToolCatalog.jsonText(["count": items.count, "total_bytes": totalBytes, "offline_mode": offline, "downloads": rows])
    }

    static func downloadSongs(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        var songs: [NavidromeSong]
        let ids = strings(args, "song_ids")
        if !ids.isEmpty {
            songs = try await BatonMCPToolCatalog.songs(ids: Array(ids.prefix(50)))
        } else if string(args, "query") != nil {
            songs = Array(try await BatonMCPToolCatalog.searchSongs(args).prefix(limit(args, default: 10, max: 50)))
        } else {
            songs = [try await BatonMCPToolCatalog.resolveMusicSong(args, music)]
        }
        songs = songs.filter { !$0.isLocalOnly }
        guard !songs.isEmpty else { throw BatonMCPToolError(message: "Nothing to download.") }
        let saved = await MusicDownloadStore.shared.download(songs)
        return done("Downloaded \(saved) of \(songs.count) songs to this Mac.", ["songs": songs.map(\.displayLine)])
    }

    /// The store ids that `ids` (from downloads_list, or a song's own id) name among `items`.
    static func downloadIDs(_ ids: [String], in items: [DownloadRow]) -> [DownloadRow] {
        items.filter { item in ids.contains(shortID(item.id)) || ids.contains(item.id) }
    }

    static func downloadRemove(_ args: [String: Any], items: [DownloadRow], delete: (String) -> Void) throws -> String {
        let present = downloadIDs(strings(args, "ids"), in: items)
        guard !present.isEmpty else { throw BatonMCPToolError(message: "None of those is downloaded here. Use the ids from downloads_list.") }
        let names = present.prefix(10).map(\.title).joined(separator: "; ")
        let would = "Remove \(present.count) download\(present.count == 1 ? "" : "s") from this Mac (\(names)); they stay on the music server."
        guard confirmed(args) else { return dryRun(would, ["ids": present.map { shortID($0.id) }]) }
        present.forEach { delete($0.id) }
        return done(would)
    }

    // MARK: - Shared links and mixtapes

    static func sharesList(refreshing sharing: SongSharing) async -> String {
        await sharing.refresh()
        return sharesText(sharing.ledger.records)
    }

    /// Every share, without its link: the link holds the key that decrypts the song.
    static func sharesText(_ records: [ShareLedger.Record], now: Date = Date()) -> String {
        let rows: [[String: Any]] = records.sorted { $0.createdAt > $1.createdAt }.map { record in
            var row: [String: Any] = [
                "id": record.id, "kind": record.containerKind.rawValue, "title": record.title,
                "shared": iso.string(from: record.createdAt), "expires": iso.string(from: record.expiresAt),
                "plays_now": record.isLive(now: now), "status": "\(record.status)", "details_hidden": record.isPrivate,
            ]
            if record.containerKind == .song { row["artist"] = record.artist }
            if let count = record.songIDs?.count { row["tracks"] = count }
            return row
        }
        return BatonMCPToolCatalog.jsonText(["count": rows.count, "shares": rows,
                                             "note": "Links are not listed: each holds the key to its song."])
    }

    static func shareRevoke(_ args: [String: Any], sharing: SongSharing) async throws -> String {
        guard let id = string(args, "share_id") else { throw BatonMCPToolError(message: "Give `share_id` from shares_list.") }
        guard let record = sharing.ledger.records.first(where: { $0.id == id }) else {
            throw BatonMCPToolError(message: "No share from this Mac has the id \(id).")
        }
        let would = "Stop the shared \(record.containerKind.rawValue) \"\(record.title)\" from playing for anyone who has the link. This cannot be undone."
        guard confirmed(args) else { return dryRun(would) }
        try await sharing.revoke(record.id, kind: record.containerKind)
        return done(would)
    }

    static func shareMixtape(_ args: [String: Any], _ music: MusicModel,
                             hasSharedBefore: Bool = SongSharing.hasSharedBefore) async throws -> String {
        guard hasSharedBefore else { throw BatonMCPToolError(message: SongSharing.consentRequiredMessage) }
        let ids = strings(args, "song_ids")
        guard (2...12).contains(ids.count), Set(ids).count == ids.count else {
            throw BatonMCPToolError(message: "Give 2 to 12 different `song_ids`.")
        }
        guard let title = string(args, "title") else { throw BatonMCPToolError(message: "Give the mixtape a `title`.") }
        let options = try SongSharing.toolOptions(args, from: BatonStorage.defaults.string(forKey: SongSharing.fromKey) ?? "")
        let songs = try await BatonMCPToolCatalog.songs(ids: ids)
        let would = "Encrypt \(songs.count) songs (\(songs.map(\.displayLine).joined(separator: "; "))) on this Mac and upload them to Baton's share service as the mixtape \"\(title)\", for anyone with the link."
        guard confirmed(args) else { return dryRun(would) }
        do {
            let record = try await SongSharing.shared.shareMixtape(songs, title: title, options: options)
            return BatonMCPToolCatalog.jsonText(["link": record.link, "title": title, "tracks": songs.count,
                                                 "expires": iso.string(from: record.expiresAt),
                                                 "note": "Send this link to the friend. It holds the key; it is not listed anywhere else."])
        } catch {
            throw BatonMCPToolError(message: SongShareError(error).errorDescription ?? "Sharing didn't work.")
        }
    }

    // MARK: - Handoff and devices

    static func handoffStatus(_ music: MusicModel) async -> String {
        await music.queueHandoff.checkForHandoff()
        var out: [String: Any] = ["linked_devices": DevicePairing.LinkedDevices.all().map {
            ["name": $0.name, "linked": iso.string(from: $0.linkedAt)] as [String: Any]
        }]
        if let offer = music.queueHandoff.offer {
            out["offer"] = ["tracks": offer.queue.songs.count, "current": offer.currentTitle ?? "",
                            "from": offer.queue.changedBy ?? ""] as [String: Any]
        } else {
            out["offer"] = NSNull()
        }
        return BatonMCPToolCatalog.jsonText(out)
    }

    static func handoffAccept(_ music: MusicModel) throws -> String {
        guard let offer = music.queueHandoff.offer else {
            throw BatonMCPToolError(message: "No other device has left a queue to pick up. Call handoff_status first.")
        }
        let title = offer.currentTitle
        music.queueHandoff.acceptOffer()
        return done("Picked up the other device's queue\(title.map { " at \"\($0)\"" } ?? "").")
    }

    static func handoffSave(_ args: [String: Any], _ music: MusicModel) -> String {
        let count = music.music.queue.count
        guard count > 0 else {
            return dryRun("Nothing: the queue here is empty, so there is no queue to leave for the other device.", ["queue_empty": true])
        }
        let would = "Leave this Mac's queue (\(count) tracks\(music.music.nowPlaying.map { ", at \"\($0.title)\"" } ?? "")) on the music server for the owner's other device."
        guard confirmed(args) else { return dryRun(would) }
        return handoffSaveText(music.queueHandoff.saveNow())
    }

    /// What `saveNow` actually did, in words.
    static func handoffSaveText(_ outcome: QueueHandoff.SaveOutcome) -> String {
        switch outcome {
        // `saveNow` hands the queue to a task that sends it; the server has not answered yet.
        case .sent: done("Scheduled to send this Mac's queue to the music server for the owner's other device; the server has not confirmed it yet.",
                         ["scheduled": true])
        case .emptyQueue: done("Nothing was saved: the queue here is empty.", ["scheduled": false])
        case .unavailable: done("Nothing was saved: handoff is off here (no music server, or a shared public one).", ["scheduled": false])
        case .unchanged: done("Nothing was saved: the music server already has this queue at this place.", ["scheduled": false])
        }
    }

    // MARK: - Speed

    static func playbackSpeed(_ args: [String: Any], _ player: StreamingPlaybackController) throws -> String {
        if args["rate"] != nil {
            guard let rate = (args["rate"] as? NSNumber)?.floatValue ?? (args["rate"] as? String).flatMap(Float.init),
                  rate.isFinite, rate >= SpokenPlaybackOptions.minimumRate, rate <= SpokenPlaybackOptions.maximumRate else {
                throw BatonMCPToolError(message: "`rate` is a number from \(SpokenPlaybackOptions.minimumRate) to \(SpokenPlaybackOptions.maximumRate).")
            }
            player.spokenRate = rate
        }
        return BatonMCPToolCatalog.jsonText([
            "spoken_rate": Double(player.spokenRate), "playing_at": Double(player.playbackRate),
            "note": "Podcasts and books play at spoken_rate; music always at 1.",
        ])
    }

    // MARK: - Settings

    static func settingsRead(_ music: MusicModel) -> String {
        BatonMCPToolCatalog.jsonText([
            "music_server_set_up": NavidromeConfig.isConfigured,
            "offline_mode": StreamingPlaybackController.isOfflineMode,
            "crossfade_seconds": music.music.crossfadeSeconds,
            "equalizer_on": music.musicEqualizer.isEnabled,
            "spoken_rate": Double(music.music.spokenRate),
            "documents_on": DocumentLibrary.isEnabled(),
            "voice_engine_for_books": BookVoiceSettings.engine.rawValue,
            "make_books_on": BookVoiceSettings.makeBooksOn.rawValue,
            "expressive_voice_server_set_up": BookVoiceSettings.expressiveEndpoint(key: nil) != nil,
            "transcription_on": SpeechConfig.transcriptionEnabled,
            "agent_may_auto_play_speech": SpeechConfig.allowAutoPlay,
            "announce_speech_immediately": SpeechConfig.announceImmediately,
            "song_sharing_used": SongSharing.hasSharedBefore,
            "note": "No addresses, names or keys are included.",
        ])
    }
}
