import BatonDocuments
import Foundation

/// The voice engines this gateway renders books with, from its environment:
///
///   BATON_TTS_KOKORO_URL       Kokoro (default http://127.0.0.1:8880)
///   BATON_TTS_CHATTERBOX_URL   Chatterbox, when set
///   BATON_TTS_OPENAI_URL       an OpenAI-compatible speech server (Qwen3-TTS first), when set;
///                              voices on it are `openai:<voice>`
///   BATON_TTS_OPENAI_MODEL     the model it is sent (default qwen3-tts)
///   BATON_TTS_OPENAI_KEY_FILE  a file holding its key, for a server that asks for one, readable
///                              by its owner only; or
///   BATON_TTS_OPENAI_KEY       the key itself. Neither is ever logged.
///
/// An address must be http or https, as on the Mac. What is wrong is said in `problems`, for the
/// log, in words that never include a key.
public enum SpeechEngineConfig {
    public struct Loaded: Equatable {
        public var endpoints: [SpeechEngineEndpoint]
        public var problems: [String]
    }

    public enum KeyFileError: Error, Equatable {
        /// Group or others may read or write it: chmod 600.
        case tooOpen(mode: Int)
        case unreadable
    }

    /// The key in `path`, refused when the file's mode lets its group or anyone else at it.
    public static func readPrivateFile(_ path: String) throws -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue else { throw KeyFileError.unreadable }
        guard mode & 0o077 == 0 else { throw KeyFileError.tooOpen(mode: mode & 0o777) }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw KeyFileError.unreadable }
        return text
    }

    public static func load(_ env: [String: String],
                            readFile: (String) throws -> String = SpeechEngineConfig.readPrivateFile) -> Loaded {
        var problems: [String] = []
        func url(_ key: String) -> URL? {
            guard let text = env[key]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            guard let url = URL(string: text), url.host != nil,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                problems.append("\(key) is not an http or https address, so it is not used")
                return nil
            }
            return url
        }
        var out = [SpeechEngineEndpoint(engine: SpeechEngines.kokoro,
                                        baseURL: url("BATON_TTS_KOKORO_URL") ?? URL(string: "http://127.0.0.1:8880")!)]
        if let chatterbox = url("BATON_TTS_CHATTERBOX_URL") {
            out.append(SpeechEngineEndpoint(engine: SpeechEngines.chatterbox, baseURL: chatterbox))
        }
        if let server = url("BATON_TTS_OPENAI_URL") {
            var key: String?
            var usable = true
            if let path = env["BATON_TTS_OPENAI_KEY_FILE"], !path.isEmpty {
                do {
                    key = try readFile(path)
                } catch KeyFileError.tooOpen(let mode) {
                    problems.append("BATON_TTS_OPENAI_KEY_FILE \(path) can be read by others (mode \(String(mode, radix: 8))); "
                        + "chmod 600 it. The expressive voice server is off until then")
                    usable = false
                } catch {
                    problems.append("BATON_TTS_OPENAI_KEY_FILE \(path) could not be read. The expressive voice server is off until it can")
                    usable = false
                }
            } else {
                key = env["BATON_TTS_OPENAI_KEY"]
            }
            if usable {
                let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
                let model = env["BATON_TTS_OPENAI_MODEL"]?.trimmingCharacters(in: .whitespaces)
                out.append(SpeechEngineEndpoint(engine: SpeechEngines.openAI, baseURL: server,
                                                model: model?.isEmpty == false ? model : nil,
                                                apiKey: trimmed?.isEmpty == false ? trimmed : nil))
            }
        }
        return Loaded(endpoints: out, problems: problems)
    }

    /// The endpoints alone.
    public static func endpoints(_ env: [String: String],
                                 readFile: (String) throws -> String = SpeechEngineConfig.readPrivateFile) -> [SpeechEngineEndpoint] {
        load(env, readFile: readFile).endpoints
    }
}
