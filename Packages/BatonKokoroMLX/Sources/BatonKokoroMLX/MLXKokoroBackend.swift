import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

/// Kokoro on MLX: the vendored KokoroSwift model and the voices from `voices.npz`.
final class MLXKokoroBackend: KokoroBackend {
    private let tts: KokoroTTS
    private let voices: [String: MLXArray]

    init(weights: URL, voices voicesURL: URL) throws {
        guard let raw = NpyzReader.read(fileFromPath: voicesURL), !raw.isEmpty else {
            throw KokoroEngineError.voicesUnreadable
        }
        var byName: [String: MLXArray] = [:]
        for (key, array) in raw {
            byName[key.hasSuffix(".npy") ? String(key.dropLast(4)) : key] = array
        }
        voices = byName
        tts = KokoroTTS(modelPath: weights)
    }

    func voiceNames() throws -> [String] { Array(voices.keys) }

    func render(text: String, voice: String, british: Bool, speed: Float) throws -> [Float] {
        guard let embedding = voices[voice] else { throw KokoroEngineError.unknownVoice(voice) }
        do {
            let (samples, _) = try tts.generateAudio(voice: embedding, language: british ? .enGB : .enUS,
                                                     text: text, speed: speed)
            return samples
        } catch KokoroTTS.KokoroTTSError.tooManyTokens {
            throw KokoroChunkTooLong()
        } catch KokoroTTS.KokoroTTSError.noSpeakableText {
            return []
        }
    }
}

/// MLX's process-wide settings for this engine, and where its compiled shaders are.
public enum KokoroMLXRuntime {
    /// MLX keeps freed GPU buffers for reuse up to its memory limit, which on a large Mac is
    /// tens of GB of footprint (29 GB measured in TBX-10849). Capped at 512 MB the footprint was
    /// 3.0 GB for about 10% of speed.
    public static let gpuCacheLimitBytes = 512 * 1_048_576

    nonisolated(unsafe) private static var applied = false
    private static let lock = NSLock()

    /// Sets MLX's buffer cache limit, once per process. Touching MLX's GPU state loads its shaders,
    /// so this is only called once `metalLibraryURL()` has found them; without them MLX aborts.
    public static func applyCacheLimit() {
        lock.lock()
        defer { lock.unlock() }
        guard !applied else { return }
        GPU.set(cacheLimit: gpuCacheLimitBytes)
        applied = true
    }

    /// MLX's cache limit as MLX reports it, or nil before `applyCacheLimit()` (reading it any
    /// earlier would load the shaders).
    public static var cacheLimit: Int? {
        lock.lock()
        defer { lock.unlock() }
        return applied ? GPU.cacheLimit : nil
    }

    /// MLX's own peak and current GPU memory in bytes, for measurement.
    public static var memory: (peak: Int, active: Int, cache: Int) {
        (GPU.peakMemory, GPU.activeMemory, GPU.cacheMemory)
    }

    /// The metallib MLX will load, found the way MLX looks for it (mlx-swift 0.29.1,
    /// `backend/metal/device.cpp`, `load_default_library`), or nil when there is none and touching
    /// the GPU would abort the process:
    ///
    /// 1. `mlx.metallib`, then `Resources/mlx.metallib`, beside the binary that holds MLX;
    /// 2. `default.metallib` in an `mlx-swift_Cmlx.bundle` beside the main bundle or inside any
    ///    loaded bundle's resources (where Xcode puts it when it compiles MLX's shaders, and where
    ///    the app's build phase puts the prebuilt one when it cannot);
    /// 3. `default.metallib` in the working directory.
    public static func metalLibraryURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let binary = Bundle(for: MLXArray.self).executableURL?.deletingLastPathComponent() {
            candidates += [binary.appendingPathComponent("mlx.metallib"),
                           binary.appendingPathComponent("Resources/mlx.metallib")]
        }
        let bundleRoots = [Bundle.main.bundleURL] + Bundle.allBundles.compactMap(\.resourceURL)
        for root in bundleRoots {
            let swiftpm = root.appendingPathComponent("mlx-swift_Cmlx.bundle")
            guard fm.fileExists(atPath: swiftpm.path) else { continue }
            let resources = Bundle(url: swiftpm)?.resourceURL ?? swiftpm
            candidates.append(resources.appendingPathComponent("default.metallib"))
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("default.metallib"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}
