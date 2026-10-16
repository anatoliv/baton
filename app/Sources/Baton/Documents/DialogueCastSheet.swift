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
struct DialogueCastChoice: Equatable {
    enum Phase: Equatable {
        case idle
        case writing
        case ready(DialogueCast.Casting)
        case unavailable(String)
    }

    enum Placing: Equatable {
        /// Not asked: the cast has not been checked.
        case idle
        case placing(done: Int, of: Int)
        /// The model's answers (none when no model answered or the person skipped), and the line
        /// that says what happened.
        case placed(DialogueCast.Fill, line: String)
    }

    /// Off unless asked: `remembered` starts a new import as the person last left it.
    var isOn = false
    var phase = Phase.idle
    /// The voices the speakers can choose from (the Kokoro host's list when the cast was written).
    var voices: [String] = []
    /// The person has checked the cast and pressed Use This Cast. Nothing a model wrote is used
    /// before that.
    var reviewed = false
    var placing = Placing.idle

    /// The switch as the person last set it on this Mac, off for the first book ever imported
    /// here. A device-local key, deliberately not in `PreferenceSync.syncedKeys`:
    /// whether a Mac voices dialogue depends on the models it can reach. Like the other document
    /// settings on the Mac (`baton.documents.enabled`, the saved model sources) it lives in
    /// Baton's defaults, which the Mac has no session purge for.
    static let rememberedKey = "baton.documents.voiceTheDialogue"

    static func remembered(in defaults: UserDefaults = BatonStorage.defaults) -> DialogueCastChoice {
        var choice = DialogueCastChoice()
        choice.isOn = defaults.object(forKey: rememberedKey) as? Bool ?? false
        return choice
    }

    static func remember(_ isOn: Bool, in defaults: UserDefaults = BatonStorage.defaults) {
        defaults.set(isOn, forKey: rememberedKey)
    }

    /// The cast that goes into the book: on, written, and checked.
    var castingToUse: DialogueCast.Casting? {
        guard isOn, reviewed, case let .ready(casting) = phase else { return nil }
        return casting
    }

    /// The model's speakers for the lines the rules left, with the cast they were asked with.
    var fillToUse: DialogueCast.Fill? {
        guard castingToUse != nil, case let .placed(fill, _) = placing else { return nil }
        return fill
    }

    /// Make Audiobook waits while the cast is being written, has not been checked, or its
    /// remaining lines are being placed.
    var holdsTheBook: Bool {
        guard isOn else { return false }
        switch phase {
        case .writing: return true
        case .ready:
            if case .placing = placing { return true }
            return !reviewed
        case .idle, .unavailable: return false
        }
    }
}

enum DialogueCastEditing {
    static let modelTask = ModelTask.castSheet

    /// The book the import sheet submits: with the checked cast when there is one, otherwise the
    /// narrator-only book exactly as it was made before casts existed (same id, same chunks).
    static func book(_ document: ImportedDocument, plan: VoicePlan, choice: DialogueCastChoice) -> PreparedBook {
        guard let casting = choice.castingToUse else { return DocumentSpeech.prepare(document, voices: plan) }
        return DialogueCast.prepare(document, plan: plan, casting: casting, fill: choice.fillToUse)
    }

    /// Placing the lines the rules leave: chapters, so chapter consent for a cloud source.
    static let fillTask = ModelTask.dialogueCast

    /// Why no model places the remaining lines when no source may.
    static func noFillLine(router: ModelRouter) -> String {
        guard let cloud = router.awaitingConsent(for: fillTask).first else {
            return "No model on this Mac or the Baton server can place the lines without a speech tag, so the narrator reads those."
        }
        return "No model on this Mac or the Baton server can place the lines without a speech tag, and "
            + "\(CloudModelConsent.notAllowedClause(cloud, fillTask.content)), so the narrator reads those."
    }

    /// What placing did, in one line.
    static func placedLine(_ fill: DialogueCast.Fill) -> String {
        guard let source = fill.source else {
            return "No model answered for the lines without a speech tag, so the narrator reads those."
        }
        let placed = fill.placedByRules + fill.speakers.count
        return "\(source) placed \(fill.speakers.count) more lines, so \(placed) of \(fill.quotes) lines have a speaker. "
            + "The narrator reads the rest."
    }

    /// Ask a model about the lines the rules leave, with the checked cast.
    @MainActor
    static func place(_ document: ImportedDocument, casting: DialogueCast.Casting,
                      progress: @escaping @MainActor (Int, Int) -> Void) async -> (fill: DialogueCast.Fill, line: String) {
        let routing = await VoiceSuggestions.liveRouting()
        let router = routing.router()
        guard !router.plan(for: fillTask).usable.isEmpty else { return (DialogueCast.Fill(), noFillLine(router: router)) }
        let executor = routing.executor
        let failure = FailureNote()
        let fill = await DialogueCast.fill(document, cast: casting.sheet, complete: { system, user in
            do {
                return try await router.complete(fillTask, system: system, user: user, executor: executor)
            } catch {
                failure.note(String(describing: error))
                throw error
            }
        }, progress: { done, total in await progress(done, total) })
        if fill.source == nil {
            documentsLog.error("cast lines: no model answered: \(failure.text ?? "nothing to ask", privacy: .public)")
        }
        return (fill, placedLine(fill))
    }

    /// Why there is no cast list when no source may write one.
    static func noModelLine(router: ModelRouter) -> String {
        guard let cloud = router.awaitingConsent(for: modelTask).first else {
            return "No model on this Mac or the Baton server can write a cast list, so the narrator reads every line."
        }
        return "No model on this Mac or the Baton server can write a cast list, and "
            + "\(CloudModelConsent.notAllowedClause(cloud, modelTask.content)), so the narrator reads every line."
    }

    /// A cast is joined into one file per chapter, so its voices share the narrator's engine;
    /// only Kokoro offers a list of voices to cast from.
    static func narratorLine(_ narrator: String) -> String? {
        narrator.hasPrefix("kokoro:") ? nil : "A cast needs a Kokoro narrator. With this narrator every line is read in one voice."
    }

    /// Ask a model for the cast list, then count lines and choose voices with the rules.
    @MainActor
    static func propose(for document: ImportedDocument, narrator: String) async -> (phase: DialogueCastChoice.Phase, voices: [String]) {
        let routing = await VoiceSuggestions.liveRouting()
        let router = routing.router()
        guard !router.plan(for: modelTask).usable.isEmpty else { return (.unavailable(noModelLine(router: router)), []) }
        async let listed = VoiceSuggestions.availableVoices()
        let executor = routing.executor
        let failure = FailureNote()
        let made = await CastSheetGenerator.generate(for: document) { system, user in
            do {
                return try await router.complete(modelTask, system: system, user: user, executor: executor)
            } catch {
                failure.note(String(describing: error))
                throw error
            }
        }
        let voices = await listed
        guard let source = made.source else {
            documentsLog.error("cast list: no model answered: \(failure.text ?? "no dialogue found", privacy: .public)")
            return (.unavailable("No model answered for the cast list, so the narrator reads every line."), voices)
        }
        guard !made.sheet.characters.isEmpty else {
            return (.unavailable("\(source) found no speaking characters, so the narrator reads every line."), voices)
        }
        let sheet = made.sheet
        let casting = await Task.detached(priority: .userInitiated) {
            DialogueCast.Casting(sheet: sheet, document: document, narrator: narrator, available: voices, source: source)
        }.value
        return (.ready(casting), voices)
    }

    /// Why the router's call failed, kept for the log: `CastSheetGenerator` only says that it did.
    final class FailureNote: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func note(_ text: String) { lock.withLock { value = text } }
        var text: String? { lock.withLock { value } }
    }

    /// "bm_george, British male".
    static func voiceLabel(_ spec: String) -> String {
        let d = VoiceCatalogue.describe(spec)
        let name = spec.split(separator: ":", maxSplits: 1).last.map(String.init) ?? spec
        let about = [d.accent?.capitalized, d.gender].compactMap { $0 }.joined(separator: " ")
        return about.isEmpty ? name : "\(name), \(about)"
    }

    /// "12 lines found", "no lines found".
    static func linesLabel(_ count: Int) -> String {
        switch count {
        case 0: "no lines found"
        case 1: "1 line found"
        default: "\(count) lines found"
        }
    }
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
            DialogueCastChoice.remember(on)
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
                CastSheetEditor(casting: casting, narrator: narrator, voices: choice.voices,
                                previewFallback: VoiceSuggestions.previewText(for: document)) { edited in
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
            if let line = DialogueCastEditing.narratorLine(narrator) {
                Text(line).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
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
                    Text(total > 0 ? "Finding who speaks the lines without a speech tag: part \(min(done + 1, total)) of \(total)…"
                                   : "Finding who speaks the lines without a speech tag…")
                        .font(.caption)
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
        choice.placing = .placed(DialogueCast.Fill(), line: "Skipped: the narrator reads the lines without a speech tag.")
    }

    private func summary(_ casting: DialogueCast.Casting) -> String {
        let voiced = casting.voices(narrator: narrator).count
        let people = casting.speakers.count == 1 ? "1 speaker" : "\(casting.speakers.count) speakers"
        if choice.reviewed { return "\(people), \(voiced) with a voice of their own. Lines nobody can place are read by the narrator." }
        return "\(casting.source ?? "A model") proposed \(people). Check the cast before the book is made: a model gets some of them wrong."
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
        let result = await DialogueCastEditing.propose(for: document, narrator: narrator)
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
    let onDone: (DialogueCast.Casting) -> Void
    let onCancel: () -> Void

    @State private var preview = VoicePreviewPlayer()
    @State private var problem: String?
    /// Names and phrases as typed, applied on Return or Use This Cast: applied letter by letter,
    /// a rename would keep every half-typed name as a phrase, and a trailing comma would vanish.
    @State private var nameDrafts: [String: String] = [:]
    @State private var aliasDrafts: [String: String] = [:]

    init(casting: DialogueCast.Casting, narrator: String, voices: [String], previewFallback: String,
         onDone: @escaping (DialogueCast.Casting) -> Void, onCancel: @escaping () -> Void) {
        _casting = State(initialValue: casting)
        self.narrator = narrator
        self.voices = voices
        self.previewFallback = previewFallback
        self.onDone = onDone
        self.onCancel = onCancel
    }

    /// The narrator's engine only: a chapter is joined from clips of one format.
    private var choices: [String] {
        let engine = narrator.split(separator: ":").first.map(String.init) ?? "kokoro"
        var list = voices.filter { $0.hasPrefix(engine + ":") }
        for chosen in casting.speakers.compactMap(\.voice) where !list.contains(chosen) { list.append(chosen) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check the Cast").font(.title3.weight(.semibold))
            Text("Proposed by \(casting.source ?? "a model"). Correct anything that is wrong before the book is made. "
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
                    Picker("Voice", selection: voiceBinding(speaker)) {
                        Text("Narrator's voice").tag(String?.none)
                        ForEach(choices, id: \.self) { voice in
                            Text(voice == narrator ? "\(DialogueCastEditing.voiceLabel(voice)), the narrator" : DialogueCastEditing.voiceLabel(voice))
                                .tag(String?.some(voice))
                        }
                    }
                    .frame(width: 300)
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
            TextField("Also called in the text, separated by commas", text: aliasBinding(speaker))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { _ = applyDrafts() }
                .accessibilityLabel("Also called, for \(speaker.name)")
        }
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
