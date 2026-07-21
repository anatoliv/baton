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
        }
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.send = send
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

    /// Fires `action` with `tokens`. Returns true on a 2xx response. Never throws — failures
    /// are logged and reported false so callers can toast.
    @discardableResult
    func run(_ action: WebhookAction, tokens: [String: String]) async -> Bool {
        guard let request = WebhookTemplate.buildRequest(action, tokens: tokens) else {
            webhookLog.error("action \(action.name, privacy: .public): invalid URL after substitution")
            return false
        }
        do {
            let status = try await send(request)
            let ok = (200 ... 299).contains(status)
            if !ok { webhookLog.error("action \(action.name, privacy: .public): HTTP \(status)") }
            return ok
        } catch {
            webhookLog.error("action \(action.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
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

// MARK: - Runner (UI helper)

/// Runs a webhook action and posts a success/failure toast. Used by the per-item menu and the
/// multi-select batch bar so both report results consistently.
@MainActor
enum WebhookRunner {
    static func run(_ action: WebhookAction, tokens: [String: String], _ model: MusicModel) {
        Task {
            let ok = await model.webhookActions.run(action, tokens: tokens)
            model.music.postToast(
                ok ? "“\(action.name)” done" : "“\(action.name)” failed",
                symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
        }
    }

    /// Runs `action` over many token sets (a multi-selection), then posts one summary toast.
    static func runBatch(_ action: WebhookAction, tokenSets: [[String: String]], _ model: MusicModel) {
        guard !tokenSets.isEmpty else { return }
        Task {
            var ok = 0
            for tokens in tokenSets where await model.webhookActions.run(action, tokens: tokens) { ok += 1 }
            let failed = tokenSets.count - ok
            let symbol = failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            let message = failed == 0
                ? "“\(action.name)” · \(ok) done"
                : "“\(action.name)” · \(ok) done, \(failed) failed"
            model.music.postToast(message, symbol: symbol)
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
                            Image(systemName: action.icon.isEmpty ? "bolt.horizontal.circle" : action.icon)
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
    @State private var draft: WebhookAction
    let onSave: (WebhookAction) -> Void

    init(action: WebhookAction, onSave: @escaping (WebhookAction) -> Void) {
        _draft = State(initialValue: action)
        self.onSave = onSave
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
                    TextField("Icon (SF Symbol)", text: $draft.icon, prompt: Text("doc.text"))
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
                Section("Available Tokens") {
                    ForEach(PodcastWebhookTokens.reference, id: \.token) { entry in
                        HStack {
                            Text("{\(entry.token)}").font(.caption.monospaced()).foregroundStyle(Color.accentColor)
                            Spacer()
                            Text(entry.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
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
