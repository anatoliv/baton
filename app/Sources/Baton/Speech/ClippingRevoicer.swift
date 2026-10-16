import BatonDocuments
import BatonPlaybackKit
import Foundation
import Observation

/// Change Voice… on a kept reading: its stored words read again in another voice,
/// by the path `ReadAloudCoordinator.keepAsClipping` takes (the same chunks to the same voice
/// server, encoded by `ReadAloudExport`), the new file taking the old one's place in the same row.
///
/// The old audio plays until the new file is whole: nothing is replaced before the last chunk
/// is encoded, so Stop, a failure or quitting part way leaves the reading in its old voice. A
/// reading that went to the other devices goes again in its new voice, and the old copy is
/// stated gone in the shared ledger so the iPhone swaps it rather than keeping both.
@MainActor
@Observable
final class ClippingRevoicer {
    static let shared = ClippingRevoicer()

    struct Progress: Equatable {
        var voice: String
        var fraction: Double
    }

    enum Problem: Error, CustomStringConvertible, Equatable {
        case noText
        case notAServerVoice(String)
        var description: String {
            switch self {
            case .noText: return "this clipping has no words kept with it to read again"
            case let .notAServerVoice(voice): return "\(voice) is not a voice the voice server reads"
            }
        }
    }

    /// Clippings being read again, by clipping id: the voice and how far it has got.
    private(set) var running: [String: Progress] = [:]

    @ObservationIgnored var synthesize: (String, SpeechConfig.Voice) async throws -> Data = { text, voice in
        try await SpeechService.synthesize(text: text, voice: voice)
    }
    /// Sends the new file to the home gateway, as keeping a reading does; the digest it landed
    /// under, or nil with no gateway set up. Tests replace it.
    @ObservationIgnored var upload: (_ file: URL, _ name: String, _ origin: String?) async throws -> String? = ClippingRevoicer.gatewayUpload
    /// Removes the old copy from the gateway, by digest. Tests replace it.
    @ObservationIgnored var removeShared: (_ digest: String) async -> Void = ClippingRevoicer.gatewayDelete
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    /// `kokoro:af_sky` as the voice server takes it, or nil for a voice it does not read.
    nonisolated static func speechVoice(_ spec: String) -> SpeechConfig.Voice? {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let engine = SpeechConfig.Engine(rawValue: parts[0].lowercased()) else { return nil }
        return SpeechConfig.Voice(engine: engine, voice: parts[1])
    }

    /// Start reading `item` again in `voice`; `finished` hears how it went (nil when it worked,
    /// and not at all when stopped).
    func start(_ item: ClippingStore.Item, voice: String, in store: ClippingStore,
               finished: @escaping @MainActor (Error?) -> Void) {
        tasks[item.id]?.cancel()
        tasks[item.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.revoice(item, to: voice, in: store)
                finished(nil)
            } catch is CancellationError {
                // Stopped: the reading keeps its old voice.
            } catch {
                finished(error)
            }
            self.tasks[item.id] = nil
        }
    }

    /// Stop reading it again: the old voice stays.
    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        running[id] = nil
    }

    /// Read the clipping's words again in `voice` and give it the new audio, keeping its row.
    func revoice(_ item: ClippingStore.Item, to voice: String, in store: ClippingStore) async throws {
        guard let text = item.clipping.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw Problem.noText
        }
        guard let speechVoice = Self.speechVoice(voice) else { throw Problem.notAServerVoice(voice) }
        // The words were kept as the reading's prepared chunks joined by spaces: cut again at
        // sentences, the size read aloud speaks.
        let chunks = SentenceSplitter.chunks(text)
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("baton-revoice-\(UUID().uuidString).m4a")
        running[item.id] = Progress(voice: voice, fraction: 0)
        defer { running[item.id] = nil }
        do {
            try await ReadAloudExport.write(chunks: chunks, voice: speechVoice, to: staged, synthesize: synthesize,
                                            fallback: false) { [weak self] fraction in
                self?.running[item.id]?.fraction = fraction
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        let oldDigest = item.clipping.sha256
        let (replaced, _) = try store.replaceAudio(id: item.id, with: staged, sha256: nil, voice: voice)
        readAloudLog.notice("a kept reading was read again in \(voice, privacy: .public)")

        // To the other devices as keeping it did, under the name the Mac shows. Best effort: the
        // reading is in its new voice here either way.
        let name = "\(replaced.clipping.title).\(replaced.url.pathExtension.isEmpty ? "m4a" : replaced.url.pathExtension)"
        guard let digest = try? await upload(replaced.url, name, replaced.clipping.source) else { return }
        store.setSHA256(id: item.id, to: digest)
        if let oldDigest, oldDigest != digest {
            var ledger = store.ledger
            ledger.remove(oldDigest)
            store.ledger = ledger
            await removeShared(oldDigest)
        }
    }

    // MARK: The gateway, as Settings configures it

    private static func gateway() -> GatewayFiles? {
        let raw = (BatonStorage.defaults.string(forKey: "baton.agent.gatewayURL") ?? "").trimmingCharacters(in: .whitespaces)
        let token = (NavidromeKeychain.secret(account: "baton.agent.gatewayToken") ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !token.isEmpty, let url = URL(string: raw), url.host != nil else { return nil }
        return GatewayFiles(gatewayURL: url, token: token)
    }

    private static func gatewayUpload(_ file: URL, _ name: String, _ origin: String?) async throws -> String? {
        guard let files = gateway() else { return nil }
        return try await files.upload(file, name: name, contentType: "audio/mp4",
                                      origin: origin ?? Host.current().localizedName ?? "Mac").sha256
    }

    private static func gatewayDelete(_ digest: String) async {
        try? await gateway()?.delete(id: digest)
    }
}
