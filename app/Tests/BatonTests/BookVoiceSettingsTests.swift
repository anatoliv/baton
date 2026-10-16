import AppKit
import BatonDocuments
import BatonKokoroMLX
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import SwiftUI
import Testing
@testable import Baton

/// Settings → Speech → Voice engine for books: the setting, the routing rule it
/// drives, where a book is made, and the section that explains it.
@MainActor
@Suite("Voice engine for books", .serialized)
struct BookVoiceSettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = ThrowawayDefaults.name("book-voice")
        let defaults = UserDefaults(suiteName: suite)!
        let saved = BookVoiceSettings.defaults
        BookVoiceSettings.defaults = defaults
        defer {
            BookVoiceSettings.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        try body(defaults)
    }

    // MARK: The setting

    @Test("Automatic and Ask each time are the defaults, and an unknown stored value reads as them")
    func defaultsAndAccessors() {
        withDefaults { defaults in
            #expect(BookVoiceSettings.engine == .automatic)
            #expect(BookVoiceSettings.makeBooksOn == .ask)
            BookVoiceSettings.engine = .server
            BookVoiceSettings.makeBooksOn = .homeServer
            #expect(defaults.string(forKey: "baton.documents.voiceEngine") == "server")
            #expect(defaults.string(forKey: "baton.documents.makeBooksOn") == "homeServer")
            #expect(BookVoiceSettings.engine == .server)
            #expect(BookVoiceSettings.makeBooksOn == .homeServer)
            defaults.set("cloud", forKey: BookVoiceSettings.engineKey)
            #expect(BookVoiceSettings.engine == .automatic)
        }
    }

    @Test("Reset to Defaults puts both back, and neither key is synced to other devices")
    func resetAndDeviceLocal() {
        withDefaults { defaults in
            BookVoiceSettings.engine = .builtIn
            BookVoiceSettings.makeBooksOn = .thisMac
            BookVoiceSettings.reset()
            #expect(defaults.object(forKey: BookVoiceSettings.engineKey) == nil)
            #expect(defaults.object(forKey: BookVoiceSettings.makeBooksOnKey) == nil)
            #expect(BookVoiceSettings.engine == .automatic)
            #expect(BookVoiceSettings.makeBooksOn == .ask)
        }
        #expect(!PreferenceSync.syncedKeys.contains(BookVoiceSettings.engineKey))
        #expect(!PreferenceSync.syncedKeys.contains(BookVoiceSettings.makeBooksOnKey))
    }

    // MARK: The routing rule

    @Test("Automatic: built-in for its English voices when downloaded, the server for everything else")
    func automaticRouting() {
        let stub = StubBuiltInEngine()
        #expect(BookVoiceSettings.route(voice: "kokoro:af_heart", engine: .automatic, builtIn: stub) == .builtIn)
        #expect(BookVoiceSettings.route(voice: "kokoro:jf_alpha", engine: .automatic, builtIn: stub) == .server("kokoro"))
        #expect(BookVoiceSettings.route(voice: "chatterbox:Abigail.wav", engine: .automatic, builtIn: stub) == .server("chatterbox"))
        // Not downloaded: every voice goes to the server, as before the setting existed.
        #expect(BookVoiceSettings.route(voice: "kokoro:af_heart", engine: .automatic, builtIn: nil) == .server("kokoro"))
        #expect(BookVoiceSettings.route(voice: "af_heart", engine: .automatic, builtIn: nil) == .server("kokoro"))
    }

    @Test("Voice server: the server even when the built-in voices are downloaded and have the voice")
    func serverRouting() {
        let stub = StubBuiltInEngine()
        #expect(BookVoiceSettings.route(voice: "kokoro:af_heart", engine: .server, builtIn: stub) == .server("kokoro"))
        #expect(BookVoiceSettings.route(voice: "kokoro:af_heart", engine: .server, builtIn: nil) == .server("kokoro"))
        #expect(BookVoiceSettings.route(voice: "chatterbox:Abigail.wav", engine: .server, builtIn: stub) == .server("chatterbox"))
    }

    @Test("Built-in: its own voices, and a plain refusal for a server-only voice or when not downloaded")
    func builtInRouting() throws {
        let stub = StubBuiltInEngine()
        #expect(BookVoiceSettings.route(voice: "kokoro:bm_george", engine: .builtIn, builtIn: stub) == .builtIn)

        guard case let .refused(chatterbox) = BookVoiceSettings.route(voice: "chatterbox:Abigail.wav", engine: .builtIn, builtIn: stub) else {
            Issue.record("a Chatterbox voice must be refused under Built-in"); return
        }
        #expect(chatterbox.hasPrefix(SynthesisError.voiceEngineSettingPrefix))
        #expect(chatterbox.contains("Abigail.wav is not one of them"))
        guard case let .refused(japanese) = BookVoiceSettings.route(voice: "kokoro:jf_alpha", engine: .builtIn, builtIn: stub) else {
            Issue.record("a non-English Kokoro voice must be refused under Built-in"); return
        }
        #expect(japanese.contains("English Kokoro voices only"))

        guard case let .refused(missing) = BookVoiceSettings.route(voice: "kokoro:af_heart", engine: .builtIn, builtIn: nil) else {
            Issue.record("Built-in without the download must refuse, not fall back"); return
        }
        #expect(missing == BookVoiceSettings.notReadyReason)
        for text in [chatterbox, japanese, missing] {
            #expect(!text.contains("—") && !text.contains("–"))
        }
    }

    @Test("The synthesizer follows the setting: Voice server never asks the downloaded built-in engine")
    func synthesizerVoiceServer() async {
        let stub = StubBuiltInEngine()
        let synthesizer = ConfiguredSpeechSynthesizer(localEngine: { stub }, engineSetting: { .server })
        _ = try? await synthesizer.synthesize(text: "Hello.", voice: "kokoro:af_heart", speed: nil)
        #expect(stub.voices.isEmpty)
    }

    @Test("The synthesizer follows the setting: Automatic and Built-in render a built-in voice in process")
    func synthesizerBuiltIn() async throws {
        for setting in [BookVoiceSettings.Engine.automatic, .builtIn] {
            let stub = StubBuiltInEngine()
            let synthesizer = ConfiguredSpeechSynthesizer(localEngine: { stub }, engineSetting: { setting })
            let data = try await synthesizer.synthesize(text: "Hello.", voice: "kokoro:af_heart", speed: nil)
            #expect(data == stub.wav)
            #expect(stub.voices == ["kokoro:af_heart"])
        }
    }

    @Test("Built-in refuses a server-only voice as a pause with the plain reason, never reaching a server")
    func synthesizerRefusal() async {
        let stub = StubBuiltInEngine()
        let refusing = ConfiguredSpeechSynthesizer(localEngine: { stub }, engineSetting: { .builtIn })
        do {
            _ = try await refusing.synthesize(text: "Hello.", voice: "chatterbox:Abigail.wav", speed: nil)
            Issue.record("a Chatterbox voice must not synthesize under Built-in")
        } catch let error as SynthesisError {
            guard case .transient = error else { Issue.record("expected a pause, got \(error)"); return }
            // The book's row shows the reason as written, not "the voice server refused this book".
            #expect(error.listenerReason == error.description)
            #expect(error.listenerReason.contains("Abigail.wav is not one of them"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(stub.voices.isEmpty)

        let notDownloaded = ConfiguredSpeechSynthesizer(localEngine: { nil }, engineSetting: { .builtIn })
        do {
            _ = try await notDownloaded.synthesize(text: "Hello.", voice: "kokoro:af_heart", speed: nil)
            Issue.record("Built-in without the download must not fall back to a server")
        } catch let error as SynthesisError {
            #expect(error.listenerReason == BookVoiceSettings.notReadyReason)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("A server failure's listener reason is unchanged by the passthrough")
    func otherReasonsUnchanged() {
        #expect(SynthesisError.transient("kokoro did not answer: timed out").listenerReason == "the voice server isn't answering")
        #expect(SynthesisError.permanent("kokoro refused the request (400): bad voice").listenerReason == "the voice server refused this book")
    }

    // MARK: The import sheet's voice list

    @Test("The import sheet offers the voices the setting allows")
    func importVoicesFollowSetting() async {
        let builtIn = ["kokoro:af_heart", "kokoro:bm_george"]
        let up: DocumentImporter.Fetch = { request in
            (Data(#"{"voices":["af_heart","jf_alpha"]}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let down: DocumentImporter.Fetch = { _ in throw URLError(.cannotConnectToHost) }
        let base = "http://127.0.0.1:8880"
        #expect(await VoiceSuggestions.availableVoices(kokoroBase: base, builtIn: builtIn, engine: .builtIn, fetch: up) == builtIn)
        #expect(await VoiceSuggestions.availableVoices(kokoroBase: base, builtIn: builtIn, engine: .server, fetch: up)
                == ["kokoro:af_heart", "kokoro:jf_alpha"])
        #expect(await VoiceSuggestions.availableVoices(kokoroBase: base, builtIn: builtIn, engine: .server, fetch: down).isEmpty)
        #expect(await VoiceSuggestions.availableVoices(kokoroBase: base, builtIn: builtIn, engine: .automatic, fetch: down) == builtIn)
    }

    // MARK: Where a book is made

    @Test("Make books on: Ask each time keeps the sheet's choice, the others decide without asking")
    func makeBooksOn() {
        #expect(BookVoiceSettings.initialRenderer(.ask, homeServerAvailable: true) == .homeServer)
        #expect(BookVoiceSettings.initialRenderer(.ask, homeServerAvailable: false) == .thisMac)
        #expect(BookVoiceSettings.initialRenderer(.thisMac, homeServerAvailable: true) == .thisMac)
        #expect(BookVoiceSettings.initialRenderer(.homeServer, homeServerAvailable: true) == .homeServer)
        #expect(BookVoiceSettings.initialRenderer(.homeServer, homeServerAvailable: false) == .thisMac)

        #expect(BookVoiceSettings.sheetAsks(.ask, homeServerAvailable: true))
        #expect(!BookVoiceSettings.sheetAsks(.ask, homeServerAvailable: false))
        #expect(!BookVoiceSettings.sheetAsks(.thisMac, homeServerAvailable: true))
        #expect(!BookVoiceSettings.sheetAsks(.homeServer, homeServerAvailable: true))
        #expect(BookVoiceSettings.sheetNote(.homeServer, homeServerAvailable: false) == "The Baton server is not answering, so this Mac makes it.")
        #expect(BookVoiceSettings.sheetNote(.ask, homeServerAvailable: true) == nil)
    }

    @Test("TBX-11017: with a Baton server set up the sheet opens on it, and This Mac says where the book goes")
    func openingChoiceAndThisMacNote() {
        // Before the Baton server has answered: set up is enough, so a quick Make goes there.
        #expect(BookVoiceSettings.openingRenderer(.ask, homeServerConfigured: true) == .homeServer)
        #expect(BookVoiceSettings.openingRenderer(.homeServer, homeServerConfigured: true) == .homeServer)
        #expect(BookVoiceSettings.openingRenderer(.thisMac, homeServerConfigured: true) == .thisMac)
        #expect(BookVoiceSettings.openingRenderer(.ask, homeServerConfigured: false) == .thisMac)
        #expect(BookVoiceSettings.thisMacNote(homeServerConfigured: false) == "Only on this Mac: your iPhone won't see this book.")
        #expect(BookVoiceSettings.thisMacNote(homeServerConfigured: true)
                == "This Mac makes it and sends each chapter to your Baton server, so your iPhone gets it too.")
        for note in [true, false].map(BookVoiceSettings.thisMacNote) {
            #expect(!note.contains("—") && !note.contains("–") && !note.contains("home server"), "house wording: \(note)")
        }
    }

    // MARK: Status lines and the section

    @Test("Each server line names its address and whether it answers")
    func serverLines() {
        #expect(BookVoiceSettings.serverStatus(name: "Kokoro", address: "http://tts.lan:8880", configured: true,
                                               status: .ok(detail: "54 voices", badge: "54")) == "Kokoro at tts.lan:8880: answering, 54 voices")
        #expect(BookVoiceSettings.serverStatus(name: "Kokoro", address: "http://tts.lan:8880", configured: true,
                                               status: .unreachable("timed out")) == "Kokoro at tts.lan:8880: not answering")
        #expect(BookVoiceSettings.serverStatus(name: "Chatterbox", address: "http://tts.lan:8004", configured: true,
                                               status: .checking) == "Chatterbox at tts.lan:8004: checking")
        #expect(BookVoiceSettings.serverStatus(name: "Chatterbox", address: "http://127.0.0.1:8004", configured: false,
                                               status: .notConfigured("Not set up")) == "Chatterbox: no address set")
        #expect(BookVoiceSettings.automaticStatus(builtInReady: true, serverAnswers: false)
                == "Now: built-in for the 28 English voices; no voice server answers for the rest")
        #expect(BookVoiceSettings.automaticStatus(builtInReady: false, serverAnswers: true)
                == "Now: the voice server for every voice (built-in voices not downloaded)")
    }

    @Test("The built-in line says downloaded, not downloaded, downloading or not available")
    func builtInLines() {
        let voices = BuiltInVoices(store: KokoroModelStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-bvs-\(UUID().uuidString)")))
        #expect(BuiltInVoicesModel(voices: voices, pinned: .ready).statusLine == "Downloaded, 28 English voices")
        #expect(BuiltInVoicesModel(voices: voices, pinned: .notDownloaded).statusLine == "Not downloaded")
        #expect(BuiltInVoicesModel(voices: voices, pinned: .downloading(done: 1_000_000, total: 342_000_000)).statusLine.hasPrefix("Downloading"))
        #expect(BuiltInVoicesModel(voices: voices, pinned: .unavailableInBuild).statusLine.hasPrefix("Not available"))
        for text in [BookVoiceEngineSection.automaticNeeds, BookVoiceEngineSection.builtInNeeds,
                     BookVoiceEngineSection.serverNeeds, BookVoiceEngineSection.homeServerNote] {
            #expect(!text.contains("—") && !text.contains("–"))
        }
        #expect(BookVoiceEngineSection.builtInNeeds.contains("342 MB"))
        #expect(BookVoiceEngineSection.homeServerNote.contains("BATON_TTS_KOKORO_URL"))
    }

    @Test("The Speech pane section lays out with every built-in state and server status")
    func sectionRenders() {
        withDefaults { _ in
            let voices = BuiltInVoices(store: KokoroModelStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("baton-bvs-\(UUID().uuidString)")))
            let states: [BuiltInVoicesModel.State] = [.ready, .notDownloaded, .downloading(done: 5_000_000, total: 342_000_000), .unavailableInBuild]
            let servers: [(ServiceStatus, ServiceStatus)] = [
                (.ok(detail: nil, badge: "54"), .ok(detail: nil, badge: "12")),
                (.unreachable("timed out"), .notConfigured("Not set up")),
                (.checking, .unknown),
            ]
            for engine in BookVoiceSettings.Engine.allCases {
                BookVoiceSettings.engine = engine
                for state in states {
                    for (kokoro, chatterbox) in servers {
                        let section = BookVoiceEngineSection(kokoro: kokoro, chatterbox: chatterbox,
                                                             model: BuiltInVoicesModel(voices: voices, pinned: state))
                        let host = NSHostingView(rootView: Form { section }.formStyle(.grouped).frame(width: 640))
                        host.layoutSubtreeIfNeeded()
                        #expect(host.fittingSize.height > 200, "\(engine) \(state) laid out at \(host.fittingSize)")
                    }
                }
            }
        }
    }
}
