import BatonDocuments
import BatonSubsonicKit
import Foundation

/// Settings → Speech → **Voice engine for books**: which engine reads a book made on
/// this Mac, and where a new book is made by default.
///
/// Both are this Mac's own: neither key is in `PreferenceSync.syncedKeys`, because whether the
/// built-in voices are downloaded, and which voice server this Mac can reach, are facts about
/// this Mac. Speech's Reset to Defaults clears them (the Mac has no `SessionPurge`; that is the
/// phone's, and the phone has no engine choice).
enum BookVoiceSettings {
    /// Which engine reads a book made on this Mac.
    enum Engine: String, CaseIterable, Sendable {
        /// Built-in when it is downloaded and the voice is one of its 28 English voices,
        /// otherwise the voice server. What every Mac did before this setting existed.
        case automatic
        /// Only the built-in voices. A voice they do not have is refused, never sent to a server.
        case builtIn
        /// Only the voice servers, even when the built-in voices are downloaded.
        case server

        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .builtIn: "Built-in voices on this Mac"
            case .server: "Voice server"
            }
        }
    }

    /// Where a new book is made.
    enum MakeBooksOn: String, CaseIterable, Sendable {
        /// The import sheet asks, starting on the home server when it answers. Today's behaviour.
        case ask
        case thisMac
        case homeServer

        var title: String {
            switch self {
            case .ask: "Ask each time"
            case .thisMac: "This Mac"
            case .homeServer: "Baton server"
            }
        }
    }

    static let engineKey = "baton.documents.voiceEngine"
    static let makeBooksOnKey = "baton.documents.makeBooksOn"

    /// Overridable in tests; Baton's own defaults otherwise.
    nonisolated(unsafe) static var defaults: UserDefaults = BatonStorage.defaults

    static var engine: Engine {
        get { defaults.string(forKey: engineKey).flatMap(Engine.init(rawValue:)) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: engineKey) }
    }

    static var makeBooksOn: MakeBooksOn {
        get { defaults.string(forKey: makeBooksOnKey).flatMap(MakeBooksOn.init(rawValue:)) ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: makeBooksOnKey) }
    }

    /// Back to Automatic and Ask each time.
    static func reset() {
        defaults.removeObject(forKey: engineKey)
        defaults.removeObject(forKey: makeBooksOnKey)
    }

    // MARK: - Routing

    /// Where one voice goes under a setting.
    enum Route: Equatable {
        /// The built-in voices, in Baton's own process.
        case builtIn
        /// The voice server for that engine (`kokoro`, `chatterbox`).
        case server(String)
        /// Neither: the setting rules out the only engine that could read it. The text is
        /// written for the book's row ("Paused: …").
        case refused(String)
    }

    /// The rule, in one place:
    ///
    /// - **Automatic**: the built-in voices when they are downloaded and have this voice,
    ///   otherwise the voice server.
    /// - **Built-in voices on this Mac**: the built-in voices, or a plain refusal when they are
    ///   not downloaded or do not have this voice. Never a server.
    /// - **Voice server**: the voice server, even when the built-in voices are downloaded.
    ///
    /// `builtIn` is the engine when it is downloaded and runnable, nil otherwise.
    static func route(voice: String, engine: Engine, builtIn: (any BuiltInSpeechEngine)?) -> Route {
        // `"kokoro:bf_emma"` names its engine; a bare voice is Kokoro's, as in HTTPSpeechSynthesizer.
        let server = voice.contains(":") ? String(voice.prefix { $0 != ":" }).lowercased() : "kokoro"
        switch engine {
        case .server:
            return .server(server)
        case .automatic:
            return builtIn?.speaks(voice) == true ? .builtIn : .server(server)
        case .builtIn:
            guard let builtIn else { return .refused(notReadyReason) }
            guard builtIn.speaks(voice) else {
                return .refused("\(refusalPrefix) Built-in voices on this Mac, and \(voiceName(voice)) is not one of them: "
                    + "they are English Kokoro voices only. Choose a built-in voice, or set it to Automatic or Voice server in Settings, Speech")
            }
            return .builtIn
        }
    }

    /// Why Built-in cannot read anything on this Mac right now.
    static var notReadyReason: String {
        if !BuiltInVoices.appleSilicon {
            return "\(refusalPrefix) Built-in voices on this Mac, which need a Mac with Apple silicon. "
                + "Choose Voice server in Settings, Speech"
        }
        if !BuiltInVoices.shadersPresent {
            return "\(refusalPrefix) Built-in voices on this Mac, which this build of Baton cannot run. "
                + "Choose Voice server in Settings, Speech"
        }
        return "\(refusalPrefix) Built-in voices on this Mac, and they are not downloaded. "
            + "Download them in Settings, Speech, or choose Automatic or Voice server"
    }

    /// How every refusal starts. `SynthesisError.listenerReason` passes a message with this
    /// opening through as it is, since it is already written for the book's row.
    static let refusalPrefix = SynthesisError.voiceEngineSettingPrefix

    /// "af_heart" from "kokoro:af_heart", "Abigail.wav" from "chatterbox:Abigail.wav".
    static func voiceName(_ voice: String) -> String {
        guard let colon = voice.firstIndex(of: ":") else { return voice }
        return String(voice[voice.index(after: colon)...])
    }

    // MARK: - Where a book is made

    /// The import sheet's starting choice. Ask each time starts on the home server when it
    /// answers (what the sheet always did); Home server falls back to this Mac, visibly, when it
    /// does not.
    static func initialRenderer(_ choice: MakeBooksOn, homeServerAvailable: Bool) -> DocumentLibrary.Renderer {
        switch choice {
        case .ask, .homeServer: homeServerAvailable ? .homeServer : .thisMac
        case .thisMac: .thisMac
        }
    }

    /// The sheet's choice the moment it opens, before the Baton server has answered:
    /// the Baton server whenever one is set up and the setting allows it, so a book made in the
    /// first seconds goes there rather than to this Mac by default. `initialRenderer` then moves
    /// it to this Mac, visibly, if the Baton server cannot take the book.
    static func openingRenderer(_ choice: MakeBooksOn, homeServerConfigured: Bool) -> DocumentLibrary.Renderer {
        switch choice {
        case .ask, .homeServer: homeServerConfigured ? .homeServer : .thisMac
        case .thisMac: .thisMac
        }
    }

    /// What making the book on this Mac means for the iPhone, said under "Made on" when This Mac
    /// makes it. With a Baton server the book goes there as each chapter is done
    /// (`MacBookUploads`); without one it stays here.
    static func thisMacNote(homeServerConfigured: Bool) -> String {
        homeServerConfigured
            ? "This Mac makes it and sends each chapter to your Baton server, so your iPhone gets it too."
            : "Only on this Mac: your iPhone won't see this book."
    }

    /// Whether the import sheet offers the choice at all: only for Ask each time, and only when
    /// the home server can take the book.
    static func sheetAsks(_ choice: MakeBooksOn, homeServerAvailable: Bool) -> Bool {
        choice == .ask && homeServerAvailable
    }

    /// The line beside "Made on" when the sheet does not ask, or nil when it does.
    static func sheetNote(_ choice: MakeBooksOn, homeServerAvailable: Bool) -> String? {
        switch choice {
        case .ask: nil
        case .thisMac: "Set in Settings, Speech."
        case .homeServer: homeServerAvailable ? "Set in Settings, Speech." : homeServerFallbackNote
        }
    }

    /// Said when the home server was chosen and does not answer: the sheet's line, and the
    /// `import_document` tool's note.
    static let homeServerFallbackNote = "The Baton server is not answering, so this Mac makes it."

    // MARK: - Status lines

    /// The voice server line for one engine: its address and whether it answers.
    static func serverStatus(name: String, address: String, configured: Bool, status: ServiceStatus) -> String {
        guard configured else { return "\(name): no address set" }
        let shown = displayAddress(address)
        switch status {
        case .ok(_, let badge): return "\(name) at \(shown): answering" + (badge.map { ", \($0) voices" } ?? "")
        case .checking, .unknown: return "\(name) at \(shown): checking"
        case .notConfigured: return "\(name): no address set"
        case .unreachable, .refused, .offline: return "\(name) at \(shown): not answering"
        }
    }

    /// `host:port` from an address, or the address as typed when it does not parse.
    static func displayAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let host = url.host else { return trimmed }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Whether any voice server answers, from the two lines above.
    static func anyServerAnswers(_ statuses: [ServiceStatus]) -> Bool {
        statuses.contains { if case .ok = $0 { true } else { false } }
    }

    /// The line under Automatic: what it does right now.
    static func automaticStatus(builtInReady: Bool, serverAnswers: Bool) -> String {
        switch (builtInReady, serverAnswers) {
        case (true, true): "Now: built-in for the 28 English voices, the voice server for the rest"
        case (true, false): "Now: built-in for the 28 English voices; no voice server answers for the rest"
        case (false, true): "Now: the voice server for every voice (built-in voices not downloaded)"
        case (false, false): "Now: nothing can read a book yet. Download the built-in voices or set a voice server"
        }
    }
}
