import BatonDocuments
import BatonSubsonicKit
import OSLog
import SwiftUI

/// The dialogue cast on the import sheet (G4, `specs/document-clippings.md`, *Dialogue cast*):
/// a per-book "Voice the dialogue" switch, off for the first book on a Mac and then as the
/// person last left it there (`remembered`, TBX-10916); when on, a cast list written by a
/// model through `ModelRouter` (`ModelTask.castSheet`: excerpts, so local sources first and a
/// cloud one only with the person's consent), shown for correction before anything uses it.
///
/// A generated sheet put one voice on one person 81% of the time (G3), so the book is made with
/// a cast only after the person has checked it in `CastSheetEditor`. With no model, or a model
/// that found nobody, the sheet says so and the book is read by the narrator alone.
///
/// Once the cast is checked, a model places the lines the rules leave (`DialogueCast.fill`,
/// TBX-10894: rules first, then a model, so most lines get a voice). With no model the rules'
/// lines stand and the sheet says so in one line.
///
/// The flow itself is shared with the iPhone (`DialogueCastFlow`, TBX-11141); this Mac brings
/// its models, its voices and its words.
typealias DialogueCastChoice = DialogueCastFlow.Choice

extension DialogueCastFlow.Choice {
    /// The switch as the person last set it on this Mac, off for the first book ever imported
    /// here. A device-local key, deliberately not in `PreferenceSync.syncedKeys`:
    /// whether a Mac voices dialogue depends on the models it can reach. Like the other document
    /// settings on the Mac (`baton.documents.enabled`, the saved model sources) it lives in
    /// Baton's defaults, which the Mac has no session purge for.
    static let rememberedKey = "baton.documents.voiceTheDialogue"

    static func remembered(in defaults: UserDefaults = BatonStorage.defaults) -> DialogueCastChoice {
        DialogueCastChoice(isOn: defaults.object(forKey: rememberedKey) as? Bool ?? false)
    }

    static func remember(_ isOn: Bool, in defaults: UserDefaults = BatonStorage.defaults) {
        defaults.set(isOn, forKey: rememberedKey)
    }
}

enum DialogueCastEditing {
    static let modelTask = DialogueCastFlow.castTask
    static let fillTask = DialogueCastFlow.fillTask

    static func book(_ document: ImportedDocument, plan: VoicePlan, choice: DialogueCastChoice) -> PreparedBook {
        DialogueCastFlow.book(document, plan: plan, choice: choice)
    }

    /// Why no model places the remaining lines when no source may.
    static func noFillLine(router: ModelRouter) -> String {
        guard let cloud = router.awaitingConsent(for: fillTask).first else { return DialogueCastFlow.noFillLine(device: "this Mac") }
        return "No model on this Mac or the Baton server can place the lines without a speech tag, and "
            + "\(CloudModelConsent.notAllowedClause(cloud, fillTask.content)), so the narrator reads those."
    }

    static func placedLine(_ fill: DialogueCast.Fill) -> String { DialogueCastFlow.placedLine(fill) }

    /// Ask a model about the lines the rules leave, with the checked cast.
    @MainActor
    static func place(_ document: ImportedDocument, casting: DialogueCast.Casting,
                      progress: @escaping @MainActor (Int, Int) -> Void) async -> (fill: DialogueCast.Fill, line: String) {
        let routing = await VoiceSuggestions.liveRouting()
        let router = routing.router()
        return await DialogueCastFlow.place(document, casting: casting, router: router, executor: routing.executor,
                                            noModel: noFillLine(router: router),
                                            log: { documentsLog.error("\($0, privacy: .public)") },
                                            progress: { done, total in await progress(done, total) })
    }

    /// Why there is no cast list when no source may write one.
    static func noModelLine(router: ModelRouter) -> String {
        guard let cloud = router.awaitingConsent(for: modelTask).first else { return DialogueCastFlow.noCastLine(device: "this Mac") }
        return "No model on this Mac or the Baton server can write a cast list, and "
            + "\(CloudModelConsent.notAllowedClause(cloud, modelTask.content)), so the narrator reads every line."
    }


    /// Ask a model for the cast list, then count lines and choose voices with the rules.
    /// `voices` lists what the speakers can be given: this Mac's voice server's by default.
    @MainActor
    static func propose(for document: ImportedDocument, narrator: String,
                        voices: @escaping @Sendable () async -> [String] = { await VoiceSuggestions.availableVoices() })
        async -> (phase: DialogueCastChoice.Phase, voices: [String]) {
        let routing = await VoiceSuggestions.liveRouting()
        let router = routing.router()
        return await DialogueCastFlow.propose(for: document, narrator: narrator, router: router, executor: routing.executor,
                                              voices: voices, noModel: noModelLine(router: router),
                                              log: { documentsLog.error("\($0, privacy: .public)") })
    }

    static func voiceLabel(_ spec: String) -> String { DialogueCastFlow.voiceLabel(spec) }
    static func linesLabel(_ count: Int) -> String { DialogueCastFlow.linesLabel(count) }
}

/// The import sheet's section: the switch, what is happening, and the way into the editor.
struct DialogueCastSection: View {
    let document: ImportedDocument
    let narrator: String
    /// The sheet's other model calls (narrator, pronunciations) are done. The cast list waits for
    /// them: on one small local model the three queue, and the third timed out behind the others
    /// in the probe walk (2026-10-15).
    let modelFree: Bool
    @Binding var choice: DialogueCastChoice
    /// Every voice the renderer offers, the Baton server's when it makes the book;
    /// nil keeps the voices the cast was written with.
    var rendererVoices: [String]? = nil
    /// Previews come from the Baton server, which makes the book.
    var previewOnServer = false
    /// The switch is the import default (`remembered`); Change Voice… leaves that alone.
    var remembers = true
    /// The voices the speakers can be given: the renderer's, when the caller knows them
    /// (Change Voice…); this Mac's voice server's otherwise.
    var offeredVoices: (@Sendable () async -> [String])? = nil
    @State private var editing = false
    @State private var waiting = false
    @State private var placingTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Voice the dialogue", isOn: $choice.isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("voice-the-dialogue")
            if choice.isOn {
                status
            } else {
                Text("One narrator reads everything. Turn this on to give each speaking character a voice of their own.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: choice.isOn) { _, on in
            if remembers { DialogueCastChoice.remember(on) }
            if on { start() }
        }
        .onAppear {
            // A sheet that opens with the switch already on (the person's last choice) writes
            // the cast as if it had just been turned on.
            if choice.isOn, choice.phase == .idle { start() }
        }
        .onChange(of: modelFree) { _, free in
            guard free, waiting else { return }
            waiting = false
            Task { await write() }
        }
        .sheet(isPresented: $editing) {
            if case let .ready(casting) = choice.phase {
                CastSheetEditor(casting: casting, narrator: narrator, voices: rendererVoices ?? choice.voices,
                                previewFallback: VoiceSuggestions.previewText(for: document),
                                preview: previewOnServer ? .batonServer() : VoicePreviewPlayer()) { edited in
                    choice.phase = .ready(edited)
                    choice.reviewed = true
                    editing = false
                    place(edited)
                } onCancel: {
                    editing = false
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch choice.phase {
        case .idle, .writing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(waiting ? "Writing the cast list after the pronunciations…" : "Writing the cast list…").font(.callout)
            }
        case let .unavailable(why):
            Text(why).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case let .ready(casting):
            HStack(alignment: .firstTextBaseline) {
                Text(summary(casting)).font(.caption).foregroundStyle(choice.reviewed ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(choice.reviewed ? "Edit Cast…" : "Check the Cast…") { editing = true }
                    .accessibilityIdentifier("check-the-cast")
            }
            switch choice.placing {
            case .idle:
                EmptyView()
            case let .placing(done, total):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(DialogueCastFlow.placingLine(done: done, of: total)).font(.caption)
                    Spacer()
                    Button("Skip") { skipPlacing() }
                        .controlSize(.small)
                        .accessibilityIdentifier("skip-placing")
                }
            case let .placed(_, line):
                Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("placed-line")
            }
        }
    }

    /// Place the lines the rules leave, with the cast as checked. Asked again whenever the cast
    /// is checked again, since the answers are names from it.
    private func place(_ casting: DialogueCast.Casting) {
        placingTask?.cancel()
        choice.placing = .placing(done: 0, of: 0)
        placingTask = Task {
            let result = await DialogueCastEditing.place(document, casting: casting) { done, total in
                guard !Task.isCancelled, case .placing = choice.placing else { return }
                choice.placing = .placing(done: done, of: total)
            }
            guard !Task.isCancelled else { return }
            choice.placing = .placed(result.fill, line: result.line)
        }
    }

    private func skipPlacing() {
        placingTask?.cancel()
        placingTask = nil
        choice.placing = .placed(DialogueCast.Fill(), line: DialogueCastFlow.skippedLine)
    }

    private func summary(_ casting: DialogueCast.Casting) -> String {
        DialogueCastFlow.summary(casting, narrator: narrator, reviewed: choice.reviewed)
    }

    /// Written once per book; asked again only when there was none to show.
    private func start() {
        switch choice.phase {
        case .idle, .unavailable:
            choice.phase = .writing
            if modelFree { Task { await write() } } else { waiting = true }
        case .writing, .ready: break
        }
    }

    private func write() async {
        placingTask?.cancel()
        choice.phase = .writing
        choice.reviewed = false
        choice.placing = .idle
        let result = if let offeredVoices {
            await DialogueCastEditing.propose(for: document, narrator: narrator, voices: offeredVoices)
        } else {
            await DialogueCastEditing.propose(for: document, narrator: narrator)
        }
        choice.phase = result.phase
        choice.voices = result.voices
    }
}

/// The cast list for correction: rename, merge two entries that are one person, mark who
/// narrates, the phrases the text uses for each, and each speaker's voice, which can be heard
/// saying one of their own lines.
struct CastSheetEditor: View {
    @State var casting: DialogueCast.Casting
    let narrator: String
    let voices: [String]
    let previewFallback: String
    /// Said under the title; by default, who proposed the cast and that it needs checking.
    var intro: String?
    /// The phrases the text uses for each speaker find their lines. A cast already in a book has
    /// its lines found (Change Voice…), so it has no phrases to edit.
    var showsPhrases = true
    let onDone: (DialogueCast.Casting) -> Void
    let onCancel: () -> Void

    @State private var preview: VoicePreviewPlayer
    @State private var problem: String?
    /// The speaker whose voice picker is open.
    @State private var pickingVoice: String?
    /// Names and phrases as typed, applied on Return or Use This Cast: applied letter by letter,
    /// a rename would keep every half-typed name as a phrase, and a trailing comma would vanish.
    @State private var nameDrafts: [String: String] = [:]
    @State private var aliasDrafts: [String: String] = [:]

    init(casting: DialogueCast.Casting, narrator: String, voices: [String], previewFallback: String,
         preview: VoicePreviewPlayer = VoicePreviewPlayer(), intro: String? = nil, showsPhrases: Bool = true,
         onDone: @escaping (DialogueCast.Casting) -> Void, onCancel: @escaping () -> Void) {
        _casting = State(initialValue: casting)
        _preview = State(initialValue: preview)
        self.narrator = narrator
        self.voices = voices
        self.previewFallback = previewFallback
        self.intro = intro
        self.showsPhrases = showsPhrases
        self.onDone = onDone
        self.onCancel = onCancel
    }

    /// The narrator's engine only: a chapter is joined from clips of one format.
    private var choices: [String] {
        DialogueCastFlow.speakerVoices(narrator: narrator, offered: voices, casting: casting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check the Cast").font(.title3.weight(.semibold))
            Text((intro ?? "Proposed by \(casting.source ?? "a model"). Correct anything that is wrong before the book is made. ")
                 + "The narrator, \(DialogueCastEditing.voiceLabel(narrator)), reads the story and any line nobody can place.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(casting.speakers) { speaker in
                        row(speaker)
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 420)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            if let failure = preview.failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { preview.stop(); onCancel() }.keyboardShortcut(.cancelAction)
                Button("Use This Cast") {
                    guard applyDrafts() else { return }
                    preview.stop()
                    onDone(casting)
                }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("use-this-cast")
            }
        }
        .padding(20)
        .frame(width: 560)
        .onDisappear { preview.stop() }
    }

    @ViewBuilder
    private func row(_ speaker: DialogueCast.Casting.Speaker) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Name", text: nameBinding(speaker))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { _ = applyDrafts() }
                    .accessibilityLabel("Name of \(speaker.name)")
                Text(DialogueCastEditing.linesLabel(speaker.lines)).font(.caption).foregroundStyle(.secondary)
                Spacer()
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
                    Divider()
                    Button("Not a Speaker") {
                        nameDrafts[speaker.id] = nil
                        aliasDrafts[speaker.id] = nil
                        casting.remove(speaker.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More for \(speaker.name)")
            }
            if speaker.isNarrator {
                Text("The narrator: these lines are read in the narrator's voice.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    // The voice picker the narrator is chosen with, in a popover.
                    Button {
                        pickingVoice = speaker.id
                    } label: {
                        HStack(spacing: 4) {
                            Text(voiceTitle(speaker.voice)).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                    }
                    .frame(width: 300, alignment: .leading)
                    .accessibilityLabel("Voice for \(speaker.name)")
                    .accessibilityValue(voiceTitle(speaker.voice))
                    .accessibilityIdentifier("cast-voice-\(speaker.id)")
                    .popover(isPresented: Binding(get: { pickingVoice == speaker.id },
                                                  set: { if !$0 { pickingVoice = nil } })) {
                        voicePicker(speaker)
                    }
                    Button {
                        if let voice = speaker.voice { preview.toggle(voice, text: speaker.sample ?? previewFallback) }
                    } label: {
                        Label(preview.playing == speaker.voice && speaker.voice != nil ? "Stop" : "Hear",
                              systemImage: preview.playing == speaker.voice && speaker.voice != nil ? "stop.circle" : "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(speaker.voice == nil)
                }
            }
            if showsPhrases {
                TextField("Also called in the text, separated by commas", text: aliasBinding(speaker))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { _ = applyDrafts() }
                    .accessibilityLabel("Also called, for \(speaker.name)")
            }
        }
    }

    /// "Heart, American, female", or what stands for the narrator.
    private func voiceTitle(_ voice: String?) -> String {
        guard let voice else { return "Narrator's voice" }
        let label = VoiceDirectory.entry(voice).label
        return voice == narrator ? "\(label), the narrator" : label
    }

    /// The speaker's voice now, then the voices best for dialogue in the narrator's language.
    private func suggestions(_ speaker: DialogueCast.Casting.Speaker) -> [String] {
        DialogueCastFlow.suggestedVoices(for: speaker, narrator: narrator, choices: choices)
    }

    private func voicePicker(_ speaker: DialogueCast.Casting.Speaker) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice for \(speaker.name)").font(.headline)
            Button {
                casting.setVoice(speaker.id, nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: speaker.voice == nil ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(speaker.voice == nil ? Color.accentColor : .secondary)
                    Text("Narrator's voice")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .accessibilityAddTraits(speaker.voice == nil ? .isSelected : [])
            VoicePicker(suggested: suggestions(speaker), all: choices, chosen: voiceBinding(speaker),
                        playing: preview.playing,
                        tag: { $0 == narrator ? "the narrator" : nil },
                        onPreview: { preview.toggle($0, text: speaker.sample ?? previewFallback) })
        }
        .padding(14)
        .frame(width: 400)
    }

    // MARK: Bindings over the editing operations

    /// Apply typed names and phrases. False when a name is refused (empty, or another
    /// speaker's), which stays in its field with the reason below.
    private func applyDrafts() -> Bool {
        for (id, text) in aliasDrafts { casting.setAliases(id, text) }
        aliasDrafts = [:]
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

    private func aliasBinding(_ speaker: DialogueCast.Casting.Speaker) -> Binding<String> {
        Binding(get: { aliasDrafts[speaker.id] ?? (casting.speaker(speaker.id)?.character.aliases ?? []).joined(separator: ", ") }) {
            aliasDrafts[speaker.id] = $0
        }
    }
}
