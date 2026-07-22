import XCTest
@testable import Baton

/// Coverage for user-defined webhook actions: token substitution, JSON-safe escaping,
/// request building (method/headers/body), the store's run() result, and persistence.
@MainActor
final class WebhookActionsTests: XCTestCase {
    // MARK: - Templating

    func testSubstituteReplacesTokens() {
        let out = WebhookTemplate.substitute(
            "{channelTitle}: {title}",
            tokens: ["channelTitle": "The Daily", "title": "Monday"], escaping: .none
        )
        XCTAssertEqual(out, "The Daily: Monday")
    }

    func testJSONEscapeProtectsBody() {
        // A title with quotes/newlines must not break a JSON body.
        let body = WebhookTemplate.substitute(
            #"{"t":"{title}"}"#, tokens: ["title": "Say \"hi\"\nthere"], escaping: .json
        )
        XCTAssertEqual(body, #"{"t":"Say \"hi\"\nthere"}"#)
        // Round-trips as valid JSON.
        let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String]
        XCTAssertEqual(obj?["t"], "Say \"hi\"\nthere")
    }

    func testURLComponentEscapingEncodesSpecials() {
        // Spaces / & / = / : / / in a token value are percent-encoded for URL + form contexts.
        let out = WebhookTemplate.substitute(
            "q={title}", tokens: ["title": "A & B=C https://x"], escaping: .urlComponent
        )
        XCTAssertEqual(out, "q=A%20%26%20B%3DC%20https%3A%2F%2Fx")
    }

    func testFormBodyIsURLEncoded() throws {
        var action = WebhookAction(name: "Save", urlTemplate: "https://web-01/save")
        action.contentType = .form
        action.bodyTemplate = "title={title}"
        let req = try XCTUnwrap(WebhookTemplate.buildRequest(action, tokens: ["title": "Q&A: A=B"]))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(String(data: try XCTUnwrap(req.httpBody), encoding: .utf8), "title=Q%26A%3A%20A%3DB")
    }

    func testURLWithSpacesInTokenStaysValid() throws {
        let action = WebhookAction(name: "S", urlTemplate: "https://web-01/save?t={title}")
        let req = try XCTUnwrap(WebhookTemplate.buildRequest(action, tokens: ["title": "Hello World"]))
        XCTAssertEqual(req.url?.absoluteString, "https://web-01/save?t=Hello%20World")
    }

    func testUnknownTokenStrippedNotSentLiterally() {
        // An unknown/typo'd placeholder is removed, not sent as literal "{artist}"…
        let out = WebhookTemplate.substitute(
            #"{"t":"{title}","a":"{artist}"}"#, tokens: ["title": "Mon"], escaping: .json
        )
        XCTAssertEqual(out, #"{"t":"Mon","a":""}"#)
        // …and it round-trips as valid JSON (object braces untouched).
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(out.utf8)))
    }

    // MARK: - Request building

    func testBuildRequestPostJSON() throws {
        var action = WebhookAction(name: "Save", urlTemplate: "https://web-01/save?u={enclosureUrl}")
        action.headers = [.init(name: "Authorization", value: "Bearer {guid}")]
        action.bodyTemplate = #"{"url":"{enclosureUrl}"}"#
        let req = try XCTUnwrap(WebhookTemplate.buildRequest(
            action, tokens: ["enclosureUrl": "https://cdn/ep.mp3", "guid": "g1"]
        ))
        XCTAssertEqual(req.httpMethod, "POST")
        // The enclosure URL in the query is percent-encoded (was raw before the escaping fix).
        XCTAssertEqual(req.url?.absoluteString, "https://web-01/save?u=https%3A%2F%2Fcdn%2Fep.mp3")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer g1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(data: try XCTUnwrap(req.httpBody), encoding: .utf8), #"{"url":"https://cdn/ep.mp3"}"#)
    }

    /// Reproduces a real failure: an action whose header row has a value but no NAME sends no
    /// header at all, and the server answers 401 "missing bearer token" while the app shows only
    /// "failed". The drop itself is intended (a nameless header is meaningless) — what's missing
    /// is any way for the user to find out, which `WebhookSendResult` now provides.
    func testHeaderWithEmptyNameIsDropped() throws {
        var action = WebhookAction(name: "Save", urlTemplate: "https://web-01/save")
        action.headers = [
            .init(name: "  ", value: "Bearer secret-token"),   // name left blank
            .init(name: "X-Real", value: "kept"),
        ]
        let req = try XCTUnwrap(WebhookTemplate.buildRequest(action, tokens: [:]))
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(req.value(forHTTPHeaderField: ""))
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Real"), "kept",
                       "a well-formed row alongside a blank one must still be sent")
    }

    /// The inverse: a properly named row is transmitted verbatim, so a 401 in the field means the
    /// header was absent or wrong — not that Baton failed to send it.
    func testNamedAuthorizationHeaderIsSent() throws {
        var action = WebhookAction(name: "Save", urlTemplate: "https://web-01/save")
        action.headers = [.init(name: " Authorization ", value: "Bearer abc123")]
        let req = try XCTUnwrap(WebhookTemplate.buildRequest(action, tokens: [:]))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer abc123",
                       "the name is trimmed, so stray spaces around it are harmless")
    }

    func testGetHasNoBody() throws {
        var action = WebhookAction(name: "Ping", urlTemplate: "https://web-01/ping")
        action.method = .get
        action.bodyTemplate = "ignored"
        let req = try XCTUnwrap(WebhookTemplate.buildRequest(action, tokens: [:]))
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertNil(req.httpBody)
    }

    func testInvalidURLReturnsNil() {
        let action = WebhookAction(name: "Bad", urlTemplate: "not a url")
        XCTAssertNil(WebhookTemplate.buildRequest(action, tokens: [:]))
    }

    // MARK: - Store run + persistence

    func testRunReportsSuccessAndFailure() async {
        var captured: URLRequest?
        let store = WebhookActionStore(defaults: freshDefaults(), send: { req in captured = req; return 204 },
                                       sendWithBody: nil)
        let action = WebhookAction(name: "Save", urlTemplate: "https://web-01/save")
        let ok = await store.run(action, tokens: [:])
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(captured?.url?.absoluteString, "https://web-01/save")

        let failStore = WebhookActionStore(defaults: freshDefaults(), send: { _ in 500 }, sendWithBody: nil)
        let failed = await failStore.run(action, tokens: [:])
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.status, 500)

        let throwStore = WebhookActionStore(defaults: freshDefaults(),
                                            send: { _ in throw URLError(.notConnectedToInternet) },
                                            sendWithBody: nil)
        let threw = await throwStore.run(action, tokens: [:])
        XCTAssertFalse(threw.ok)
        XCTAssertNil(threw.status, "a transport failure never reached a status code")
        XCTAssertNotNil(threw.detail)
    }

    /// The failure that actually happened in the field: the learning-pipeline answered
    /// 401 {"detail":"missing bearer token"} and the app said only "failed". The reason must now
    /// reach the toast.
    func testFailureSurfacesServerExplanation() async {
        let body = Data(#"{"detail":"missing bearer token"}"#.utf8)
        let store = WebhookActionStore(defaults: freshDefaults(), send: { _ in 401 },
                                       sendWithBody: { _ in (401, body) })
        let action = WebhookAction(name: "Save transcript", urlTemplate: "https://learn.example/transcript/audio")
        let result = await store.run(action, tokens: [:])
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, 401)
        XCTAssertEqual(result.detail, "missing bearer token")
        XCTAssertEqual(result.toastSuffix, " · HTTP 401 · missing bearer token")
    }

    /// Servers phrase error envelopes differently; a bare status with an unhelpful body should
    /// still yield something actionable rather than an empty toast.
    func testFailureDetailAcrossBodyShapes() {
        XCTAssertEqual(WebhookSendResult.summarize(body: Data(#"{"message":"nope"}"#.utf8), status: 400), "nope")
        XCTAssertEqual(WebhookSendResult.summarize(body: Data(#"{"error":"bad key"}"#.utf8), status: 403), "bad key")
        XCTAssertEqual(WebhookSendResult.summarize(body: Data("plain trouble".utf8), status: 500), "plain trouble")
        // Empty body and HTML error pages fall back to a plain-language hint.
        XCTAssertEqual(WebhookSendResult.summarize(body: Data(), status: 404),
                       "the server has no such path — check the URL")
        XCTAssertEqual(WebhookSendResult.summarize(body: Data("<html>oops</html>".utf8), status: 401),
                       "the server rejected the credentials — check the Authorization header")
    }

    /// The failure that survived the first fix: the header NAME was set, but its value came back
    /// empty because the Keychain refused the secret to a re-signed build. URLSession drops an
    /// empty header field, so the server saw no auth and answered the same generic 401 — looking
    /// exactly like a bad token. It must now fail before sending, naming the header.
    func testEmptyHeaderValueFailsBeforeSending() async {
        var sent = false
        let store = WebhookActionStore(defaults: freshDefaults(),
                                       send: { _ in sent = true; return 200 },
                                       sendWithBody: { _ in sent = true; return (200, Data()) })
        var action = WebhookAction(name: "Save transcript", urlTemplate: "https://learn.example/transcript/audio")
        action.headers = [.init(name: "Authorization", value: "")]
        let result = await store.run(action, tokens: [:])
        XCTAssertFalse(result.ok)
        XCTAssertNil(result.status, "it must not reach the network at all")
        XCTAssertFalse(sent, "a request with an empty auth header is never worth sending")
        XCTAssertEqual(result.detail,
                       "the “Authorization” header has no value — re-enter it in Settings → Actions")
    }

    /// A header that's fully blank (no name, no value) is just an unused row — it must not trip
    /// the empty-value guard and block an otherwise valid action.
    func testFullyBlankHeaderRowDoesNotBlockSending() async {
        let store = WebhookActionStore(defaults: freshDefaults(), send: { _ in 204 }, sendWithBody: nil)
        var action = WebhookAction(name: "Ping", urlTemplate: "https://web-01/ping")
        action.headers = [.init(name: "", value: "")]
        let result = await store.run(action, tokens: [:])
        XCTAssertTrue(result.ok, "an empty spare row shouldn’t stop the request")
    }

    /// A bad URL never reaches the network, so there's no status — but the user still needs a reason.
    func testInvalidURLReportsReason() async {
        let store = WebhookActionStore(defaults: freshDefaults(), send: { _ in 200 }, sendWithBody: nil)
        let action = WebhookAction(name: "Broken", urlTemplate: "not-a-url")
        let result = await store.run(action, tokens: [:])
        XCTAssertFalse(result.ok)
        XCTAssertNil(result.status)
        XCTAssertNotNil(result.detail)
    }

    func testCRUDPersists() {
        let defaults = freshDefaults()
        let store = WebhookActionStore(defaults: defaults, send: { _ in 200 })
        var action = WebhookAction(name: "A", urlTemplate: "https://x/a")
        store.upsert(action)
        action.name = "A2"
        store.upsert(action)                       // update in place, not duplicate
        XCTAssertEqual(store.actions.count, 1)
        XCTAssertEqual(store.actions.first?.name, "A2")

        let reborn = WebhookActionStore(defaults: defaults, send: { _ in 200 })
        XCTAssertEqual(reborn.actions.map(\.name), ["A2"])

        store.delete(action)
        XCTAssertTrue(store.actions.isEmpty)
    }

    // MARK: - Podcast tokens

    func testPodcastTokens() {
        let channel = PodcastChannel(
            feedURL: URL(string: "https://feed/x.xml")!, title: "The Daily",
            description: nil, imageURL: URL(string: "https://img/show.jpg"), episodes: [], lastRefreshed: nil
        )
        let episode = PodcastEpisode(
            id: "guid-1", title: "Monday", description: "notes", publishDate: nil,
            duration: 1800, enclosureURL: URL(string: "https://cdn/mon.mp3")!, imageURL: nil
        )
        let tokens = PodcastWebhookTokens.tokens(episode: episode, channel: channel)
        XCTAssertEqual(tokens["title"], "Monday")
        XCTAssertEqual(tokens["channelTitle"], "The Daily")
        XCTAssertEqual(tokens["enclosureUrl"], "https://cdn/mon.mp3")
        XCTAssertEqual(tokens["feedUrl"], "https://feed/x.xml")
        XCTAssertEqual(tokens["durationSec"], "1800")
        // Episode has no art → falls back to the channel image.
        XCTAssertEqual(tokens["episodeImageUrl"], "https://img/show.jpg")
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "io.tonebox.tests.webhook.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
