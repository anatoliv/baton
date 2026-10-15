import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Model and voice servers running on this Mac (`specs/local-models-on-mac.md`, cards M7.2 to
/// M7.4): what their answers mean, with no networking of its own. The app makes the requests
/// these build and hands the bytes back here, so every rule about what an answer means is
/// tested against real captured responses rather than against a running server.
///
/// Baton never installs anything. It finds what is running, offers what is missing, and saves
/// a source only after it has answered a real request.
public enum LocalModelServers {
    public static let ollamaBaseURL = "http://127.0.0.1:11434"
    /// LM Studio's OpenAI-compatible root. Saved with the `/v1`, which `HTTPModelClient` expects.
    public static let lmStudioBaseURL = "http://127.0.0.1:1234/v1"
    /// Where Kokoro-FastAPI listens when it runs on this Mac (`./start-gpu_mac.sh`).
    public static let kokoroBaseURL = "http://127.0.0.1:8880"

    /// The context Baton asks Ollama for. Ollama's own default on a Mac under 24 GB is 4k, and it
    /// truncates longer prompts with no error, so the router always sends `num_ctx`.
    public static let ollamaContextTokens = 8_192
    /// LM Studio's `/v1/models` does not say what context a model was loaded with, and its own
    /// default is 4,096. Claiming less than the truth makes the router skip a chapter-sized task;
    /// claiming more would have it cut a chapter short in silence.
    public static let lmStudioContextTokens = 4_096

    /// Detection must not hold up the pane: a server on this Mac answers in milliseconds or not
    /// at all.
    public static let detectionTimeout: TimeInterval = 2

    static func get(_ base: String, _ path: String, timeout: TimeInterval = detectionTimeout) -> URLRequest? {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: trimmed + path), url.host != nil else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return request
    }
}

/// A model a local server has installed (Ollama) or offers (LM Studio).
public struct LocalModel: Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var sizeBytes: Int64?
    /// "8.2B"
    public var parameterSize: String?
    /// "Q4_K_M"
    public var quantization: String?
    /// The longest context the model supports, when the server says.
    public var contextLength: Int?

    public var id: String { name }

    public init(name: String, sizeBytes: Int64? = nil, parameterSize: String? = nil,
                quantization: String? = nil, contextLength: Int? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.contextLength = contextLength
    }
}

/// What a detection request came back with, before anything is concluded from it.
public enum LocalServerProbe: Equatable, Sendable {
    case answered(status: Int, body: Data)
    /// Refused, timed out, nothing listening. The string is the transport's reason.
    case noAnswer(String)
}

/// Where a server on this Mac stands, which is what its row says.
public enum LocalServerState: Equatable, Sendable {
    /// No app and no command-line install were found.
    case notInstalled
    /// Installed, and nothing answers on its port.
    case notRunning
    case running(models: [LocalModel])
    /// Something answered on the port, but not the way this server would.
    case unexpected(String)

    /// The rule, in one place: an answer that parses is the server, whatever was found on disk
    /// (a build run from source has no app bundle); no answer means not running when it is
    /// installed and not installed otherwise; an answer that does not parse is somebody else.
    public static func detect(installed: Bool, probe: LocalServerProbe,
                              parse: (Data) throws -> [LocalModel]) -> LocalServerState {
        switch probe {
        case .noAnswer:
            return installed ? .notRunning : .notInstalled
        case let .answered(status, body):
            guard (200..<300).contains(status) else {
                return .unexpected("Something on that port answered with HTTP \(status).")
            }
            do {
                return .running(models: try parse(body))
            } catch {
                return .unexpected("Something on that port answered, but not the way this server does.")
            }
        }
    }

    public var models: [LocalModel] {
        if case let .running(models) = self { return models }
        return []
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public enum LocalModelParseError: Error, Equatable {
    case unreadable
}

// MARK: - Ollama

public enum OllamaAPI {
    public static func tagsRequest(baseURL: String = LocalModelServers.ollamaBaseURL) -> URLRequest? {
        LocalModelServers.get(baseURL, "/api/tags")
    }

    /// `GET /api/tags`: `{"models":[{"name":…,"size":…,"details":{…}}]}`.
    public static func parseTags(_ data: Data) throws -> [LocalModel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { throw LocalModelParseError.unreadable }
        return models.compactMap { entry in
            guard let name = (entry["name"] as? String) ?? (entry["model"] as? String), !name.isEmpty else { return nil }
            let details = entry["details"] as? [String: Any] ?? [:]
            return LocalModel(name: name,
                              sizeBytes: (entry["size"] as? NSNumber)?.int64Value,
                              parameterSize: details["parameter_size"] as? String,
                              quantization: details["quantization_level"] as? String,
                              contextLength: (details["context_length"] as? NSNumber)?.intValue)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `POST /api/pull`, streamed. No timeout worth the name: a 6 GB download takes as long as
    /// it takes, and Cancel is how it stops early.
    public static func pullRequest(model: String, baseURL: String = LocalModelServers.ollamaBaseURL) -> URLRequest? {
        guard var request = LocalModelServers.get(baseURL, "/api/pull", timeout: 3_600) else { return nil }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true],
                                                       options: [.sortedKeys])
        return request
    }

    /// The source a tested model is saved as. Context is capped at what Baton asks for, never
    /// the model's maximum: `num_ctx` is what Ollama allocates, and 40k of cache for a
    /// two-thousand-token voice suggestion is memory taken from everything else on the Mac.
    public static func source(for model: LocalModel, baseURL: String = LocalModelServers.ollamaBaseURL) -> ModelSource {
        let context = min(LocalModelServers.ollamaContextTokens, model.contextLength ?? LocalModelServers.ollamaContextTokens)
        return ModelSource(name: "This Mac · Ollama · \(model.name)", provider: .ollama,
                           baseURL: baseURL, model: model.name, contextTokens: context)
    }
}

/// Progress through one streamed `/api/pull`. Ollama sends one JSON object per line: a status,
/// and for each layer a `digest` with `total` and, once bytes arrive, `completed`. The bar is
/// the sum over every layer seen, so the small layers after the weights do not reset it.
public struct OllamaPullProgress: Equatable, Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Ollama reported an error, such as a model name that does not exist.
        case server(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case let .server(message): return "Ollama said: \(message)"
            case let .unreadable(line): return "Ollama sent something that is not progress: \(line.prefix(80))"
            }
        }
    }

    public private(set) var status = ""
    public private(set) var succeeded = false
    private var layers: [String: Layer] = [:]

    private struct Layer: Equatable, Sendable {
        var total: Int64
        var completed: Int64
    }

    public init() {}

    public var completedBytes: Int64 { layers.values.reduce(0) { $0 + $1.completed } }
    public var totalBytes: Int64 { layers.values.reduce(0) { $0 + $1.total } }

    /// Nil until a layer has said how big it is, so the bar can be indeterminate rather than
    /// sit at zero looking stuck.
    public var fraction: Double? {
        if succeeded { return 1 }
        let total = totalBytes
        guard total > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(total))
    }

    /// Apply one line of the stream. Blank lines are ignored; an `error` throws.
    public mutating func apply(line: String) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable(trimmed)
        }
        if let error = json["error"] as? String { throw Failure.server(error) }
        if let status = json["status"] as? String {
            self.status = status
            if status == "success" { succeeded = true }
        }
        if let digest = json["digest"] as? String, let total = (json["total"] as? NSNumber)?.int64Value, total > 0 {
            let completed = (json["completed"] as? NSNumber)?.int64Value ?? layers[digest]?.completed ?? 0
            layers[digest] = Layer(total: total, completed: min(total, max(0, completed)))
        }
    }
}

// MARK: - LM Studio

public enum LMStudioAPI {
    public static func modelsRequest(baseURL: String = LocalModelServers.lmStudioBaseURL) -> URLRequest? {
        LocalModelServers.get(baseURL, "/models")
    }

    /// `GET /v1/models`: `{"data":[{"id":…}],"object":"list"}`. Embedding models are left out:
    /// they cannot answer a chat request, and offering one to test would only fail.
    public static func parseModels(_ data: Data) throws -> [LocalModel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { throw LocalModelParseError.unreadable }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            if id.lowercased().contains("embed") { return nil }
            return LocalModel(name: id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func source(for model: LocalModel, baseURL: String = LocalModelServers.lmStudioBaseURL) -> ModelSource {
        ModelSource(name: "This Mac · LM Studio · \(model.name)", provider: .openAICompatible,
                    baseURL: baseURL, model: model.name, contextTokens: LocalModelServers.lmStudioContextTokens)
    }
}

// MARK: - Choosing and fetching a model

/// The model offered for download, picked by the Mac's memory (`specs/local-models-on-mac.md`,
/// *Recommended models*). Sizes are the downloads Ollama lists.
public struct RecommendedModel: Equatable, Sendable {
    public var name: String
    public var downloadBytes: Int64
    public var licence: String

    public static func forMac(physicalMemory: UInt64) -> RecommendedModel {
        let gigabyte: UInt64 = 1 << 30
        if physicalMemory >= 24 * gigabyte {
            return RecommendedModel(name: "qwen3.5:9b", downloadBytes: 6_600_000_000, licence: "Apache 2.0")
        }
        return RecommendedModel(name: "qwen3.5:4b", downloadBytes: 3_400_000_000, licence: "Apache 2.0")
    }

    /// Why a pull must not start, or nil when it may. The model needs its own size on disk and
    /// room to spare: a volume filled to the last byte breaks more than the download.
    public static func pullRefusal(downloadBytes: Int64, freeBytes: Int64?) -> String? {
        guard let free = freeBytes else { return nil }
        let headroom: Int64 = 2_000_000_000
        guard free < downloadBytes + headroom else { return nil }
        return "This Mac has \(LocalModelFormat.bytes(free)) free, and this model needs \(LocalModelFormat.bytes(downloadBytes + headroom)) with room to spare."
    }
}

public enum LocalModelFormat {
    /// "3.4 GB", "850 MB": decimal units, as Ollama and Finder both show them.
    public static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: count)
    }
}

// MARK: - The test request

/// The one request a source must answer before it is saved. Structured, because every document
/// task asks for JSON, and a model that cannot return a one-key object will not return a cast
/// sheet. Trivial, because a test that takes a minute is a test nobody runs twice.
public enum LocalModelTest {
    public static let system = "You answer with JSON only. No explanation, no code fence."
    public static let user = #"Reply with exactly this JSON object and nothing else: {"ready": true}"#
    /// Enough for a cold load of an 8B model from disk, which is the slow part of a first test.
    public static let timeout: TimeInterval = 60
    /// Room for a reasoning model to think before it answers. LM Studio cannot be told to skip
    /// reasoning the way Ollama's `think: false` does, and at 64 tokens Qwen3 0.6B spent all of
    /// them thinking and returned nothing; at 1,024 it answered after 64 (TBX-10858, measured
    /// 2026-10-15). A model that follows the instruction stops after a handful of tokens anyway.
    public static let maxTokens = 1_024

    /// Whether the reply is the object that was asked for. A code fence or a reasoning block
    /// around it is forgiven; anything else is a model that will not follow a schema.
    public static func passed(_ reply: String) -> Bool {
        var text = reply
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["ready"] as? Bool) == true
    }
}

// MARK: - Kokoro

public enum KokoroAPI {
    public static func voicesRequest(baseURL: String = LocalModelServers.kokoroBaseURL) -> URLRequest? {
        LocalModelServers.get(baseURL, "/v1/audio/voices")
    }

    /// `{"voices":[{"id":…}]}` from Kokoro-FastAPI, or a bare list of names.
    public static func parseVoices(_ data: Data) throws -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["voices"] as? [Any] else { throw LocalModelParseError.unreadable }
        return raw.compactMap { element in
            if let name = element as? String { return name }
            if let entry = element as? [String: Any] { return (entry["id"] as? String) ?? (entry["name"] as? String) }
            return nil
        }
    }
}

/// Where Baton's configured Kokoro is, relative to this Mac.
public enum KokoroPlacement: Equatable, Sendable {
    case thisMac
    /// On the home network (or a tailnet): the host is named.
    case network(String)
    /// A public address.
    case elsewhere(String)
    /// Nobody has entered one; the address Baton would use is only a placeholder.
    case none

    public static func classify(configuredBaseURL: String, hasStoredHost: Bool) -> KokoroPlacement {
        guard hasStoredHost else { return .none }
        let base = configuredBaseURL.trimmingCharacters(in: .whitespaces)
        guard let host = URL(string: base)?.host?.lowercased(), !host.isEmpty else { return .none }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare == "::1" || bare.hasPrefix("127.") { return .thisMac }
        return ModelSource.isPrivateHost(bare) ? .network(host) : .elsewhere(host)
    }

    /// The sentence the Kokoro row shows, given whether a Kokoro answers on this Mac and with
    /// how many voices, and whether the Mac app's built-in voices (Kokoro on MLX, TBX-10854) are
    /// downloaded, which is what reads a book made on this Mac when no Kokoro server is set up.
    public func summary(localVoices: Int?, builtInVoicesReady: Bool = false) -> String {
        let local = localVoices.map { "A Kokoro is running on this Mac with \($0) voices." }
        switch self {
        case .thisMac:
            return localVoices.map { "Baton speaks through the Kokoro on this Mac, which has \($0) voices." }
                ?? "Baton is set to use a Kokoro on this Mac, and none is running."
        case let .network(host):
            let lead = "Baton uses the Kokoro at \(host) on your network."
            return local.map { "\(lead) \($0) To use it instead, set Kokoro under Services to \(LocalModelServers.kokoroBaseURL)." }
                ?? "\(lead) None is running on this Mac."
        case let .elsewhere(host):
            let lead = "Baton uses the Kokoro at \(host), which is not on this Mac or your network."
            return local.map { "\(lead) \($0)" } ?? lead
        case .none:
            return local.map { "\($0) Baton is not using it yet: set Kokoro under Services to \(LocalModelServers.kokoroBaseURL)." }
                ?? (builtInVoicesReady
                    ? "No Kokoro is set up, and none is running on this Mac. Books made on this Mac read with the built-in voices above, in English."
                    : "No Kokoro is set up, and none is running on this Mac. Books made on this Mac need one, or the built-in voices above once they are downloaded.")
        }
    }
}
