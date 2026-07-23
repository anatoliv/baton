import Foundation
import Observation
import OSLog
import SwiftUI

private let webhookLog = Logger(subsystem: "io.tonebox.baton", category: "WebhookActions")

// MARK: - Model

/// A user-defined HTTP action: a request template that Baton fires against an endpoint you
/// configure, with placeholders filled from the media item it's invoked on. The motivating
/// case is "save this episode's transcript" — POST an episode's audio URL to a self-hosted
/// endpoint — but it's deliberately generic: any POST/GET with a templated URL, headers, and
/// body works, and it can run per-item or over a multi-selection.
///
/// Security note: the request goes to whatever URL you configure with whatever headers you
/// set (auth tokens included), stored locally. It only fires on an explicit action, never
/// automatically. Intended for your own/LAN endpoints.
struct WebhookAction: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// SF Symbol shown in menus.
    var icon: String = "bolt.horizontal.circle"
    var method: Method = .post
    /// URL, may contain `{token}` placeholders.
    var urlTemplate: String
    var headers: [Header] = []
    var contentType: ContentType = .json
    /// Request body, may contain `{token}` placeholders (ignored for GET / `.none`).
    var bodyTemplate: String = ""
    /// Whether this action may receive **credential-bearing** tokens — `{streamUrl}` /
    /// `{downloadUrl}` for library tracks, whose URLs embed your Subsonic auth as query params.
    /// Off by default and per-action, because such a URL grants access to your whole library to
    /// whatever endpoint the action posts to. Only turn it on for an endpoint you fully trust.
    var allowCredentialedURLs: Bool = false

    // Custom decoding so actions saved before this field existed still load (with the toggle OFF,
    // the safe default) instead of failing to decode and vanishing on upgrade. Encoding stays
    // synthesized. Only `allowCredentialedURLs` is decode-if-present; every prior field has always
    // been written, so requiring them keeps genuinely-corrupt data loud.
    enum CodingKeys: String, CodingKey {
        case id, name, icon, method, urlTemplate, headers, contentType, bodyTemplate, allowCredentialedURLs
    }

    init(id: UUID = UUID(), name: String, icon: String = "bolt.horizontal.circle",
         method: Method = .post, urlTemplate: String, headers: [Header] = [],
         contentType: ContentType = .json, bodyTemplate: String = "",
         allowCredentialedURLs: Bool = false) {
        self.id = id; self.name = name; self.icon = icon; self.method = method
        self.urlTemplate = urlTemplate; self.headers = headers; self.contentType = contentType
        self.bodyTemplate = bodyTemplate; self.allowCredentialedURLs = allowCredentialedURLs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "bolt.horizontal.circle"
        method = try c.decode(Method.self, forKey: .method)
        urlTemplate = try c.decode(String.self, forKey: .urlTemplate)
        headers = try c.decodeIfPresent([Header].self, forKey: .headers) ?? []
        contentType = try c.decode(ContentType.self, forKey: .contentType)
        bodyTemplate = try c.decodeIfPresent(String.self, forKey: .bodyTemplate) ?? ""
        allowCredentialedURLs = try c.decodeIfPresent(Bool.self, forKey: .allowCredentialedURLs) ?? false
    }

    enum Method: String, Codable, CaseIterable, Identifiable {
        case post = "POST", get = "GET", put = "PUT", patch = "PATCH", delete = "DELETE"
        var id: String { rawValue }
        /// GET/DELETE carry no body.
        var sendsBody: Bool { self == .post || self == .put || self == .patch }
    }

    enum ContentType: String, Codable, CaseIterable, Identifiable {
        case json, form, text, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .json: "JSON"
            case .form: "Form"
            case .text: "Text"
            case .none: "None"
            }
        }
        var headerValue: String? {
            switch self {
            case .json: "application/json"
            case .form: "application/x-www-form-urlencoded"
            case .text: "text/plain; charset=utf-8"
            case .none: nil
            }
        }
    }

    struct Header: Codable, Hashable, Identifiable {
        var id: UUID = UUID()
        var name: String = ""
        var value: String = ""
    }
}

// MARK: - Templating + request building

enum WebhookTemplate {
    /// Tokens whose values carry Subsonic credentials (auth is embedded in the URL query). They
    /// are stripped unless the action's `allowCredentialedURLs` is on — see `WebhookActionStore.run`.
    static let credentialedTokenKeys: Set<String> = ["streamUrl", "downloadUrl"]

    /// How a token's value is escaped for the context it's spliced into, so a title with
    /// quotes, spaces, or `&`/`=` can't break the JSON, corrupt a form/query, or invalidate the
    /// URL.
    enum Escaping {
        /// Raw — headers / plain-text bodies.
        case none
        /// JSON string-literal escaping — JSON bodies.
        case json
        /// Percent-encoding of everything but the RFC-3986 unreserved set — URL query values and
        /// `application/x-www-form-urlencoded` bodies (space→%20, `&`/`=`/`/` encoded).
        case urlComponent
    }

    /// RFC-3986 unreserved characters; everything else is percent-encoded for `.urlComponent`.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Substitutes `{token}` occurrences in `template` from `tokens`, escaping each value for the
    /// given context. Any remaining `{identifier}` placeholder (an unknown token — usually a
    /// typo) is stripped rather than sent literally; JSON object braces (`{"…`) are untouched
    /// since they don't match the identifier shape.
    static func substitute(_ template: String, tokens: [String: String], escaping: Escaping) -> String {
        var out = template
        for (key, raw) in tokens {
            let value: String
            switch escaping {
            case .none: value = raw
            case .json: value = jsonEscaped(raw)
            case .urlComponent: value = raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
            }
            out = out.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return out.replacingOccurrences(
            of: "\\{[A-Za-z][A-Za-z0-9_]*\\}", with: "", options: .regularExpression
        )
    }

    /// Escapes a string for embedding inside a JSON string literal (no surrounding quotes).
    static func jsonEscaped(_ string: String) -> String {
        var out = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Builds the `URLRequest` for `action` with `tokens` filled in, or nil if the resolved URL
    /// is invalid.
    static func buildRequest(_ action: WebhookAction, tokens: [String: String]) -> URLRequest? {
        // Token values in the URL are percent-encoded so spaces/`&`/`#` don't invalidate it.
        let urlString = substitute(action.urlTemplate, tokens: tokens, escaping: .urlComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = action.method.rawValue
        for header in action.headers where !header.name.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(
                substitute(header.value, tokens: tokens, escaping: .none),
                forHTTPHeaderField: header.name.trimmingCharacters(in: .whitespaces)
            )
        }
        if action.method.sendsBody, action.contentType != .none {
            if let contentType = action.contentType.headerValue {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            // JSON → string-literal escape; form → percent-encode; text → raw.
            let escaping: Escaping = switch action.contentType {
            case .json: .json
            case .form: .urlComponent
            case .text, .none: .none
            }
            let body = substitute(action.bodyTemplate, tokens: tokens, escaping: escaping)
            request.httpBody = body.data(using: .utf8)
        }
        return request
    }
}

// MARK: - Store

/// Owns the user's webhook actions (persisted as JSON in UserDefaults) and runs them. The HTTP
/// sender is injectable so the runner can be unit-tested without the network.
///
/// SECURITY: a webhook action's header values can carry an `Authorization: Bearer …`
/// secret. The action list is persisted as JSON in UserDefaults (a user-readable plist) for its
/// structure, but header *values* are moved to an injectable `SecretStore` (the Keychain in the app)
/// and blanked in the persisted JSON, so no auth token lands in cleartext. The value is re-injected
/// from the secret store on load, so editing + request-building see it transparently. Both the
/// `defaults` and the `secrets` store are injectable so the store is fully unit-testable.
@MainActor
@Observable
final class WebhookActionStore {
    private(set) var actions: [WebhookAction] = []

    private let defaults: UserDefaults
    private let secrets: any SecretStore
    private let storageKey = "tonebox.webhookActions"
    /// Performs the request, returning the HTTP status code. Injected for tests.
    private let send: (URLRequest) async throws -> Int
    /// Performs the request returning status **and** response body. The body is what makes a
    /// failure diagnosable — servers explain themselves there ("missing bearer token") and we
    /// used to throw it away, leaving the user with a bare "failed". Optional so existing
    /// callers/tests that inject only `send` keep working.
    private let sendWithBody: ((URLRequest) async throws -> (Int, Data))?

    /// Runs the request through whichever sender was injected.
    private func sendDetailed(_ request: URLRequest) async throws -> (Int, Data) {
        if let sendWithBody { return try await sendWithBody(request) }
        return (try await send(request), Data())
    }

    /// Keychain account key for a header's secret value — the header id is a globally unique UUID.
    private static func secretKey(_ header: WebhookAction.Header) -> String {
        "tonebox.webhook.header.\(header.id.uuidString)"
    }

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore(),
        send: @escaping (URLRequest) async throws -> Int = { request in
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        },
        sendWithBody: ((URLRequest) async throws -> (Int, Data))? = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.send = send
        self.sendWithBody = sendWithBody
        load()
    }

    // MARK: CRUD

    func upsert(_ action: WebhookAction) {
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        persist()
    }

    func delete(_ action: WebhookAction) {
        // Remove the action's header secrets from the store so nothing is stranded.
        for header in action.headers { secrets.setSecret(nil, for: Self.secretKey(header)) }
        actions.removeAll { $0.id == action.id }
        persist()
    }

    // MARK: Run

    /// Fires `action` with `tokens`. Never throws — failures come back as a `WebhookSendResult`
    /// so the caller can tell the user *why*, not just that something went wrong.
    @discardableResult
    func run(_ action: WebhookAction, tokens: [String: String]) async -> WebhookSendResult {
        // A header whose value resolved to nothing is never a request worth sending: URLSession
        // drops an empty header field, so the server sees no auth at all and answers with a
        // generic 401 that looks like a bad token. The usual cause is the Keychain refusing the
        // secret to this binary (a re-signed build invalidates the item's ACL), which is
        // invisible from the UI — so fail here, naming the header, instead of on the wire.
        let emptyValued = action.headers
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.name.trimmingCharacters(in: .whitespaces) }
        if let name = emptyValued.first {
            webhookLog.error("action \(action.name, privacy: .public): header \(name, privacy: .public) has no value")
            return .init(
                status: nil,
                detail: "the “\(name)” header has no value — re-enter it in Settings → Actions"
            )
        }

        // Enforce the credentialed-URL toggle here, at the boundary, regardless of what the
        // caller passed: a token that carries auth must never leave unless the action opted in.
        var tokens = tokens
        if !action.allowCredentialedURLs {
            for key in WebhookTemplate.credentialedTokenKeys { tokens[key] = nil }
        }

        guard let request = WebhookTemplate.buildRequest(action, tokens: tokens) else {
            webhookLog.error("action \(action.name, privacy: .public): invalid URL after substitution")
            return .init(status: nil, detail: "the URL isn’t valid once its {tokens} are filled in")
        }
        do {
            let (status, body) = try await sendDetailed(request)
            if (200 ... 299).contains(status) { return .init(status: status, detail: nil) }
            webhookLog.error("action \(action.name, privacy: .public): HTTP \(status)")
            return .init(status: status, detail: WebhookSendResult.summarize(body: body, status: status))
        } catch {
            webhookLog.error("action \(action.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .init(status: nil, detail: error.localizedDescription)
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              var decoded = try? JSONDecoder().decode([WebhookAction].self, from: data) else { return }
        // Re-inject each header's secret value from the secret store (blanked in the plaintext JSON).
        for i in decoded.indices {
            for j in decoded[i].headers.indices {
                decoded[i].headers[j].value = secrets.secret(for: Self.secretKey(decoded[i].headers[j])) ?? ""
            }
        }
        actions = decoded
    }

    private func persist() {
        // Move header values into the secret store and persist the list with them blanked, so an
        // auth token in a header never lands in the cleartext defaults plist.
        var sanitized = actions
        for i in sanitized.indices {
            for j in sanitized[i].headers.indices {
                let header = sanitized[i].headers[j]
                secrets.setSecret(header.value, for: Self.secretKey(header))
                sanitized[i].headers[j].value = ""
            }
        }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - Tokens

/// The `{token}` vocabulary a podcast episode exposes to a webhook action. Kept here so the
/// editor's help text and the runtime substitution can't drift apart.
enum PodcastWebhookTokens {
    /// Tokens + a one-line description, for the Settings editor's reference list.
    static let reference: [(token: String, description: String)] = [
        ("title", "Episode title"),
        ("channelTitle", "Show title"),
        ("enclosureUrl", "Direct audio URL"),
        ("feedUrl", "Show RSS feed URL"),
        ("guid", "Episode GUID"),
        ("pubDate", "Publish date"),
        ("durationSec", "Duration in seconds"),
        ("episodeImageUrl", "Episode artwork URL"),
        ("channelImageUrl", "Show artwork URL"),
        ("description", "Episode notes (plain text)"),
    ]

    /// Stand-in values for the editor's **Test** button, so an action can be verified without
    /// hunting down an episode to run it on. Deliberately obvious as a sample (example.com, a
    /// clearly-fake GUID) so anything it reaches can tell a test apart from a real submission —
    /// and so a transcription endpoint rejects it cheaply instead of ingesting junk.
    static let sample: [String: String] = [
        "title": "Test Episode",
        "channelTitle": "Baton Test",
        "enclosureUrl": "https://example.com/baton-test.mp3",
        "feedUrl": "https://example.com/feed.xml",
        "guid": "baton-test-guid",
        "pubDate": "2026-01-01T00:00:00Z",
        "durationSec": "60",
        "episodeImageUrl": "https://example.com/episode.jpg",
        "channelImageUrl": "https://example.com/show.jpg",
        "description": "A sample request sent by Baton’s Test button.",
    ]

    static func tokens(episode: PodcastEpisode, channel: PodcastChannel) -> [String: String] {
        var iso: String {
            guard let date = episode.publishDate else { return "" }
            return ISO8601DateFormatter().string(from: date)
        }
        return [
            "title": episode.title,
            "channelTitle": channel.title,
            "enclosureUrl": episode.enclosureURL.absoluteString,
            "feedUrl": channel.feedURL.absoluteString,
            "guid": episode.id,
            "pubDate": iso,
            "durationSec": episode.duration.map(String.init) ?? "",
            "episodeImageUrl": (episode.imageURL ?? channel.imageURL)?.absoluteString ?? "",
            "channelImageUrl": channel.imageURL?.absoluteString ?? "",
            "description": episode.description ?? "",
        ]
    }
}

// MARK: - Send result

/// The outcome of firing one action, carrying enough to tell the user what went wrong.
///
/// Actions talk to servers the user configured, so the failures are overwhelmingly setup
/// mistakes — a missing header, a typo'd path, an expired token. The server almost always says
/// exactly which ("missing bearer token"), and reporting a bare "failed" throws that away and
/// leaves them guessing with no log to check.
struct WebhookSendResult {
    /// HTTP status, or nil when the request never got that far (bad URL, network error).
    let status: Int?
    /// Human-readable failure reason; nil on success.
    let detail: String?

    var ok: Bool { detail == nil }

    /// One-line failure text for a toast: "HTTP 401 · missing bearer token".
    var toastSuffix: String {
        guard let detail else { return "" }
        if let status { return " · HTTP \(status) · \(detail)" }
        return " · \(detail)"
    }

    /// Distils a response body into something worth showing.
    ///
    /// Prefers the message field of a JSON error envelope — FastAPI uses `detail`, many others
    /// `message`/`error` — because that's the sentence the server wrote for a human. Falls back
    /// to trimmed plain text, and to a generic phrase for an empty body (or an HTML error page,
    /// which is never useful in a toast).
    static func summarize(body: Data, status: Int) -> String {
        let raw = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["detail", "message", "error", "error_description"] {
                if let value = obj[key] as? String, !value.isEmpty { return clip(value) }
            }
        }
        guard !raw.isEmpty, !raw.lowercased().hasPrefix("<") else {
            return genericReason(for: status)
        }
        return clip(raw)
    }

    /// A plain-language hint when the server said nothing useful.
    private static func genericReason(for status: Int) -> String {
        switch status {
        case 401, 403: "the server rejected the credentials — check the Authorization header"
        case 404: "the server has no such path — check the URL"
        case 405: "wrong HTTP method for that URL"
        case 408, 504: "the server timed out"
        case 413: "the request was too large"
        case 422, 400: "the server rejected the request body"
        case 500 ... 599: "the server errored"
        default: "unexpected response"
        }
    }

    private static func clip(_ s: String, limit: Int = 120) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}

// MARK: - Runner (UI helper)

/// Runs a webhook action and posts a success/failure toast. Used by the per-item menu and the
/// multi-select batch bar so both report results consistently.
@MainActor
enum WebhookRunner {
    static func run(_ action: WebhookAction, tokens: [String: String], _ model: MusicModel) {
        Task {
            let result = await model.webhookActions.run(action, tokens: tokens)
            model.music.postToast(
                result.ok
                    ? "“\(action.name)” done"
                    : "“\(action.name)” failed\(result.toastSuffix)",
                symbol: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                // A diagnosis needs reading time; a confirmation doesn't.
                seconds: result.ok ? 1.9 : 6
            )
        }
    }

    /// The **Actions** submenu for a single item, or nil when the user has no actions configured.
    /// Every browse row that supports actions renders this the same way. `tokens` is a closure so
    /// the (sometimes credential-fetching) token set is only built when the menu is actually used.
    @MainActor @ViewBuilder
    static func menu(for tokens: @escaping () -> [String: String], _ model: MusicModel) -> some View {
        if !model.webhookActions.actions.isEmpty {
            Menu("Actions", systemImage: "bolt.horizontal.circle") {
                ForEach(model.webhookActions.actions) { action in
                    Button(action.name, systemImage: SFSymbolCatalog.resolved(action.icon)) {
                        run(action, tokens: tokens(), model)
                    }
                }
            }
        }
    }

    /// Runs `action` over many token sets (a multi-selection), then posts one summary toast.
    static func runBatch(_ action: WebhookAction, tokenSets: [[String: String]], _ model: MusicModel) {
        guard !tokenSets.isEmpty else { return }
        Task {
            var ok = 0
            // Keep the first failure's reason: in a batch they're nearly always the same setup
            // mistake repeated, and one concrete cause beats "3 failed" with no explanation.
            var firstFailure: String?
            for tokens in tokenSets {
                let result = await model.webhookActions.run(action, tokens: tokens)
                if result.ok { ok += 1 } else if firstFailure == nil { firstFailure = result.toastSuffix }
            }
            let failed = tokenSets.count - ok
            let symbol = failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            let message = failed == 0
                ? "“\(action.name)” · \(ok) done"
                : "“\(action.name)” · \(ok) done, \(failed) failed\(firstFailure ?? "")"
            model.music.postToast(message, symbol: symbol, seconds: failed == 0 ? 1.9 : 6)
        }
    }
}

// MARK: - Settings pane

/// The **Actions** settings pane — manage user-defined webhook actions. Mirrors the Servers
/// pane: a grouped `Form` list with add/edit via a sheet, and inline delete.
struct BatonActionsPane: View {
    @Environment(MusicModel.self) private var model
    @State private var editing: WebhookAction?
    @State private var showingNew = false

    private var store: WebhookActionStore { model.webhookActions }

    var body: some View {
        Form {
            Section("Webhook Actions") {
                if store.actions.isEmpty {
                    Text("No actions yet. Add one to send a media item to an HTTP endpoint — "
                        + "e.g. POST a podcast episode's audio URL to a save-transcript service.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(store.actions) { action in
                        HStack(spacing: 10) {
                            Image(systemName: SFSymbolCatalog.resolved(action.icon))
                                .foregroundStyle(Color.accentColor).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(action.name.isEmpty ? "(untitled)" : action.name)
                                Text("\(action.method.rawValue) \(action.urlTemplate)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Edit") { editing = action }
                            Button(role: .destructive) { store.delete(action) } label: {
                                Image(systemName: "trash")
                            }
                            .help("Delete action")
                        }
                    }
                }
                Text("Actions appear in the ••• / right-click menu on podcast episodes and in the "
                    + "multi-select bar. Requests fire only when you run an action. Tokens like "
                    + "{enclosureUrl} are filled from the item.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Button { showingNew = true } label: { Label("Add Action…", systemImage: "plus") }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { action in
            WebhookActionEditor(action: action) { store.upsert($0) }
        }
        .sheet(isPresented: $showingNew) {
            WebhookActionEditor(action: WebhookAction(name: "", urlTemplate: "https://")) { store.upsert($0) }
        }
    }
}

// MARK: - Editor sheet

/// Add / edit a webhook action. A `Form` sheet matching `RadioStationEditor`'s shape, with a
/// token reference so you can see what placeholders are available.
struct WebhookActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicModel.self) private var model
    @State private var draft: WebhookAction
    /// Outcome of the last Test, shown inline. Nil until one runs.
    @State private var testResult: WebhookSendResult?
    @State private var testing = false
    let onSave: (WebhookAction) -> Void

    init(action: WebhookAction, onSave: @escaping (WebhookAction) -> Void) {
        _draft = State(initialValue: action)
        self.onSave = onSave
    }

    /// Fires the DRAFT (not the saved copy) against the real endpoint with sample tokens, so a
    /// misconfigured header or URL surfaces here rather than the first time you use it on an
    /// episode — which is how an empty auth header went unnoticed through two rounds of fixes.
    private func runTest() {
        testing = true
        testResult = nil
        Task {
            let result = await model.webhookActions.run(draft, tokens: PodcastWebhookTokens.sample)
            testResult = result
            testing = false
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: draft.urlTemplate.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Action").font(.headline).padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Save transcript"))
                    SymbolField(symbol: $draft.icon, label: "Icon (SF Symbol)")
                    Picker("Method", selection: $draft.method) {
                        ForEach(WebhookAction.Method.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("URL", text: $draft.urlTemplate, prompt: Text("https://example.com/transcribe"))
                        .textContentType(.URL)
                }
                Section("Headers") {
                    ForEach($draft.headers) { $header in
                        HStack {
                            TextField("Name", text: $header.name, prompt: Text("Authorization"))
                            TextField("Value", text: $header.value, prompt: Text("Bearer …"))
                            Button(role: .destructive) { draft.headers.removeAll { $0.id == header.id } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless)
                        }
                    }
                    Button { draft.headers.append(.init()) } label: { Label("Add Header", systemImage: "plus") }
                    // A header with a value but no name is silently dropped when the request is
                    // built — which shows up much later as an unexplained 401 from the server.
                    // Say so here, where it can still be fixed.
                    if draft.headers.contains(where: {
                        $0.name.trimmingCharacters(in: .whitespaces).isEmpty
                            && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
                    }) {
                        Label(
                            "A header with a value but no name won’t be sent. Add a name (e.g. Authorization) or remove the row.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                    // The mirror image, and the harder one to spot: the name is right but the value
                    // is blank. Header values live in the Keychain, so this is also what you see if
                    // the stored secret can no longer be read (a re-signed build invalidates the
                    // item's ACL) — the row looks configured while sending nothing.
                    if draft.headers.contains(where: {
                        !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                            && $0.value.trimmingCharacters(in: .whitespaces).isEmpty
                    }) {
                        Label(
                            "A header with a name but no value won’t be sent. Re-enter the value — stored values are kept in the Keychain and can become unreadable after an app update.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                }
                Section {
                    Toggle("Allow credentialed URLs", isOn: $draft.allowCredentialedURLs)
                    Text("Lets **{streamUrl}** and **{downloadUrl}** be sent for library tracks. Those URLs embed your server credentials, so anything that receives one can read your whole library. Only turn this on for an endpoint you trust.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Security")
                }
                if draft.method.sendsBody {
                    Section("Body") {
                        Picker("Content Type", selection: $draft.contentType) {
                            ForEach(WebhookAction.ContentType.allCases) { Text($0.label).tag($0) }
                        }
                        if draft.contentType != .none {
                            TextEditor(text: $draft.bodyTemplate)
                                .font(.body.monospaced()).frame(minHeight: 90)
                        }
                    }
                }
                Section {
                    Text("An action fills whatever tokens match the item you run it on — songs, albums, artists, playlists, or podcast episodes. Unknown tokens are removed.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(MusicWebhookTokens.reference, id: \.kind) { group in
                        DisclosureGroup(group.kind) {
                            ForEach(group.tokens, id: \.token) { entry in
                                HStack(spacing: 6) {
                                    Text("{\(entry.token)}").font(.caption.monospaced()).foregroundStyle(Color.accentColor)
                                    if entry.credentialed {
                                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    Text(entry.description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    DisclosureGroup("Podcast episode") {
                        ForEach(PodcastWebhookTokens.reference, id: \.token) { entry in
                            HStack {
                                Text("{\(entry.token)}").font(.caption.monospaced()).foregroundStyle(Color.accentColor)
                                Spacer()
                                Text(entry.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Available Tokens")
                } footer: {
                    Label("A locked token carries your credentials and is only sent when “Allow credentialed URLs” is on.", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack(alignment: .firstTextBaseline) {
                Button {
                    runTest()
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("Test") }
                }
                .disabled(!canSave || testing)
                .help("Send one request to this URL using sample values, without saving")

                if let testResult {
                    Label {
                        Text(testResult.ok
                             ? "Worked\(testResult.status.map { " · HTTP \($0)" } ?? "")"
                             : "Failed\(testResult.toastSuffix.trimmingCharacters(in: .whitespaces))")
                            .font(.callout)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: testResult.ok
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(testResult.ok ? Color.green : Color.orange)
                }

                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: 520, height: 620)
    }
}
