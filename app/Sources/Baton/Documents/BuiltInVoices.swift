import BatonDocuments
import BatonKokoroMLX
import BatonSubsonicKit
import Foundation

/// A speech engine that runs in Baton's own process. The one there is today is Kokoro on MLX
/// (`BuiltInVoices`); tests give a stub.
protocol BuiltInSpeechEngine: Sendable {
    /// True when this engine speaks `voice` (an app id like `kokoro:af_heart`).
    func speaks(_ voice: String) -> Bool
    /// 24 kHz mono 16-bit WAV, the format the Kokoro server returns.
    func synthesizeWAV(text: String, voice: String, speed: Double?) async throws -> Data
}

/// The built-in "This Mac" voices: Kokoro-82M on MLX, in Baton's own
/// process, so a person with no voice server can still turn a document into an audiobook. Off
/// until the 342 MB model is downloaded from Settings → Speech; English voices only.
///
/// The model lives in `Application Support/Baton/Models/kokoro-mlx` (a probe launch's own support
/// directory under a probe), out of Time Machine, and is checked against its pinned sha256 before
/// it is kept. The engine loads on the first render and stays loaded; MLX's buffer cache is
/// capped at 512 MB (measured footprint 3.0 GB while rendering, 29 GB uncapped).
final class BuiltInVoices: BuiltInSpeechEngine, @unchecked Sendable {
    static let shared = BuiltInVoices(store: KokoroModelStore(directory: defaultDirectory()))

    /// `Application Support/Baton/Models/kokoro-mlx`, under a probe's own support directory when
    /// this is a probe launch. Not created until the download starts.
    static func defaultDirectory() -> URL {
        BatonStorage.directory(for: BatonStorage.current)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("kokoro-mlx", isDirectory: true)
    }

    /// MLX runs on Apple silicon only; the Intel half of the universal app never touches it.
    static let appleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    /// MLX's shaders are in the app bundle (and this Mac can run them) or not, for the life of
    /// the process.
    static let shadersPresent = appleSilicon && KokoroMLXRuntime.metalLibraryURL() != nil

    let store: KokoroModelStore
    private let lock = NSLock()
    private var engine: KokoroEngine?

    init(store: KokoroModelStore) {
        self.store = store
    }

    /// Downloaded, checked, and runnable in this build.
    var isAvailable: Bool { Self.shadersPresent && store.isInstalled }

    /// The app's ids for the built-in voices (`kokoro:af_heart`), sorted, when they can be used;
    /// none otherwise.
    var availableVoiceIDs: [String] {
        isAvailable ? Self.englishVoices.sorted().map(KokoroVoices.appVoice(for:)) : []
    }

    /// Itself when available, so the synthesizer can register it; nil otherwise.
    var ifAvailable: (any BuiltInSpeechEngine)? { isAvailable ? self : nil }

    func speaks(_ voice: String) -> Bool {
        guard let name = KokoroVoices.modelName(for: voice) else { return false }
        return Self.englishVoices.contains(name)
    }

    func synthesizeWAV(text: String, voice: String, speed: Double?) async throws -> Data {
        let engine = try loadedEngine()
        // Rendering is synchronous GPU work (a 300 character chunk is about a second); keep it off
        // the caller's executor.
        return try await Task.detached(priority: .utility) {
            do {
                return try engine.synthesizeWAV(text: text, voice: voice, speed: speed)
            } catch let error as KokoroEngineError {
                throw SynthesisError.permanent("the built-in voices: \(error.description)")
            }
        }.value
    }

    /// Drops the loaded model (before removing its files).
    func unload() {
        lock.lock()
        engine = nil
        lock.unlock()
    }

    private func loadedEngine() throws -> KokoroEngine {
        lock.lock()
        defer { lock.unlock() }
        if let engine { return engine }
        do {
            let made = try KokoroEngine(modelDirectory: store.directory)
            engine = made
            return made
        } catch let error as KokoroEngineError {
            throw SynthesisError.permanent("the built-in voices: \(error.description)")
        }
    }

    /// The 28 English voices in the pinned `voices.npz`, known without loading the
    /// model so routing a voice costs nothing. A voice outside this list goes to the server.
    static let englishVoices: Set<String> = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova",
        "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]
}
