import AVFoundation
import BatonDocuments
import BatonSubsonicKit
import Foundation
import Observation

/// "Previously…" on the iPhone: Play on a book last heard
/// more than a day ago offers a short spoken recap of what has been heard, then the book plays.
///
/// What the Mac and the phone must agree on is `Recap` in BatonDocuments: when it is offered,
/// where the listener is, the spoiler bound (only text before that position reaches the model),
/// the prompt, the one router call and the voice. This file holds only what is the phone's own:
/// where its words come from, which models it can reach, and how it speaks.
///
/// **The models.** The phone has three routes to a model. The music friend's own model
/// (Settings, Music friend, Model provider: the same settings "Summarize this episode" uses) is
/// called directly; the home server's model is reached through its book route
/// (`POST /v1/books/complete`), which answers only when that model is on the home
/// network; Apple's on-device model answers on an iPhone with Apple Intelligence. All go through
/// `ModelRouter`, as on the Mac: a model on the person's own network, the home server or the phone
/// is used as it is, and a cloud model only when the person allowed it chapters
/// (`ModelConsentLedger`), asked the first time it is the only one left (`askingConsent`). The
/// home server's `/v1/agent` is not used: it runs the music friend's tool loop with tools that act
/// on playback, so it cannot keep the spoiler rule.
enum MobileRecap {
    /// The book's words: the shaped book this phone sent to the home server, else the text it
    /// kept beside the record, else the chapters' own text in Clippings.
    @MainActor
    static func preparedBook(for book: MobileBookShelf.Book, homeServer: HomeServerBooks?) -> PreparedBook? {
        if let homeServer, let record = homeServer.record(forDocument: book.documentID) {
            if let shaped = homeServer.preparedBook(forJob: record.jobID) { return shaped }
            let kept = record.chapterTexts.enumerated().map { index, text in
                Recap.ChapterText(index: index, title: record.chapterTitles.indices.contains(index)
                                      ? record.chapterTitles[index] : "Chapter \(index + 1)", text: text)
            }
            if let made = Recap.book(documentID: book.documentID, title: book.title, author: book.author, chapters: kept) {
                return made
            }
        }
        return Recap.book(documentID: book.documentID, title: book.title, author: book.author,
                          chapters: book.chapters.map {
                              Recap.ChapterText(index: $0.index, title: $0.title, text: $0.item?.clipping.text ?? "",
                                                durationSeconds: $0.item?.clipping.durationSeconds)
                          })
    }

    /// The length of the synced chapter's audio, which turns its seconds into a share heard.
    static func chapterDuration(_ book: MobileBookShelf.Book) -> Double? {
        guard let position = book.position else { return nil }
        return book.chapters.first { $0.index == position.chapterIndex }?.item?.clipping.durationSeconds
    }

    static func shouldOffer(_ book: MobileBookShelf.Book, prepared: PreparedBook, lastPlayed: Date?,
                            now: Date = Date()) -> Bool {
        Recap.shouldOffer(book: prepared, synced: book.position, chapterDuration: chapterDuration(book),
                          finished: book.finished, lastPlayed: lastPlayed, now: now)
    }

    static func position(in prepared: PreparedBook, book: MobileBookShelf.Book) -> BookPosition {
        Recap.position(in: prepared, synced: book.position, chapterDuration: chapterDuration(book), finished: book.finished)
    }

    // MARK: - Models

    /// The models this phone can reach for a recap, in the order they are tried, nearest first:
    /// the music friend's model when it is on the person's network (it is the one the person
    /// chose, and usually larger), then the home server's book route, then Apple's on-device
    /// model when this iPhone has it, and last the music friend's model when it is a cloud one,
    /// which needs consent for chapters. The music friend's model counts as set up with a model
    /// and an address, plus a key unless it is on the person's network; the untouched defaults
    /// (Anthropic with no key) are left out. `homeServer` is the gateway's address when this
    /// phone has one and its token.
    static func sources(model: String, baseURL: String, provider: RemoteControlSettings.LLMProvider,
                        hasKey: Bool, homeServer: String? = nil, onDevice: ModelSource?) -> [ModelSource] {
        var direct: ModelSource?
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        let name = model.trimmingCharacters(in: .whitespaces)
        if !base.isEmpty, !name.isEmpty {
            var source = ModelSource(name: "", provider: provider == .anthropic ? .anthropic : .openAICompatible,
                                     baseURL: base, model: name, contextTokens: 8_192)
            source.name = source.isLocal ? "\(name) on your network" : ModelConsentWording.providerName(source)
            if source.isLocal || hasKey { direct = source }
        }
        var sources: [ModelSource] = []
        if let direct, direct.isLocal { sources.append(direct) }
        if let homeServer { sources.append(BookCompletion.source(gatewayURL: homeServer)) }
        if var onDevice {
            onDevice.name = "Apple Intelligence on this iPhone"
            sources.append(onDevice)
        }
        if let direct, !direct.isLocal { sources.append(direct) }
        return sources
    }

    /// The cloud models a book task could send chapters to, for Settings: today the music
    /// friend's model when it is a hosted one with a key.
    @MainActor
    static func cloudSources(_ config: AgentConfig) -> [ModelSource] {
        sources(model: config.model, baseURL: config.baseURL, provider: config.provider,
                hasKey: !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty, onDevice: nil)
            .filter { !$0.isLocal }
    }

    /// The live routing: the music friend's settings, Apple's model when it can answer, and
    /// what the person allowed cloud models (none unless they said so).
    @MainActor
    static func liveRouting(_ config: AgentConfig) -> (sources: [ModelSource], consent: ModelConsent, executor: ModelRouter.Executor) {
        let key = config.apiKey
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
        var onDevice = AppleOnDeviceModel.sourceIfAvailable()
        #if DEBUG
        // UI tests answer from FakeHomeServer, whatever the Mac running the simulator has.
        if ProcessInfo.processInfo.environment["uitestNoOnDeviceModel"] == "1" { onDevice = nil }
        #endif
        let gateway = config.gatewayURL.trimmingCharacters(in: .whitespaces)
        let token = config.gatewayToken.trimmingCharacters(in: .whitespaces)
        // The executor below hands the gateway token to this source, so it takes the same guard
        // as every other gateway client on the phone: never plain HTTP to a public address
        //
        let homeServer = MobileModel.bearerGateway(address: gateway, token: token) != nil ? gateway : nil
        let sources = sources(model: config.model, baseURL: base, provider: config.provider,
                              hasKey: !key.trimmingCharacters(in: .whitespaces).isEmpty, homeServer: homeServer,
                              onDevice: onDevice)
        let executor = AppleOnDeviceModel.executor(otherwise: HTTPModelClient.executor(apiKey: { source in
            if source.provider == .homeServer { return homeServer != nil ? token : nil }
            return source.baseURL == base && !key.isEmpty ? key : nil
        }))
        return (sources, ModelConsentLedger(defaults: BatonStorage.defaults).consent, executor)
    }

    /// Why no recap was written, in one line.
    static func noRecapLine(sources: [ModelSource], consent: ModelConsent) -> String {
        if sources.isEmpty {
            return "No model is set up for recaps on this iPhone, so the book plays as it is."
        }
        if let cloud = ModelRouter(sources: sources, consent: consent).awaitingConsent(for: .recap).first {
            return "No model on this iPhone or your network wrote a recap, and sending chapters to \(cloud.name) is not allowed, so the book plays as it is."
        }
        return "No model on this iPhone or your network wrote a recap, so the book plays as it is."
    }
}

/// The offer as Clippings shows it: made when Play is pressed on a book due a recap, written and
/// spoken on "Hear Recap", dropped on "Just Play". The same states as the Mac's banner.
@MainActor
@Observable
final class MobileRecapOffer {
    enum State: Equatable {
        case offered
        case writing
        /// Nothing nearer wrote a recap and this cloud source could, but the person has never
        /// answered whether it may have chapters (M4.6): the Mac's question, once.
        case askingConsent(ModelSource)
        case speaking
        case failed(String)
    }

    /// The answers the Mac's first-use question offers.
    enum ConsentAnswer { case once, always, notNow }

    struct Offer {
        let book: MobileBookShelf.Book
        let prepared: PreparedBook
        let position: BookPosition
    }

    private(set) var offer: Offer?
    private(set) var state: State = .offered
    /// The recap as spoken, shown while it plays, and the model that wrote it.
    private(set) var text: String?
    private(set) var writtenBy: String?

    /// Offer a recap for `book` if one is due. Returns whether it was offered, so the caller
    /// plays at once when it was not.
    @discardableResult
    func consider(_ book: MobileBookShelf.Book, prepared: PreparedBook?, lastPlayed: Date?, now: Date = Date()) -> Bool {
        guard let prepared, MobileRecap.shouldOffer(book, prepared: prepared, lastPlayed: lastPlayed, now: now) else {
            offer = nil
            return false
        }
        offer = Offer(book: book, prepared: prepared, position: MobileRecap.position(in: prepared, book: book))
        state = .offered
        text = nil
        writtenBy = nil
        return true
    }

    func dismiss() {
        offer = nil
        state = .offered
        text = nil
        writtenBy = nil
    }

    /// Write the recap and hand it to `speak`, which returns once it has been said (or could not
    /// be). Then `thenPlay` runs, recap or not: a silent model costs a line, never the book.
    /// When nothing nearer answered and a cloud source is left that the person has never been
    /// asked about (`isAnswered`), the offer asks first (`askingConsent`) and the book waits for
    /// `answerConsent`.
    func hear(sources: [ModelSource], consent: ModelConsent, isAnswered: (ModelSource) -> Bool = { _ in true },
              executor: @escaping ModelRouter.Executor,
              speak: @escaping (String) async -> Bool, thenPlay: @escaping () -> Void) async {
        guard let offer else { return }
        state = .writing
        guard let recap = await Recap.write(book: offer.prepared, position: offer.position, sources: sources,
                                            consent: consent, executor: executor) else {
            if let cloud = ModelRouter(sources: sources, consent: consent).awaitingConsent(for: .recap)
                .first(where: { !isAnswered($0) }) {
                state = .askingConsent(cloud)
                return
            }
            state = .failed(MobileRecap.noRecapLine(sources: sources, consent: consent))
            thenPlay()
            return
        }
        text = recap.text
        writtenBy = recap.source
        state = .speaking
        let spoken = await speak(recap.text)
        if !spoken { state = .failed("The recap could not be spoken, so the book plays as it is.") }
        thenPlay()
        if spoken { dismiss() }
    }

    /// The person's answer to the question, kept the way the Mac keeps it: "Always" and "Not
    /// now" in the ledger for that provider and chapters, "Allow once" for this recap only. Not
    /// now plays the book as it is; the others write the recap with that source alone.
    func answerConsent(_ answer: ConsentAnswer, ledger: ModelConsentLedger, executor: @escaping ModelRouter.Executor,
                       speak: @escaping (String) async -> Bool, thenPlay: @escaping () -> Void) async {
        guard case let .askingConsent(source) = state else { return }
        let content = ModelTask.recap.content
        switch answer {
        case .notNow:
            ledger.decline(source, content)
            dismiss()
            thenPlay()
        case .always, .once:
            if answer == .always { ledger.grant(source, content) }
            await hear(sources: [source], consent: ledger.consent.granting(source, content), executor: executor,
                       speak: speak, thenPlay: thenPlay)
        }
    }
}

/// Says a recap the way this phone says spoken things: the home server's voices
/// (`POST /v1/speech/preview`, the route the import screen's voice preview uses), in a voice
/// other than the book's narrator (`Recap.voice(otherThan:)`); else the iPhone's own voice, which
/// is never a home-server narrator.
@MainActor
final class MobileRecapSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    /// The home server's preview takes at most this many characters (`BookRoutes`).
    static let previewLimit = 600

    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Returns once the recap has been said; false when nothing could say it.
    func speak(_ text: String, narrator: String, client: GatewayBookClient?) async -> Bool {
        if let client {
            let voice = Recap.voice(otherThan: narrator)
            if let wav = try? await client.preview(text: Recap.fitting(text, characters: Self.previewLimit), voice: voice),
               let player = try? AVAudioPlayer(data: wav) {
                self.player = player
                player.play()
                try? await Task.sleep(for: .seconds(player.duration))
                self.player = nil
                return true
            }
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.prefersAssistiveTechnologySettings = false
        await withCheckedContinuation { continuation in
            finished = continuation
            synthesizer.speak(utterance)
        }
        return true
    }

    func stop() {
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    private func resume() {
        finished?.resume()
        finished = nil
    }
}
