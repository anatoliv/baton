import XCTest
@testable import Baton
@testable import BatonAgentKit

/// A hundred things a person actually says to a music player, run through the
/// real agent loop against a real model. **Skipped unless configured** — see
/// `RemoteAgentLiveTests` for the `~/.baton-live-agent.json` file it needs.
///
/// Unit tests prove Baton's control flow with a scripted model; they say nothing
/// about whether the thing is pleasant to talk to. This measures the two
/// properties that make it worth using and that only a real model can answer:
///
/// 1. **The right thing happens.** "Put something on" plays; "what's this?"
///    answers without touching playback; "add it to the queue" queues rather
///    than replacing what's playing.
/// 2. **It reads like a person.** No tool names, no restating the question, no
///    paragraph where a line will do, and — the failure that started all this —
///    no describing an action it did not take.
///
/// Run it: `./scripts/test.sh -only-testing:BatonTests/RemoteAgentConversationEval`
/// It prints a scorecard and every failing case, so the output is the report.
@MainActor
final class RemoteAgentConversationEval: XCTestCase {
    /// Belt and braces for TBX-2848: this is the test the runner died under, so arm the
    /// exit diagnostic here too rather than trusting the bundle's principal class to have
    /// been instantiated. Idempotent.
    override class func setUp() {
        super.setUp()
        RunnerExitDiagnostic.arm()
    }

    // MARK: What a message should lead to

    enum Expectation {
        /// Something must start playing (or a choice must be offered).
        case plays
        /// Must go to the END of the queue, not replace what's playing.
        case queues
        /// A question about state or the library: answer it, don't start music.
        case answers
        /// Conversation about music. A reply is the point; playing is not
        /// forbidden but must not be the *only* thing it does.
        case chats
        /// One specific tool, because the words are unambiguous.
        case runs(String)
        /// Saved for later rather than played now.
        case saves
    }

    struct Case {
        let message: String
        let expect: Expectation
        /// Player state to hand the model, when the message refers to "this".
        var context: String = "Player state: nothing is playing right now."
        var history: [RemoteConversationLog.Turn] = []
    }

    private static let playing =
        "Player state: \"Absolutely (Original Mix)\" by DIDO, from the album \"YT Mix\" — track 3 of 25 in the queue."

    // MARK: - The corpus

    // Grouped by what the person is trying to do, because that is what decides
    // whether the answer is right — not the grammar they used to say it.
    static let cases: [Case] = [
        // — Vibes and moods. The headline case: none of these are song titles.
        Case(message: "find lazy music and play", expect: .plays),
        Case(message: "put on something chill", expect: .plays),
        Case(message: "i want something upbeat", expect: .plays),
        Case(message: "play something mellow for the evening", expect: .plays),
        Case(message: "something to focus to", expect: .plays),
        Case(message: "put on something for cooking dinner", expect: .plays),
        Case(message: "i need energy", expect: .plays),
        Case(message: "something moody", expect: .plays),
        Case(message: "play something nostalgic", expect: .plays),
        Case(message: "give me something dreamy", expect: .plays),
        Case(message: "put on background music", expect: .plays),
        Case(message: "something for a rainy afternoon", expect: .plays),
        Case(message: "play music for cleaning the house", expect: .plays),
        Case(message: "i want to dance", expect: .plays),
        Case(message: "something relaxing before bed", expect: .plays),

        // — Named things. These SHOULD be a straight search-and-play.
        Case(message: "play dido", expect: .plays),
        Case(message: "play armin van buuren", expect: .plays),
        Case(message: "put on white flag", expect: .plays),
        Case(message: "play the absolutely original mix", expect: .plays),
        Case(message: "i want to hear some trance", expect: .plays),
        Case(message: "play some gothic stuff", expect: .plays),
        Case(message: "play eurodance", expect: .plays),
        Case(message: "put on markus schulz", expect: .plays),
        Case(message: "play my classic trance playlist", expect: .plays),
        Case(message: "play the newest album i added", expect: .plays),

        // — Recommendation. The whole reason for the discovery tools.
        Case(message: "what should i listen to?", expect: .plays),
        Case(message: "surprise me", expect: .plays),
        Case(message: "play something i haven't heard in a while", expect: .plays),
        Case(message: "play my favourites", expect: .plays),
        Case(message: "what do i have that's good?", expect: .chats),
        Case(message: "recommend me something from my library", expect: .chats),
        Case(message: "play something like armin van buuren", expect: .plays),
        Case(message: "i'm bored of my usual stuff", expect: .plays),
        Case(message: "play my most listened tracks", expect: .plays),
        Case(message: "anything new in here?", expect: .chats),

        // — Queue, which is a different verb and must not replace playback.
        Case(message: "add some trance to the queue", expect: .queues, context: playing),
        Case(message: "queue up more like this", expect: .queues, context: playing),
        Case(message: "stick dido on the end", expect: .queues, context: playing),
        Case(message: "add white flag after this one", expect: .queues, context: playing),
        Case(message: "put a few chill tracks in the queue", expect: .queues, context: playing),

        // — Transport. Unambiguous, and must never become a search.
        Case(message: "pause", expect: .runs("music_pause"), context: playing),
        Case(message: "hold on a sec", expect: .runs("music_pause"), context: playing),
        Case(message: "skip this", expect: .runs("music_next"), context: playing),
        Case(message: "next one please", expect: .runs("music_next"), context: playing),
        Case(message: "go back", expect: .runs("music_previous"), context: playing),
        Case(message: "stop the music", expect: .runs("music_stop"), context: playing),
        Case(message: "turn it up", expect: .runs("music_set_volume"), context: playing),
        Case(message: "too loud", expect: .runs("music_set_volume"), context: playing),
        Case(message: "keep it going after this", expect: .runs("music_start_radio"), context: playing),
        Case(message: "shuffle it", expect: .runs("music_set_shuffle"), context: playing),

        // — Questions about the player. Must NOT start music.
        Case(message: "what's playing?", expect: .answers, context: playing),
        Case(message: "what is this song", expect: .answers, context: playing),
        Case(message: "who sings this?", expect: .answers, context: playing),
        Case(message: "what album is this from", expect: .answers, context: playing),
        Case(message: "how long is this track", expect: .answers, context: playing),
        Case(message: "is anything playing", expect: .answers),
        Case(message: "what's coming up next?", expect: .answers, context: playing),
        Case(message: "how many tracks are queued", expect: .answers, context: playing),
        Case(message: "what have i got queued up", expect: .answers, context: playing),

        // — Questions about the library. Also must not start music.
        Case(message: "what genres do i have?", expect: .answers),
        Case(message: "do i have any coltrane", expect: .answers),
        Case(message: "have i got anything by bjork", expect: .answers),
        Case(message: "how much trance do i have", expect: .answers),
        Case(message: "what are my playlists", expect: .answers),
        Case(message: "show me my liked songs", expect: .answers),
        Case(message: "do i have any ambient", expect: .answers),
        Case(message: "what's my most played song", expect: .answers),
        Case(message: "find songs by dido", expect: .answers),
        Case(message: "search for trance", expect: .answers),
        // Kept verbatim from conversations rated "misunderstood" on the phone,
        // 9 Aug 2026. Bare "show" with no "me" is the shape that got missed —
        // "show me my liked songs" above already passes, so the corpus knew the
        // polite form and not the terse one. Both mean display, not play.
        Case(message: "Show piano tracks", expect: .answers),
        Case(message: "Show tracks", expect: .answers),

        // — Liking and rating.
        Case(message: "i love this song", expect: .runs("music_like"), context: playing),
        Case(message: "add this to my favourites", expect: .runs("music_like"), context: playing),
        Case(message: "give this five stars", expect: .runs("music_rate"), context: playing),
        Case(message: "this deserves a 4", expect: .runs("music_rate"), context: playing),
        Case(message: "actually i don't like this, unlike it", expect: .runs("music_like"), context: playing),

        // — Mixes and playlists.
        Case(message: "make me a 40 minute focus mix", expect: .plays),
        Case(message: "build a one hour trance mix", expect: .plays),
        // Making a playlist is not playing one — saving it IS the whole request.
        // Either route is right: create_playlist, or build_mix with
        // action="playlist", which is what the mix tool exists for.
        Case(message: "make a playlist of my chill stuff", expect: .saves),
        Case(message: "i need an hour of music for a drive", expect: .plays),
        Case(message: "put together something for a party", expect: .plays),

        // — Talking about music. This is the "friend" half: a reply is the
        // point, and answering with silence or a wall of JSON both fail.
        Case(message: "what do you think of this track?", expect: .chats, context: playing),
        Case(message: "is dido any good?", expect: .chats),
        Case(message: "tell me about armin van buuren", expect: .chats),
        Case(message: "what kind of music do i listen to?", expect: .chats),
        Case(message: "am i listening to too much trance?", expect: .chats),
        Case(message: "what's this genre even called", expect: .chats, context: playing),
        Case(message: "i'm in a weird mood today", expect: .chats),
        Case(message: "hey", expect: .chats),
        Case(message: "thanks!", expect: .chats),
        Case(message: "what else does this artist have?", expect: .chats, context: playing),
        Case(message: "when did this come out", expect: .chats, context: playing),
        Case(message: "do you like trance?", expect: .chats),
        Case(message: "my taste is terrible isn't it", expect: .chats),
        Case(message: "what should i explore next?", expect: .chats),
        Case(message: "why do i keep playing this one", expect: .chats, context: playing),

        // — Follow-ups. These only work if the conversation is carried.
        Case(
            message: "play the second one",
            expect: .plays,
            history: [
                .init(role: "user", text: "search for dido"),
                .init(role: "assistant", text: "*Songs*\n• White Flag — Dido\n• Absolutely (Original Mix) — DIDO"),
            ]
        ),
        Case(
            // "the other one" while something plays is honestly ambiguous —
            // switching now and lining it up next are both defensible.
            message: "actually the other one",
            expect: .queues,
            context: playing,
            history: [
                .init(role: "user", text: "play dido"),
                .init(role: "assistant", text: "▶︎ Absolutely (Original Mix) — DIDO"),
            ]
        ),
        Case(
            message: "more of that",
            expect: .plays,
            context: playing,
            history: [
                .init(role: "user", text: "play some trance"),
                .init(role: "assistant", text: "▶︎ Playing your trance."),
            ]
        ),
        Case(
            message: "no, something quieter",
            expect: .plays,
            context: playing,
            history: [
                .init(role: "user", text: "put something on"),
                .init(role: "assistant", text: "▶︎ Big Beat — loud and fast."),
            ]
        ),
        Case(
            message: "yeah go on then",
            expect: .plays,
            history: [
                .init(role: "user", text: "what should i listen to"),
                .init(role: "assistant", text: "Your Classic Trance playlists haven't been touched in months — want those?"),
            ]
        ),

        // — More than one thing in one message. The corpus had none of these,
        // which is how "rate 4 this track and list similar by the same artist"
        // reached a shipped release answering with the command list.
        Case(message: "rate 4 this track and list similar by the same artist",
             expect: .runs("music_rate"), context: playing),
        Case(message: "like this and queue up more by them", expect: .runs("music_like"), context: playing),
        Case(message: "pause and tell me what that was", expect: .runs("music_pause"), context: playing),
        Case(message: "turn it down and skip this", expect: .runs("music_set_volume"), context: playing),
        Case(message: "what's playing, and is there more like it?", expect: .answers, context: playing),

        // — Awkward, terse, or typo'd. People type badly on phones.
        Case(message: "plya something", expect: .plays),
        Case(message: "musci", expect: .chats),
        Case(message: "play", expect: .plays),
        Case(message: "?", expect: .chats),
        Case(message: "something. anything.", expect: .plays),
        Case(message: "PLAY SOMETHING LOUD", expect: .plays),
        Case(message: "can you like, put on some music or whatever", expect: .plays),
        Case(message: "i dunno, you pick", expect: .plays),
        Case(message: "sleep in 30", expect: .runs("music_sleep_timer")),
        Case(message: "turn the music off in an hour", expect: .runs("music_sleep_timer"), context: playing),
    ]

    // MARK: - A library that behaves like a real one

    /// Modelled on a real Navidrome library: mostly YouTube-sourced, genres that
    /// are half-useful ("Music" on 5,487 tracks) and half-real (Trance, Gothic),
    /// long DJ mixes beside three-minute tracks, and no track anywhere called
    /// "lazy", "chill-out-for-cooking", or any other mood someone might type.
    /// Mirrors the router: shape the result, then let Baton attach what it
    /// knows. Without this the eval would measure a path production no longer
    /// takes — and would never see a seeded ask_choice.
    private func library(memory: RemoteMemoryStore, picks: [RemoteMemoryStore.Pick] = []) -> RemoteAgent.ToolRunner {
        let raw = rawLibrary()
        return { call in
            let (text, isError) = await raw(call)
            guard !isError else { return (text, true) }
            let shaped = RemoteAgentResults.shape(text)
            return (RemoteAgentResults.annotate(
                shaped, tool: call.name, memory: memory, recentPicks: picks), false)
        }
    }

    /// The fixture has to *remember what it played*. It didn't, and the
    /// consequence was invisible to the eval's own scoring but obvious to an
    /// LLM judge reading the transcripts: `music_now_playing` answered "DIDO —
    /// Absolutely" however many tracks had been started since, so the model
    /// played gothic, checked, saw DIDO, and reported that it couldn't change
    /// the music. A fixture that lies teaches the thing under test to sound
    /// confused, and then scores it for the confusion.
    private final class PlayerState: @unchecked Sendable {
        var title = "Absolutely (Original Mix)"
        var artist = "DIDO"
        var playCount = 34
    }

    private func rawLibrary() -> RemoteAgent.ToolRunner {
        let state = PlayerState()
        return { call in
            let query: String = {
                if case let .string(value)? = call.arguments["query"] { return value.lowercased() }
                if case let .string(value)? = call.arguments["prompt"] { return value.lowercased() }
                if case let .string(value)? = call.arguments["name"] { return value.lowercased() }
                return ""
            }()

            func songs(_ items: [(String, String, Int)]) -> String {
                let rows = items.map { title, artist, seconds in
                    #"{"id":"\#(abs(title.hashValue))","title":"\#(title)","artist":"\#(artist)","duration_seconds":\#(seconds)}"#
                }
                return #"{"songs":[\#(rows.joined(separator: ","))],"albums":[],"artists":[]}"#
            }

            switch call.name {
            case "music_search":
                // Real words in this library, and nothing else.
                if query.contains("chill") || query.contains("lounge") || query.contains("relax") {
                    return (songs([
                        ("Deep Rooftop Chillout", "Unknown", 11168),
                        ("RELAX LOUNGE CHILLOUT Luxury Chill", "Unknown", 23845),
                        ("The Best Of Vocal Chill Out Music 2023", "Unknown", 12981),
                    ]), false)
                }
                if query.contains("ambient") || query.contains("psychill") {
                    return (songs([
                        ("Ambient, Downtempo, PsyChill Mix", "Space Station", 5702),
                        ("Space Ambient (Cosmic Serenity)", "dr_rost", 2618),
                    ]), false)
                }
                if query.contains("dido") {
                    return (#"""
                    {"songs":[{"id":"s1","title":"Absolutely (Original Mix)","artist":"DIDO","duration_seconds":443,"play_count":34,"rating":5},
                    {"id":"s2","title":"White Flag","artist":"Dido","duration_seconds":221}],
                    "albums":[],"artists":[{"id":"a1","name":"DIDO"},{"id":"a2","name":"Dido"}]}
                    """#, false)
                }
                if query.contains("trance") || query.contains("armin") || query.contains("schulz") {
                    return (songs([
                        ("Communication (Part 2)", "Armin van Buuren", 380),
                        ("Mainstage", "Markus Schulz", 402),
                    ]), false)
                }
                if query.contains("gothic") || query.contains("new wave") {
                    return (songs([("The Voice", "Technoir", 289), ("Rainbow Vs. Stars", "Evil's Toy", 254)]), false)
                }
                if query.contains("eurodance") || query.contains("dance") || query.contains("upbeat") || query.contains("party") {
                    return (songs([("Big Love", "Unknown", 609), ("Meet Her at the Loveparade", "Da Hool", 341)]), false)
                }
                // Everything else — including every mood anyone types.
                return (#"{"songs":[],"albums":[],"artists":[]}"#, false)

            case "music_list_genres":
                return (#"""
                {"genres":[{"name":"Music","song_count":5487},{"name":"People & Blogs","song_count":435},
                {"name":"Entertainment","song_count":219},{"name":"Trance","song_count":107},
                {"name":"Electronic","song_count":105},{"name":"Gothic","song_count":68},
                {"name":"New Wave","song_count":68},{"name":"Eurodance","song_count":40},
                {"name":"House","song_count":38},{"name":"Big Beat","song_count":32},
                {"name":"Ambient","song_count":22}]}
                """#, false)

            case "music_liked":
                return (#"""
                {"songs":[{"id":"l1","title":"Evermore (Original Mix)","artist":"DIDO","rating":5,"play_count":3},
                {"id":"l2","title":"Initialize Deep Work — Coding Music","artist":"Unknown","rating":5},
                {"id":"l3","title":"PAGANINI x MELODIC TECHNO","artist":"Unknown","rating":5}],
                "albums":[],"artists":[{"id":"a9","name":"Cerf, Mitiska & Jaren"}],"total_liked_songs":65}
                """#, false)

            case "music_browse_albums":
                // Honour `type`: a fixture that answers "random" to every kind
                // makes a model that correctly asks for "newest" look broken.
                var kind = "random"
                if case let .string(value)? = call.arguments["type"] { kind = value }
                let newest = #"{"id":"b9","name":"Lost in Love","artist":"Unknown","year":2025,"song_count":8}"#
                let rest = #"{"id":"b1","name":"2009","artist":"Armin van Buuren","year":2009,"song_count":2},"# +
                    #"{"id":"b2","name":"Navigator","artist":"Armin van Buuren","song_count":4}"#
                let list = kind == "newest" || kind == "recent" ? newest + "," + rest : rest
                return (#"{"type":"\#(kind)","albums":[\#(list)]}"#, false)

            case "music_similar_songs":
                return (#"""
                {"seed_id":"s1","songs":[{"id":"m1","title":"Man On The Run","artist":"Cerf, Mitiska & Jaren","duration_seconds":372},
                {"id":"m2","title":"Nadia Ali \"Rapture\" (Avicii Mix)","artist":"Nadia Ali","duration_seconds":401}],"note":""}
                """#, false)

            case "music_random":
                return (songs([("The Voice", "Technoir", 289), ("Big Love", "Unknown", 609)]), false)

            case "music_artist_info":
                return (#"""
                {"id":"a1","name":"Armin van Buuren","albums":[{"id":"b1","name":"2009","year":2009},
                {"id":"b2","name":"Navigator"}]}
                """#, false)

            case "music_list_playlists":
                return (#"""
                {"playlists":[{"name":"02 - Classic Trance (Pt 1)","song_count":60},
                {"name":"02 - Classic Trance (Pt 2)","song_count":60},{"name":"Evening","song_count":24}]}
                """#, false)

            case "music_get_playlist":
                return (#"{"name":"Evening","songs":[{"id":"p1","title":"Lost in Love","artist":"Unknown"}]}"#, false)

            case "music_now_playing":
                return (#"""
                {"state":"playing","summary":"\#(state.artist) — \#(state.title)","queue_length":25,"queue_index":2,
                "volume_percent":51,"now_playing":{"id":"s1","title":"\#(state.title)","artist":"\#(state.artist)",
                "album":"YT Mix","duration_seconds":443,"year":2026,"play_count":\#(state.playCount),"rating":5}}
                """#, false)

            case "music_get_queue":
                return (#"""
                {"queue_index":2,"tracks":[{"title":"First Breach","artist":"Unknown"},
                {"title":"The First Touch","artist":"Dimitris Athanasiou"},
                {"title":"Absolutely (Original Mix)","artist":"DIDO"}]}
                """#, false)

            case "music_play", "music_play_next":
                // Whatever was asked for is what's now playing — the behaviour
                // a real player has and the fixture used to lack.
                state.title = query.isEmpty ? "Deep Rooftop Chillout" : query.capitalized
                state.artist = "Unknown"
                state.playCount = 1
                return (#"{"playing":{"title":"\#(state.title)","artist":"\#(state.artist)"},"queued":12}"#, false)
            case "music_queue_add":
                return (#"{"added":8,"queue_length":33,"summary":"queued"}"#, false)
            case "music_build_mix":
                state.title = "Communication"; state.artist = "Armin van Buuren"; state.playCount = 3
                return (#"{"mix":"focus","track_count":11,"total_minutes":42,"now_playing":{"title":"Communication","artist":"Armin van Buuren"}}"#, false)
            case "music_play_playlist":
                state.title = "Mainstage"; state.artist = "Markus Schulz"; state.playCount = 4
                return (#"{"playing_playlist":"02 - Classic Trance (Pt 1)","tracks":60,"now_playing":{"title":"Mainstage","artist":"Markus Schulz"}}"#, false)
            case "music_start_radio":
                state.title = "Man On The Run"; state.artist = "Cerf, Mitiska & Jaren"; state.playCount = 2
                return (#"{"radio":"on","now_playing":{"title":"Man On The Run","artist":"Cerf, Mitiska & Jaren"}}"#, false)
            default:
                return (#"{"ok":true}"#, false)
            }
        }
    }

    // MARK: - Scoring

    static let playTools: Set<String> = [
        "music_play", "music_build_mix", "music_play_playlist", "music_start_radio",
    ]
    static let queueTools: Set<String> = ["music_queue_add", "music_play_next"]
    /// Anything that changes what comes out of the speakers.
    static var playbackTools: Set<String> {
        playTools.union(queueTools).union([
            "music_pause", "music_resume", "music_stop", "music_next", "music_previous",
            "music_seek", "music_set_volume", "music_set_shuffle", "music_set_repeat",
        ])
    }

    struct Result {
        let text: String
        let tools: [String]
        let asked: Bool
    }

    private func verdict(_ expect: Expectation, _ result: Result) -> String? {
        let tools = Set(result.tools)
        switch expect {
        case .plays:
            guard tools.isDisjoint(with: Self.playTools), !result.asked else { return nil }
            return "nothing started playing"
        case .queues:
            guard tools.isDisjoint(with: Self.queueTools), !result.asked else { return nil }
            return tools.isDisjoint(with: Self.playTools)
                ? "nothing was queued"
                : "REPLACED the queue instead of adding to it"
        case .answers:
            let changed = tools.intersection(Self.playbackTools)
            return changed.isEmpty ? nil : "started/changed playback for a question: \(changed.sorted())"
        case .chats:
            return result.text.isEmpty ? "said nothing" : nil
        case let .runs(tool):
            return tools.contains(tool) || result.asked ? nil : "expected \(tool), ran \(result.tools)"
        case .saves:
            let saved: Set<String> = ["music_create_playlist", "music_build_mix", "music_add_to_playlist"]
            return tools.isDisjoint(with: saved) ? "nothing was saved" : nil
        }
    }

    /// Things that make a reply read like software rather than a person.
    private func styleComplaints(_ text: String) -> [String] {
        var out: [String] = []
        if text.isEmpty { return ["empty"] }
        if text.contains("music_") { out.append("leaks a tool name") }
        if text.count > 400 { out.append("too long (\(text.count) chars)") }
        if text.contains("{") || text.contains("\"songs\"") { out.append("leaks JSON") }
        if text.lowercased().hasPrefix("i'm sorry") || text.lowercased().contains("as an ai") {
            out.append("robotic apology")
        }
        return out
    }

    // MARK: - The run

    func testAHundredThingsPeopleSay() async throws {
        let live = try RemoteAgentLiveTests.liveConfig()
        // BATON_EVAL_NO_FORCE=1 runs the same corpus with the first-turn forced
        // tool call disabled, which is how the "is it still load-bearing?"
        // question gets answered with a number instead of an opinion.
        let noForce = ProcessInfo.processInfo.environment["BATON_EVAL_NO_FORCE"] == "1"
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.baton-eval-no-force")
        RemoteAgent.forcesFirstToolCall = !noForce
        defer { RemoteAgent.forcesFirstToolCall = true }
        if noForce { print("EXPERIMENT: forcesFirstToolCall = false") }

        let memory = RemoteMemoryStore(url: nil)
        var failures: [String] = []
        var transcript: [[String: Any]] = []
        var styleIssues: [String] = []
        var asked = 0, played = 0, answered = 0
        var toolHistogram: [String: Int] = [:]

        for (index, testCase) in Self.cases.enumerated() {
            let outcome: RemoteAgent.Outcome
            do {
                outcome = try await RemoteAgent.run(
                    message: testCase.message,
                    history: testCase.history,
                    playerContext: testCase.context,
                    config: live,
                    tools: RemoteAgent.toolSchemas(definitions: BatonMCPToolCatalog.definitions()),
                    runTool: library(memory: memory)
                )
            } catch {
                failures.append("[\(index + 1)] “\(testCase.message)” → threw: \(error)")
                continue
            }

            let result = Result(
                text: outcome.choice.map { $0.rendered() } ?? outcome.text,
                tools: outcome.toolsRun,
                asked: outcome.choice != nil
            )
            for tool in outcome.toolsRun { toolHistogram[tool, default: 0] += 1 }
            transcript.append([
                "n": index + 1,
                "message": testCase.message,
                "context": testCase.context,
                "tools": outcome.toolsRun,
                "reply": result.text,
                "asked": result.asked,
            ])
            if result.asked { asked += 1 }
            if !Set(result.tools).isDisjoint(with: Self.playTools) { played += 1 }
            if Set(result.tools).isDisjoint(with: Self.playbackTools) { answered += 1 }

            if let complaint = verdict(testCase.expect, result) {
                failures.append(
                    "[\(index + 1)] “\(testCase.message)” → \(complaint)\n"
                        + "      tools: \(result.tools)\n      said: \(result.text.prefix(160))"
                )
            }
            let style = styleComplaints(result.text)
            if !style.isEmpty {
                styleIssues.append("[\(index + 1)] “\(testCase.message)” → \(style.joined(separator: ", "))\n      said: \(result.text.prefix(160))")
            }
        }

        // Everything the eval cannot judge — did the sentence match the action,
        // would a friend say this — is scored offline by scripts/agent-judge.py
        // over this file. Written next to the live config, same opt-in.
        let transcriptURL = URL(fileURLWithPath: NSHomeDirectory() + "/.baton-eval-transcript.json")
        if let data = try? JSONSerialization.data(
            withJSONObject: ["cases": transcript], options: [.prettyPrinted]) {
            try? data.write(to: transcriptURL)
            print("TRANSCRIPT: \(transcriptURL.path) (\(transcript.count) cases)")
        }

        // Stamp the run so scripts/check-release.sh can say whether this
        // version has ever been measured. A release with no number is a release
        // shipping on hope.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        if let stamp = try? JSONSerialization.data(withJSONObject: [
            "version": version,
            "correct": Self.cases.count - failures.count,
            "total": Self.cases.count,
            "asked": asked,
        ], options: [.prettyPrinted]) {
            try? stamp.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/.baton-eval-last.json"))
        }

        let total = Self.cases.count
        print("""

        ══════════════════════════════════════════════════════════════
        CONVERSATION EVAL — \(total) messages
        ══════════════════════════════════════════════════════════════
          correct        \(total - failures.count)/\(total)
          asked a choice \(asked)
          started music  \(played)
          answered only  \(answered)
          style flags    \(styleIssues.count)

        TOOLS USED
        \(toolHistogram.sorted { $0.value > $1.value }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n"))

        WRONG BEHAVIOUR (\(failures.count))
        \(failures.joined(separator: "\n"))

        STYLE (\(styleIssues.count))
        \(styleIssues.joined(separator: "\n"))
        ══════════════════════════════════════════════════════════════
        """)

        // A threshold, not perfection: these are judgement calls made by a model,
        // and a corpus this varied will always have a tail. Regressions in the
        // *structure* are what this must catch.
        XCTAssertLessThan(
            failures.count, total / 5,
            "more than 20% of ordinary messages did the wrong thing"
        )
    }
}
