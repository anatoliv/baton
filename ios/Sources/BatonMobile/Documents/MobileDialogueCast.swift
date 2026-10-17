import AVFoundation
import BatonDocuments
import OSLog
import SwiftUI

private let castLog = Logger(subsystem: "io.tonebox.baton", category: "DialogueCast")

/// Voice the dialogue on the iPhone: the Mac's flow (`DialogueCastFlow`) in a
/// phone's idiom. The phone's models write the cast list and place the lines the rules leave:
/// the music friend's model on the person's network, the Baton server's book model, Apple's
/// on-device model, then a cloud model only with consent (`MobileRecap.sources`). The book is
/// made on the Baton server, and the cast travels inside it: each line's speaker and
/// `VoicePlan.characters`, which the server reads each line by.
///
/// With no model, the screen says so plainly and one narrator reads every line.
enum MobileCast {
    /// The switch as the person last left it on this iPhone, off for the first book. A device
    /// preference: whether a phone voices dialogue depends on the models it can reach.
    static let rememberedKey = "baton.documents.voiceTheDialogue"

    static func remembered(in defaults: UserDefaults = BatonStorage.defaults) -> DialogueCastFlow.Choice {
        DialogueCastFlow.Choice(isOn: defaults.object(forKey: rememberedKey) as? Bool ?? false)
    }

    static func remember(_ isOn: Bool, in defaults: UserDefaults = BatonStorage.defaults) {
        defaults.set(isOn, forKey: rememberedKey)
    }

    @MainActor
    static func routing(_ model: MobileModel) -> (router: ModelRouter, executor: ModelRouter.Executor) {
        let live = MobileRecap.liveRouting(model.agentConfig)
        return (ModelRouter(sources: live.sources, consent: live.consent), live.executor)
    }

    /// Why no cast list, in one line.
    static func noCastLine(router: ModelRouter) -> String {
        guard let cloud = router.awaitingConsent(for: DialogueCastFlow.castTask).first else {
            return DialogueCastFlow.noCastLine(device: "this iPhone")
        }
        return "No model on this iPhone or the Baton server can write a cast list, and sending excerpts to "
            + "\(cloud.name) is not allowed, so the narrator reads every line."
    }

    /// Why no model places the remaining lines, in one line.
    static func noFillLine(router: ModelRouter) -> String {
        guard let cloud = router.awaitingConsent(for: DialogueCastFlow.fillTask).first else {
            return DialogueCastFlow.noFillLine(device: "this iPhone")
        }
        return "No model on this iPhone or the Baton server can place the lines without a speech tag, and sending chapters to "
            + "\(cloud.name) is not allowed, so the narrator reads those."
    }

    /// The book's first words, to hear a voice in when a speaker has no line of their own.
    static func opening(_ document: ImportedDocument) -> String {
        let first = document.chapters.lazy.flatMap(\.paragraphs).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return first.map { String($0.prefix(160)) } ?? document.title
    }

    /// The voices a speaker can be given: the ones the Baton server offers, which makes the book.
    @MainActor
    static func offeredVoices(_ model: MobileModel) -> @Sendable () async -> [String] {
        let books = model.books
        return { await books.voiceListing().voices ?? [] }
    }

    @MainActor
    static func propose(for document: ImportedDocument, narrator: String, model: MobileModel) async
        -> (phase: DialogueCastFlow.Choice.Phase, voices: [String]) {
        let (router, executor) = routing(model)
        return await DialogueCastFlow.propose(for: document, narrator: narrator, router: router, executor: executor,
                                              voices: offeredVoices(model), noModel: noCastLine(router: router),
                                              log: { castLog.error("\($0, privacy: .public)") })
    }

    @MainActor
    static func place(_ document: ImportedDocument, casting: DialogueCast.Casting, model: MobileModel,
                      progress: @escaping @MainActor (Int, Int) -> Void) async -> (fill: DialogueCast.Fill, line: String) {
        let (router, executor) = routing(model)
        return await DialogueCastFlow.place(document, casting: casting, router: router, executor: executor,
                                            noModel: noFillLine(router: router),
                                            log: { castLog.error("\($0, privacy: .public)") },
                                            progress: { done, total in await progress(done, total) })
    }
}

/// A voice heard in a few words, made by the Baton server; pressing the playing voice again
/// stops it, another switches to it.
@MainActor
@Observable
final class MobileVoicePreview {
    private(set) var playing: String?
    private(set) var failure: String?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ voice: String, text: String, client: GatewayBookClient?) {
        let was = playing
        stop()
        guard was != voice, let client else { return }
        Task {
            do {
                let wav = try await client.preview(text: String(text.prefix(200)), voice: voice)
                let player = try AVAudioPlayer(data: wav)
                self.player = player
                playing = voice
                failure = nil
                player.play()
                try? await Task.sleep(for: .seconds(player.duration))
                if playing == voice, self.player === player { playing = nil }
            } catch {
                failure = "Your Baton server could not play \(VoiceDirectory.entry(voice).label): \(error.localizedDescription)"
                if playing == voice { playing = nil }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }
}

/// Voice the dialogue for one book on one screen: the switch and the cast, writing the cast list,
/// and placing the lines once the cast is checked. Owned by the screen, so the editor is presented
/// from the screen itself: a sheet hung on a `List` section closed the import screen under it.
@MainActor
@Observable
final class MobileCastModel {
    var choice: DialogueCastFlow.Choice
    /// Check the Cast… is open.
    var editing = false
    /// The import screen's switch is remembered; Change Voice leaves that alone.
    let remembers: Bool
    @ObservationIgnored private var placingTask: Task<Void, Never>?

    init(_ choice: DialogueCastFlow.Choice, remembers: Bool) {
        self.choice = choice
        self.remembers = remembers
    }

    /// The switch was turned; on, the cast list is written once per book.
    func switched(_ on: Bool, document: ImportedDocument, narrator: String, model: MobileModel) {
        if remembers { MobileCast.remember(on) }
        if on { start(document: document, narrator: narrator, model: model) }
    }

    func start(document: ImportedDocument, narrator: String, model: MobileModel) {
        switch choice.phase {
        case .idle, .unavailable:
            placingTask?.cancel()
            choice.phase = .writing
            choice.reviewed = false
            choice.placing = .idle
            Task {
                let result = await MobileCast.propose(for: document, narrator: narrator, model: model)
                choice.phase = result.phase
                choice.voices = result.voices
            }
        case .writing, .ready: break
        }
    }

    /// Use This Cast: the cast as checked, then the lines the rules leave are placed with it.
    func use(_ edited: DialogueCast.Casting, document: ImportedDocument, model: MobileModel) {
        choice.phase = .ready(edited)
        choice.reviewed = true
        editing = false
        placingTask?.cancel()
        choice.placing = .placing(done: 0, of: 0)
        placingTask = Task {
            let result = await MobileCast.place(document, casting: edited, model: model) { [weak self] done, total in
                guard let self, !Task.isCancelled, case .placing = self.choice.placing else { return }
                self.choice.placing = .placing(done: done, of: total)
            }
            guard !Task.isCancelled else { return }
            choice.placing = .placed(result.fill, line: result.line)
        }
    }

    func skip() {
        placingTask?.cancel()
        placingTask = nil
        choice.placing = .placed(DialogueCast.Fill(), line: DialogueCastFlow.skippedLine)
    }
}

/// The switch, what is happening, and the way into the editor, as a `List` section: on the
/// import screen, and in Change Voice for a book with no cast yet. The screen presents the
/// editor with `castEditor`.
struct MobileCastSection: View {
    @Bindable var cast: MobileCastModel
    let document: ImportedDocument
    let narrator: String
    let model: MobileModel

    var body: some View {
        Section {
            Toggle("Voice the dialogue", isOn: $cast.choice.isOn)
                .accessibilityIdentifier("voice-the-dialogue")
            if cast.choice.isOn { status }
        } footer: {
            if !cast.choice.isOn {
                Text("One narrator reads everything. Turn this on to give each speaking character a voice of their own.")
            }
        }
        .onChange(of: cast.choice.isOn) { _, on in
            cast.switched(on, document: document, narrator: narrator, model: model)
        }
        .onAppear {
            if cast.choice.isOn, cast.choice.phase == .idle { cast.start(document: document, narrator: narrator, model: model) }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch cast.choice.phase {
        case .idle, .writing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Writing the cast list…").foregroundStyle(.secondary)
            }
        case let .unavailable(why):
            Text(why).font(.callout).foregroundStyle(.orange)
                .accessibilityIdentifier("cast-unavailable")
        case let .ready(casting):
            Text(DialogueCastFlow.summary(casting, narrator: narrator, reviewed: cast.choice.reviewed))
                .font(.callout).foregroundStyle(cast.choice.reviewed ? Color.secondary : Color.orange)
                .accessibilityIdentifier("cast-summary")
            Button(cast.choice.reviewed ? "Edit Cast…" : "Check the Cast…") { cast.editing = true }
                .accessibilityIdentifier("check-the-cast")
            switch cast.choice.placing {
            case .idle:
                EmptyView()
            case let .placing(done, total):
                HStack(spacing: 8) {
                    ProgressView()
                    Text(DialogueCastFlow.placingLine(done: done, of: total)).font(.callout)
                    Spacer()
                    Button("Skip") { cast.skip() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("skip-placing")
                }
            case let .placed(_, line):
                Text(line).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("placed-line")
            }
        }
    }
}

extension View {
    /// Check the Cast…, presented from the screen that owns `cast`.
    func castEditor(_ cast: MobileCastModel, document: ImportedDocument?, narrator: String, voices: [String]?,
                    model: MobileModel) -> some View {
        sheet(isPresented: Binding(get: { cast.editing }, set: { cast.editing = $0 })) {
            if case let .ready(casting) = cast.choice.phase, let document {
                MobileCastEditor(casting: casting, narrator: narrator, voices: voices ?? cast.choice.voices,
                                 previewFallback: MobileCast.opening(document), model: model) { edited in
                    cast.use(edited, document: document, model: model)
                } onCancel: {
                    cast.editing = false
                }
            }
        }
    }
}

/// The cast for correction on the phone: rename, merge two entries that are one person, mark
/// who narrates, take someone off the list, and give each speaker a voice, heard saying one of
/// their own lines.
struct MobileCastEditor: View {
    @State var casting: DialogueCast.Casting
    let narrator: String
    let voices: [String]
    let previewFallback: String
    let model: MobileModel
    /// Said on top; by default, who proposed the cast and that it needs checking.
    var intro: String?
    let onDone: (DialogueCast.Casting) -> Void
    let onCancel: () -> Void

    @State private var preview = MobileVoicePreview()
    /// Names as typed, applied on Return or Use This Cast.
    @State private var nameDrafts: [String: String] = [:]
    @State private var problem: String?

    private var choices: [String] {
        DialogueCastFlow.speakerVoices(narrator: narrator, offered: voices, casting: casting)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text((intro ?? "Proposed by \(casting.source ?? "a model"). Correct anything that is wrong before the book is made. ")
                         + "The narrator, \(DialogueCastFlow.voiceLabel(narrator)), reads the story and any line nobody can place.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(casting.speakers) { speaker in
                    Section {
                        row(speaker)
                    } header: {
                        Text(DialogueCastFlow.linesLabel(speaker.lines))
                    }
                }
                if casting.speakers.isEmpty {
                    Section { Text("Nobody is left: the narrator reads every line.").foregroundStyle(.secondary) }
                }
                if let problem = problem ?? preview.failure {
                    Section { Text(problem).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Check the Cast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { preview.stop(); onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This Cast") {
                        guard applyDrafts() else { return }
                        preview.stop()
                        onDone(casting)
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("use-this-cast")
                }
            }
        }
        .onDisappear { preview.stop() }
    }

    @ViewBuilder
    private func row(_ speaker: DialogueCast.Casting.Speaker) -> some View {
        HStack {
            TextField("Name", text: nameBinding(speaker))
                .onSubmit { _ = applyDrafts() }
                .submitLabel(.done)
                .accessibilityLabel("Name of \(speaker.name)")
            Menu {
                Toggle("This Is the Narrator", isOn: narratorBinding(speaker))
                Menu("Merge Into") {
                    ForEach(casting.speakers.filter { $0.id != speaker.id }) { other in
                        Button(other.name) {
                            _ = applyDrafts()
                            casting.merge(speaker.id, into: other.id)
                        }
                    }
                }
                .disabled(casting.speakers.count < 2)
                Button("Not a Speaker", role: .destructive) {
                    nameDrafts[speaker.id] = nil
                    casting.remove(speaker.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle").imageScale(.large)
            }
            .accessibilityLabel("More for \(speaker.name)")
        }
        if speaker.isNarrator {
            Text("The narrator: these lines are read in the narrator's voice.").font(.callout).foregroundStyle(.secondary)
        } else {
            NavigationLink {
                voiceList(speaker)
            } label: {
                LabeledContent("Voice", value: voiceTitle(speaker.voice))
            }
            .accessibilityIdentifier("cast-voice-\(speaker.id)")
            Button {
                if let voice = speaker.voice { preview.toggle(voice, text: speaker.sample ?? previewFallback, client: model.gatewayBookClient()) }
            } label: {
                let playing = speaker.voice != nil && preview.playing == speaker.voice
                Label(playing ? "Stop" : "Hear", systemImage: playing ? "stop.circle" : "play.circle")
            }
            .disabled(speaker.voice == nil)
            .accessibilityLabel("Hear \(speaker.name)")
        }
    }

    private func voiceList(_ speaker: DialogueCast.Casting.Speaker) -> some View {
        List {
            Section {
                Button {
                    casting.setVoice(speaker.id, nil)
                } label: {
                    HStack {
                        Text("Narrator's voice").foregroundStyle(.primary)
                        Spacer()
                        if casting.speaker(speaker.id)?.voice == nil { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .accessibilityAddTraits(casting.speaker(speaker.id)?.voice == nil ? .isSelected : [])
            } footer: {
                Text("The narrator reads \(speaker.name)'s lines.")
            }
            VoicePicker(suggested: DialogueCastFlow.suggestedVoices(for: casting.speaker(speaker.id) ?? speaker, narrator: narrator,
                                                                    choices: choices),
                        all: choices, chosen: voiceBinding(speaker), playing: preview.playing,
                        tag: { $0 == narrator ? "the narrator" : nil },
                        onPreview: { preview.toggle($0, text: speaker.sample ?? previewFallback, client: model.gatewayBookClient()) })
        }
        .navigationTitle("Voice for \(speaker.name)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func voiceTitle(_ voice: String?) -> String {
        guard let voice else { return "Narrator's voice" }
        let label = VoiceDirectory.entry(voice).label
        return voice == narrator ? "\(label), the narrator" : label
    }

    private func applyDrafts() -> Bool {
        var refused: String?
        for (id, name) in nameDrafts {
            guard casting.speaker(id)?.name != name else { nameDrafts[id] = nil; continue }
            if casting.rename(id, to: name) {
                nameDrafts[id] = nil
            } else {
                refused = name.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Every speaker needs a name. To take someone off the list, use Not a Speaker."
                    : "Another speaker is called \(name). To make them one person, use Merge Into."
            }
        }
        problem = refused
        return refused == nil
    }

    private func nameBinding(_ speaker: DialogueCast.Casting.Speaker) -> Binding<String> {
        Binding(get: { nameDrafts[speaker.id] ?? casting.speaker(speaker.id)?.name ?? speaker.name }) { nameDrafts[speaker.id] = $0 }
    }

    private func narratorBinding(_ speaker: DialogueCast.Casting.Speaker) -> Binding<Bool> {
        Binding(get: { casting.speaker(speaker.id)?.isNarrator ?? false }) { casting.setNarrator(speaker.id, $0) }
    }

    private func voiceBinding(_ speaker: DialogueCast.Casting.Speaker) -> Binding<String?> {
        Binding(get: { casting.speaker(speaker.id)?.voice }) { casting.setVoice(speaker.id, $0) }
    }
}
