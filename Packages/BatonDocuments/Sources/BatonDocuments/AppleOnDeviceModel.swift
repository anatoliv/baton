import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple's on-device model can answer here, and if not, why (M7.1,
/// `specs/local-models-on-mac.md`, *Apple on-device*). Portable, so the reasons and their words
/// are the same everywhere; only reading the live value needs the framework.
public enum OnDeviceModelAvailability: Equatable, Sendable {
    case available
    /// This Mac cannot run Apple Intelligence (an Intel Mac, for one).
    case deviceNotEligible
    /// It can, but Apple Intelligence is off in System Settings.
    case appleIntelligenceNotEnabled
    /// It is on, and macOS is still downloading the model.
    case modelNotReady
    /// macOS 15: Foundation Models arrived in macOS 26.
    case olderSystem
    /// A reason this build does not know yet, as the framework names it.
    case other(String)

    public var isAvailable: Bool { self == .available }

    /// One sentence for Settings.
    public var explanation: String {
        switch self {
        case .available: "Ready. It runs on this Mac, with nothing to download."
        case .deviceNotEligible: "This Mac cannot run Apple Intelligence."
        case .appleIntelligenceNotEnabled: "Apple Intelligence is turned off. Turn it on in System Settings to use it here."
        case .modelNotReady: "macOS is still downloading Apple's model. Try again later."
        case .olderSystem: "Apple's on-device model needs macOS 26 or later."
        case let .other(reason): "Apple's on-device model is not available (\(reason))."
        }
    }
}

/// Apple's Foundation Models as a `ModelRouter` source (M7.1). It is local, so it needs no
/// consent, and it is run by the app rather than over HTTP: `executor(otherwise:)` answers for
/// `.appleOnDevice` sources and hands every other source to the HTTP client.
///
/// Where a task's prompt asks for JSON, the reply is generated as a `@Generable` type and handed
/// back as that JSON, so the parsers the other sources use read it unchanged. Which task is
/// running comes from `ModelRouter.currentTask`.
public enum AppleOnDeviceModel {
    public static let sourceName = "Apple Intelligence on this Mac"
    /// Instructions, prompt, schema and reply together, on macOS 26 (`contextSize` is read when
    /// the framework is there, since a later model may be larger).
    public static let defaultContextTokens = 4_096

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unavailable(OnDeviceModelAvailability)
        case unsupportedLanguage
        case contextTooSmall

        public var description: String {
            switch self {
            case let .unavailable(why): why.explanation
            case .unsupportedLanguage: "Apple Intelligence does not support this book's language"
            case .contextTooSmall: "the request was too long for Apple's on-device model"
            }
        }
    }

    public static func source(contextTokens: Int = contextTokens) -> ModelSource {
        ModelSource(name: sourceName, provider: .appleOnDevice, baseURL: nil, model: "system", contextTokens: contextTokens)
    }

    /// The source when the model can answer here, else nil.
    public static func sourceIfAvailable() -> ModelSource? {
        availability.isAvailable ? source() : nil
    }

    public static var contextTokens: Int {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return SystemLanguageModel.default.contextSize }
        #endif
        return defaultContextTokens
    }

    /// The live availability on this device.
    public static var availability: OnDeviceModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady): return .modelNotReady
            case let .unavailable(reason): return .other(String(describing: reason))
            @unknown default: return .other("unknown")
            }
        }
        return .olderSystem
        #else
        return .olderSystem
        #endif
    }

    /// An executor that runs `.appleOnDevice` sources here and passes the rest to `otherwise`.
    public static func executor(otherwise: @escaping ModelRouter.Executor) -> ModelRouter.Executor {
        { source, system, user in
            guard source.provider == .appleOnDevice else { return try await otherwise(source, system, user) }
            return try await respond(task: ModelRouter.currentTask, system: system, user: user)
        }
    }

    /// One prompt on the on-device model: typed for a task whose prompt asks for JSON, text
    /// otherwise. Greedy sampling, like the temperature 0 the HTTP sources are asked for.
    public static func respond(task: ModelTask?, system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let availability = availability
            guard availability.isAvailable else { throw Failure.unavailable(availability) }
            let session = LanguageModelSession(instructions: system)
            let options = GenerationOptions(samplingMode: .greedy)
            do {
                switch task {
                case ModelTask.voiceSuggestion?:
                    return try await session.respond(to: user, generating: GeneratedVoiceSuggestion.self, options: options)
                        .rawContent.jsonString
                case ModelTask.pronunciations?:
                    return try await session.respond(to: user, generating: GeneratedPronunciations.self, options: options)
                        .rawContent.jsonString
                default:
                    return try await session.respond(to: user, options: options).content
                }
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .unsupportedLanguageOrLocale: throw Failure.unsupportedLanguage
                case .exceededContextWindowSize: throw Failure.contextTooSmall
                default: throw error
                }
            }
        }
        throw Failure.unavailable(.olderSystem)
        #else
        throw Failure.unavailable(.olderSystem)
        #endif
    }
}

#if canImport(FoundationModels)
/// The voice suggestion's reply, the shape `VoiceCaster.system` asks for.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct GeneratedVoiceSuggestion {
    @Guide(description: "The book's genre")
    var genre: String
    @Guide(description: "The period the book is set in or was written in")
    var era: String
    @Guide(description: "The book's tone, in a few words")
    var tone: String
    @Guide(description: "The chosen voice id, exactly as it appears in the VOICES list")
    var primary_voice: String
    @Guide(description: "Two other voice ids from the VOICES list, different from the chosen one", .count(2))
    var alternates: [String]
    @Guide(description: "Reading speed", .range(0.85...1.1))
    var speed: Double
    @Guide(description: "One sentence on why this voice suits the book")
    var rationale: String
}

/// The pronunciation proposal's reply, the shape `PronunciationLexicon.system` asks for.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct GeneratedPronunciations {
    @Guide(description: "Only the words a text-to-speech voice would get wrong; empty when there are none")
    var words: [GeneratedPronunciation]
}

@available(macOS 26.0, iOS 26.0, *)
@Generable
struct GeneratedPronunciation {
    @Guide(description: "The word exactly as it was listed")
    var word: String
    @Guide(description: "Its pronunciation in IPA")
    var ipa: String
}
#endif
