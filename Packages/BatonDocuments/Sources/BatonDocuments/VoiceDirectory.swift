import Foundation

/// Every voice a renderer offers, in words a listener can choose from.
///
/// The import sheet, Change Voice and the dialogue cast used to show a suggestion alone: a
/// primary voice and a few alternates, named by their raw ids ("bf_emma on Kokoro"). The Baton
/// server lists every voice its Kokoro has (68 of them), so the pickers on both apps now show
/// the suggestion on top and every voice below, grouped by accent or language and by gender,
/// in readable names ("Heart, American, female"), searchable.
///
/// The names come from Kokoro's own id scheme, the one `VoiceCatalogue` reads: the first letter
/// is the language or accent ("a" American English, "b" British English, "e" Spanish, ...), the
/// second the gender ("f" female, "m" male), and what follows the underscore the voice's name.
/// An id that does not follow the scheme (a Chatterbox reference file, a voice blend) is shown
/// as it is, in a group of its own, so nothing a server offers is hidden.
public struct VoiceEntry: Sendable, Equatable, Hashable, Identifiable {
    /// The app's spec, "kokoro:af_heart".
    public var spec: String
    /// The engine's own id, "af_heart".
    public var rawID: String
    /// "Heart"; the raw id when the id cannot be read.
    public var name: String
    /// "American", "British", "Spanish", ...; nil when the id cannot be read.
    public var accent: String?
    /// "female" or "male"; nil when the id cannot be read.
    public var gender: String?
    /// The language code the voice speaks ("en", "es"), when the id says.
    public var language: String?

    public var id: String { spec }

    /// The id followed Kokoro's scheme, so the name, accent and gender are known.
    public var isReadable: Bool { accent != nil && gender != nil }

    /// "Heart, American, female"; the raw id alone when the id cannot be read.
    public var label: String {
        guard let accent, let gender else { return rawID }
        return "\(name), \(accent), \(gender)"
    }

    /// The engine that reads it: `kokoro`, `chatterbox`, `openai`.
    public var engine: String { HTTPSpeechSynthesizer.split(spec).engine }

    /// The title of the group it is listed under: "American English, female" for a Kokoro
    /// voice, the engine's name for another engine's ("Expressive voices", "Chatterbox",
    /// An internal task), or "Other voices" for a Kokoro id that cannot be read.
    public var groupTitle: String {
        if engine != SpeechEngines.kokoro { return SpeechEngines.title(engine) }
        guard let gender, let first = rawID.first, let place = VoiceDirectory.places[first] else {
            return VoiceDirectory.otherGroupTitle
        }
        return "\(place.group), \(gender)"
    }
}

/// One group of the All voices list: its title and its voices, by name.
public struct VoiceGroup: Sendable, Equatable, Identifiable {
    public var title: String
    public var voices: [VoiceEntry]
    public var id: String { title }
}

public enum VoiceDirectory {
    /// Kokoro's language letters, in the order their groups are listed: the accent word a row
    /// says, the group's title, and the language code.
    static let places: [Character: (order: Int, accent: String, group: String, language: String)] = [
        "a": (0, "American", "American English", "en"),
        "b": (1, "British", "British English", "en"),
        "e": (2, "Spanish", "Spanish", "es"),
        "f": (3, "French", "French", "fr"),
        "h": (4, "Hindi", "Hindi", "hi"),
        "i": (5, "Italian", "Italian", "it"),
        "j": (6, "Japanese", "Japanese", "ja"),
        "p": (7, "Brazilian Portuguese", "Brazilian Portuguese", "pt"),
        "z": (8, "Mandarin Chinese", "Mandarin Chinese", "zh"),
    ]

    static let genders: [Character: String] = ["f": "female", "m": "male"]

    public static let otherGroupTitle = "Other voices"

    /// What a spec ("kokoro:af_heart", or a bare "af_heart") says about its voice.
    public static func entry(_ spec: String) -> VoiceEntry {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let engine = parts.count == 2 ? parts[0].lowercased() : "kokoro"
        let rawID = parts.count == 2 ? parts[1] : spec
        let full = "\(engine):\(rawID)"
        // Qwen3-TTS's preset speakers say who they are: "Ryan, English, male".
        if let preset = SpeechEngines.qwen3Preset(full) {
            return VoiceEntry(spec: full, rawID: rawID, name: readableName(rawID),
                              accent: DeliveryHints.languageNames[preset.language], gender: preset.gender,
                              language: preset.language)
        }
        let chars = Array(rawID)
        guard engine == "kokoro", chars.count > 3, chars[2] == "_",
              let place = places[chars[0]], let gender = genders[chars[1]],
              chars[3...].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return VoiceEntry(spec: full, rawID: rawID, name: rawID, accent: nil, gender: nil, language: nil)
        }
        return VoiceEntry(spec: full, rawID: rawID, name: readableName(String(chars[3...])),
                          accent: place.accent, gender: gender, language: place.language)
    }

    /// "heart" to "Heart", "santa_claus" to "Santa Claus". Kokoro keeps its earlier model's
    /// voices under a "v0" prefix ("af_v0bella"), so that one reads "Bella (v0)", told apart
    /// from today's Bella.
    static func readableName(_ tail: String) -> String {
        if tail.hasPrefix("v0"), tail.count > 2 { return "\(readableName(String(tail.dropFirst(2)))) (v0)" }
        return tail.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Every voice in `specs`, grouped by accent or language and then gender (American English
    /// first, female before male), each group by name, and the voices that cannot be read last.
    /// Duplicates are listed once.
    public static func groups(_ specs: [String]) -> [VoiceGroup] {
        var seen = Set<String>()
        let entries = specs.map(entry).filter { seen.insert($0.spec).inserted }
        let grouped = Dictionary(grouping: entries, by: \.groupTitle)
        return grouped.map { title, voices in
            VoiceGroup(title: title, voices: voices.sorted {
                ($0.name.lowercased(), $0.rawID) < ($1.name.lowercased(), $1.rawID)
            })
        }
        .sorted { rank($0) < rank($1) }
    }

    /// Kokoro's groups first, by place and gender, then each other engine's group in
    /// `SpeechEngines.order`, then Kokoro's unreadable ids.
    private static func rank(_ group: VoiceGroup) -> (Int, Int, String) {
        guard let first = group.voices.first else { return (Int.max, 0, group.title) }
        if first.engine != SpeechEngines.kokoro { return (100 + SpeechEngines.order(first.engine), 0, group.title) }
        guard first.isReadable, let letter = first.rawID.first,
              let place = places[letter] else { return (Int.max, 0, group.title) }
        return (place.order, first.gender == "female" ? 0 : 1, group.title)
    }

    /// The voices of every engine, grouped by engine: one section per engine that
    /// offered any, in `SpeechEngines.order`, each with its own groups as `groups` makes them.
    /// For a picker that shows engines as sections; `groups` is the same list flattened.
    public static func byEngine(_ specs: [String], matching query: String = "") -> [EngineSection] {
        let all = groups(specs, matching: query)
        let engines = Dictionary(grouping: all, by: { $0.voices.first?.engine ?? SpeechEngines.kokoro })
        return engines.map { EngineSection(engine: $0.key, title: SpeechEngines.title($0.key), groups: $0.value) }
            .sorted { (SpeechEngines.order($0.engine), $0.engine) < (SpeechEngines.order($1.engine), $1.engine) }
    }

    /// The voices that match what was typed in the search field: every word typed must begin a
    /// word of the voice's name, accent, language, gender or raw id, so "british male" finds
    /// George and not Emma, and "fem" finds the female voices. Case and accents are ignored. An
    /// empty search matches everything.
    public static func matches(_ entry: VoiceEntry, query: String) -> Bool {
        let tokens = words(query)
        guard !tokens.isEmpty else { return true }
        let haystack = Set(words("\(entry.label) \(entry.groupTitle) \(entry.rawID)") + [fold(entry.rawID)])
        return tokens.allSatisfy { token in haystack.contains { $0.hasPrefix(token) } }
    }

    /// `groups` with only the voices matching `query`, and no empty groups.
    public static func groups(_ specs: [String], matching query: String) -> [VoiceGroup] {
        groups(specs).compactMap { group in
            let voices = group.voices.filter { matches($0, query: query) }
            return voices.isEmpty ? nil : VoiceGroup(title: group.title, voices: voices)
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func words(_ text: String) -> [String] {
        fold(text).split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." }).map(String.init)
    }

    /// The voices shown on top, under Suggested: the voice remembered for the book's language
    /// first when the renderer offers it, then the suggestion's own, each once. `available` nil
    /// means the renderer did not list its voices, so a remembered voice is not offered: it may
    /// be one this renderer does not have.
    public static func suggested(_ suggestion: [String], remembered: String?, available: [String]?) -> [String] {
        var list: [String] = []
        if let remembered, available?.contains(remembered) == true { list.append(remembered) }
        for voice in suggestion where !list.contains(voice) { list.append(voice) }
        return list
    }

    /// Why All voices is missing, in a listener's words, for a Baton server that did not list
    /// its voices: one older than the route answers 404.
    public static func unavailableLine(_ error: Error?) -> String {
        let reason: String
        switch error {
        case GatewayBookError.http(404, _)?:
            reason = "your Baton server is older than the voice list"
        case let error as GatewayBookError:
            reason = error.listenerReason
        default:
            reason = "the Baton server isn't answering"
        }
        return "Only the suggested voices are here, because \(reason)."
    }
}

/// One engine's voices in a picker (`VoiceDirectory.byEngine`).
public struct EngineSection: Sendable, Equatable, Identifiable {
    public var engine: String
    /// "Kokoro", "Expressive voices", "Chatterbox".
    public var title: String
    public var groups: [VoiceGroup]
    public var id: String { engine }
}

/// What a renderer said when asked for its voices: the list, or nil and why not.
public struct VoiceListing: Sendable, Equatable {
    public var voices: [String]?
    public var problem: String?

    public init(voices: [String]?, problem: String? = nil) {
        self.voices = voices
        self.problem = voices == nil ? problem : nil
    }
}

/// The voice last chosen for a book in each language, kept on this device: the next
/// book in that language starts on it, if the renderer offers it. Only a narrator choice is
/// remembered, never a character's voice in a cast.
public struct VoiceChoiceMemory {
    public static let storageKey = "baton.documents.lastVoiceByLanguage"

    let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// "en" for "en-GB" and for a book with no declared language.
    public static func languageKey(_ language: String?) -> String {
        let code = language.map { String($0.prefix(2)).lowercased() } ?? ""
        return code.isEmpty ? "en" : code
    }

    public func remember(_ voice: String, language: String?) {
        var all = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        all[Self.languageKey(language)] = voice
        defaults.set(all, forKey: Self.storageKey)
    }

    public func last(language: String?) -> String? {
        (defaults.dictionary(forKey: Self.storageKey) as? [String: String])?[Self.languageKey(language)]
    }
}
