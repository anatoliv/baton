import BatonDocuments
import BatonKokoroMLX
import BatonSubsonicKit
import Observation
import SwiftUI

/// Settings → Speech → **Voice engine for books** (TBX-10909, built on TBX-10854's download):
/// which engine reads a book made on this Mac, each choice with what it needs and a live status
/// line, the built-in voices' download, and where a new book is made.
///
/// The server lines come from the pane's own probe of the Services hosts, so this section and
/// the badges above it never disagree. Behind `baton.documents.enabled`, like the rest of
/// document clippings.
struct BookVoiceEngineSection: View {
    /// The Services probe's answer for each host.
    var kokoro: ServiceStatus
    var chatterbox: ServiceStatus
    @State private var model: BuiltInVoicesModel
    @AppStorage(BookVoiceSettings.engineKey, store: BookVoiceSettings.defaults)
    private var engine: BookVoiceSettings.Engine = .automatic
    @AppStorage(BookVoiceSettings.makeBooksOnKey, store: BookVoiceSettings.defaults)
    private var makeBooksOn: BookVoiceSettings.MakeBooksOn = .ask

    init(kokoro: ServiceStatus, chatterbox: ServiceStatus, model: BuiltInVoicesModel = BuiltInVoicesModel()) {
        self.kokoro = kokoro
        self.chatterbox = chatterbox
        _model = State(initialValue: model)
    }

    static let automaticNeeds = "Whenever the built-in voices are downloaded, uses them first for every voice they have (their 28 English voices), and the voice server for every other voice. The default."
    static let builtInNeeds = "Kokoro, run by Baton itself. English only, 28 voices. Needs the one-time \(BuiltInVoicesModel.sizeText) download and a Mac with Apple silicon. Works offline, and nothing leaves this Mac. Recommended on Apple silicon: in a side-by-side listening test they sounded the same as the server."
    static let serverNeeds = "A Kokoro or Chatterbox server at the addresses under Services above, for example on your home network. More languages, and Chatterbox's voices and voice cloning. Needs the address to answer, and the book's text is sent to it."
    static let homeServerNote = "The Baton server makes books with its own voice server, the Kokoro, Chatterbox and expressive server addresses set in the Baton server's own setup (BATON_TTS_KOKORO_URL, BATON_TTS_CHATTERBOX_URL and BATON_TTS_OPENAI_URL), not with the choice above."

    var body: some View {
        Section {
            option(.automatic, needs: Self.automaticNeeds,
                   status: BookVoiceSettings.automaticStatus(builtInReady: model.state == .ready, serverAnswers: serverAnswers),
                   good: model.state == .ready || serverAnswers)
            option(.builtIn, needs: Self.builtInNeeds, status: model.statusLine, good: model.state == .ready)
            builtInControls
            option(.server, needs: Self.serverNeeds, status: serverLine(.kokoro), good: answers(kokoro))
            serverDetail
            ExpressiveServerFields()
            Picker("Make books on", selection: $makeBooksOn) {
                ForEach(BookVoiceSettings.MakeBooksOn.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("make-books-on")
            note(Self.homeServerNote)
        } header: {
            Text("Voice engine for books")
        } footer: {
            note("Applies to books made on this Mac and to the voice previews in the import sheet. Spoken summaries and Read aloud use the Services above and are not affected.")
        }
        .onAppear { model.refresh() }
    }

    private var serverAnswers: Bool { BookVoiceSettings.anyServerAnswers([kokoro, chatterbox]) }

    private func answers(_ status: ServiceStatus) -> Bool {
        if case .ok = status { true } else { false }
    }

    private func serverLine(_ engine: SpeechConfig.Engine) -> String {
        BookVoiceSettings.serverStatus(
            name: engine == .kokoro ? "Kokoro" : "Chatterbox",
            address: SpeechConfig.baseURL(for: engine),
            configured: SpeechConfig.hasStoredHost(for: engine),
            status: engine == .kokoro ? kokoro : chatterbox)
    }

    /// One choice: a radio mark, its name, what it needs, and how it stands right now. The whole
    /// row selects; the mark is the button Accessibility (and the probe) presses, so the lines
    /// beside it stay readable text rather than one long button title.
    private func option(_ choice: BookVoiceSettings.Engine, needs: String, status: String, good: Bool) -> some View {
        let selected = engine == choice
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                engine = choice
            } label: {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(choice.title)
            .accessibilityIdentifier("voice-engine-\(choice.rawValue)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.title).fontWeight(selected ? .semibold : .regular)
                Text(needs).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(status, systemImage: good ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(good ? Color.green : Color.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { engine = choice }
    }

    /// The built-in voices' download, under their option.
    @ViewBuilder
    private var builtInControls: some View {
        if model.state != .unavailableInBuild {
            HStack {
                Spacer()
                switch model.state {
                case .unavailableInBuild:
                    EmptyView()
                case .notDownloaded:
                    Button("Download (\(BuiltInVoicesModel.sizeText))") { model.download() }
                case .downloading:
                    Button("Cancel") { model.cancel() }
                case .ready:
                    Button("Remove", role: .destructive) { model.remove() }
                }
            }
            if case let .downloading(done, total) = model.state {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
            }
        }
        if let problem = model.problem {
            note(problem, tint: .orange)
        }
        if engine == .builtIn, model.state != .ready {
            note(BookVoiceSettings.notReadyReason + ".", tint: .orange)
        }
    }

    /// Chatterbox's line under Kokoro's, and what Voice server means when nothing answers.
    @ViewBuilder
    private var serverDetail: some View {
        let chatterboxLine = serverLine(.chatterbox)
        Label(chatterboxLine, systemImage: answers(chatterbox) ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption)
            .foregroundStyle(answers(chatterbox) ? Color.green : Color.secondary)
            .padding(.leading, 24)
        if engine == .server, !serverAnswers {
            note("No voice server answers, so books made on this Mac pause until one does, even with the built-in voices downloaded.", tint: .orange)
        }
    }

    private func note(_ text: String, tint: Color = .secondary) -> some View {
        Text(text).font(.callout).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
@Observable
final class BuiltInVoicesModel {
    enum State: Equatable {
        /// This build of Baton has no MLX shaders, so the engine cannot run.
        case unavailableInBuild
        case notDownloaded
        case downloading(done: Int64, total: Int64)
        case ready
    }

    /// "342 MB": whole megabytes, as the spec and the button name it (the formatter says 341.7).
    static let sizeText = "\(Int((Double(KokoroModelFiles.totalBytes) / 1_000_000).rounded())) MB"

    private(set) var state: State = .notDownloaded
    private(set) var problem: String?
    private var task: Task<Void, Never>?
    private let voices: BuiltInVoices
    /// A state that `refresh` keeps, for the section's render tests.
    private let pinned: State?

    init(voices: BuiltInVoices = .shared, pinned: State? = nil) {
        self.voices = voices
        self.pinned = pinned
        if let pinned { state = pinned }
    }

    var statusLine: String {
        switch state {
        case .unavailableInBuild:
            return BuiltInVoices.appleSilicon ? "Not available in this build of Baton" : "Not available on this Mac: needs Apple silicon"
        case .notDownloaded: return "Not downloaded"
        case let .downloading(done, total):
            return "Downloading \(LocalModelFormat.bytes(done)) of \(LocalModelFormat.bytes(total))"
        case .ready: return "Downloaded, 28 English voices"
        }
    }

    func refresh() {
        if let pinned { state = pinned; return }
        guard task == nil else { return }
        if !BuiltInVoices.shadersPresent { state = .unavailableInBuild }
        else { state = voices.store.isInstalled ? .ready : .notDownloaded }
    }

    func download() {
        guard task == nil else { return }
        problem = nil
        let needed = KokoroModelFiles.totalBytes - voices.store.bytesOnDisk
        if let free = LocalModelsModel.freeSpace(), free < needed {
            problem = "This Mac has \(LocalModelFormat.bytes(free)) free and the voices need \(LocalModelFormat.bytes(needed)). Make some room and try again."
            return
        }
        state = .downloading(done: voices.store.bytesOnDisk, total: KokoroModelFiles.totalBytes)
        let store = voices.store
        let throttle = ProgressThrottle()
        // The model is main-actor isolated, so the download holds it until it ends.
        task = Task {
            do {
                try await store.install { done, total in
                    guard throttle.shouldReport(done, total) else { return }
                    Task { @MainActor in self.progress(done, total) }
                }
                finish(problem: nil)
            } catch is CancellationError {
                finish(problem: nil)
            } catch let error as URLError where error.code == .cancelled {
                finish(problem: nil)
            } catch {
                let why = (error as? KokoroModelError)?.description ?? error.localizedDescription
                finish(problem: "The download stopped: \(why). Press Download to try again.")
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func remove() {
        voices.unload()
        do {
            try voices.store.remove()
            problem = nil
        } catch {
            problem = "Baton could not remove the voices: \(error.localizedDescription)"
        }
        refresh()
    }

    private func progress(_ done: Int64, _ total: Int64) {
        guard case .downloading = state else { return }
        state = .downloading(done: done, total: total)
    }

    private func finish(problem: String?) {
        task = nil
        self.problem = problem
        refresh()
    }
}

/// The transport reports every few kilobytes; the row needs about one update per megabyte.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = -1

    func shouldReport(_ done: Int64, _ total: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard done == total || last < 0 || abs(done - last) >= 1_000_000 else { return false }
        last = done
        return true
    }
}

/// The expressive voice server: an OpenAI-compatible speech server such as
/// Qwen3-TTS, by address, model and an optional key. Its voices join the pickers as their own
/// group, read a sentence at a time with each character's delivery instruction. The key goes to
/// the Keychain when saved, never to defaults, and is never shown again.
struct ExpressiveServerFields: View {
    @AppStorage(BookVoiceSettings.expressiveURLKey, store: BookVoiceSettings.defaults) private var address = ""
    @AppStorage(BookVoiceSettings.expressiveModelKey, store: BookVoiceSettings.defaults) private var model = ""
    @State private var key = ""
    @State private var hasKey = NavidromeKeychain.availability(account: BookVoiceSettings.expressiveKeyAccount) == .present

    static let explanation = "An OpenAI-compatible speech server, such as Qwen3-TTS, for more expressive narration. Its voices are listed as Expressive voices, read a sentence at a time, and each character is told how to sound. The book's text is sent to it."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Expressive voice server").fontWeight(.medium)
            Text(Self.explanation).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Address", text: $address, prompt: Text("http://host:port"))
                .accessibilityIdentifier("expressive-server-address")
            TextField("Model", text: $model, prompt: Text(SpeechEngines.defaultOpenAIModel))
                .accessibilityIdentifier("expressive-server-model")
            HStack {
                SecureField("Key", text: $key, prompt: Text(hasKey ? "Saved in the Keychain" : "Only if the server asks for one"))
                    .accessibilityIdentifier("expressive-server-key")
                Button("Save Key") {
                    _ = NavidromeKeychain.setSecret(key.trimmingCharacters(in: .whitespacesAndNewlines), account: BookVoiceSettings.expressiveKeyAccount)
                    key = ""
                    hasKey = true
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasKey {
                    Button("Remove Key", role: .destructive) {
                        NavidromeKeychain.deleteSecret(account: BookVoiceSettings.expressiveKeyAccount)
                        hasKey = false
                    }
                }
            }
            Text(statusLine).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 24)
    }

    private var statusLine: String {
        guard BookVoiceSettings.expressiveEndpoint(key: nil) != nil else {
            return address.isEmpty ? "Expressive voices: no address set" : "Expressive voices: the address is not a web address"
        }
        let shownModel = model.isEmpty ? SpeechEngines.defaultOpenAIModel : model
        return "Expressive voices at \(BookVoiceSettings.displayAddress(address)), model \(shownModel)"
    }
}
