import AppKit
import BatonDocuments
import BatonSpeech
import Observation
import SwiftUI

/// Settings → Speech → **Models on this Mac** (`specs/local-models-on-mac.md`, cards M7.2 to
/// M7.4). One row per server that can run on this Mac, each saying what it found: not installed,
/// installed and not running, or running with what it has.
///
/// The rules this screen keeps:
/// - Baton never installs anything. A missing server gets a link to its vendor's page and the
///   row finds it once it is running.
/// - A model download starts only from a button that names the model and its size, and can be
///   cancelled. Free space is checked before it starts, not discovered at 90%.
/// - A model is saved only after it answered a real request, and a saved one that stops
///   answering says so rather than disappearing.
/// - Everything here talks to `127.0.0.1`. No book text goes anywhere from this screen.
///
/// Behind `baton.documents.enabled`, like the rest of document clippings.
struct LocalModelsSection: View {
    @State private var model = LocalModelsModel()
    @State private var showKokoroHelp = false

    var body: some View {
        Group {
            ollamaSection
            lmStudioSection
            kokoroSection
            savedSection
        }
        // Poll while the pane is open: quickly while something is still missing, because that is
        // when the person is off starting it and will come back to look; slowly otherwise.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: model.everythingRunning ? .seconds(10) : .seconds(2))
            }
        }
        .sheet(isPresented: $showKokoroHelp) { KokoroHelpSheet() }
    }

    // MARK: - Ollama

    private var ollamaSection: some View {
        Section {
            serverRow("Ollama", state: model.ollama, port: 11434)
            switch model.ollama {
            case .notInstalled:
                note("Ollama runs language models on this Mac. Install it and open it, and this row finds it.")
                HStack(spacing: 12) {
                    Button("Get Ollama") { open("https://ollama.com/download") }
                    Text("or with Homebrew: `brew install --cask ollama-app`")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            case .notRunning:
                note("Ollama is installed but not running. Open it, and this row finds it.")
                Button("Open Ollama") { LocalModelsModel.openApp(bundleID: LocalModelsModel.ollamaBundleID) }
            case let .running(models):
                if models.isEmpty {
                    note("Ollama is running with no models yet. Download the one recommended below.")
                }
                ForEach(models) { item in modelRow(item, source: OllamaAPI.source(for: item)) }
                pullRow(installed: models)
            case let .unexpected(why):
                note(why)
            case nil:
                EmptyView()
            }
        } header: {
            Text("Models on this Mac")
        } footer: {
            Text("Document features, such as choosing a narrator's voice, need a language model. One running on this Mac keeps the book's text on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The recommended model, offered for download only when it is missing, with its size on
    /// the button itself. Nothing downloads until that button is pressed.
    @ViewBuilder
    private func pullRow(installed: [LocalModel]) -> some View {
        let recommended = model.recommended
        if !installed.contains(where: { $0.name == recommended.name }) {
            let size = LocalModelFormat.bytes(recommended.downloadBytes)
            switch model.pull {
            case let .running(progress):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloading \(recommended.name)")
                        Spacer()
                        Button("Cancel") { model.cancelPull() }
                    }
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                        Text("\(LocalModelFormat.bytes(progress.completedBytes)) of \(LocalModelFormat.bytes(progress.totalBytes)) · \(progress.status)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        ProgressView()
                        Text(progress.status.isEmpty ? "Starting" : progress.status)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            default:
                LabeledContent("Recommended for this Mac") {
                    Button("Download \(recommended.name) (\(size))") { model.startPull() }
                        .disabled(model.pullRefusal != nil)
                }
                note("\(recommended.name) is a \(size) download from ollama.com, under the \(recommended.licence) licence. It is picked for this Mac's \(model.memoryDescription) of memory. Nothing downloads until you press the button.")
                if let refusal = model.pullRefusal {
                    note(refusal, tint: .orange)
                }
                if case let .failed(why) = model.pull {
                    note(why, tint: .red)
                }
            }
        }
    }

    // MARK: - LM Studio

    private var lmStudioSection: some View {
        Section {
            serverRow("LM Studio", state: model.lmStudio, port: 1234)
            switch model.lmStudio {
            case .notInstalled:
                note("LM Studio runs language models on this Mac, and downloads them in its own window. Install it, start its local server, and this row finds it.")
                Button("Get LM Studio") { open("https://lmstudio.ai") }
            case .notRunning:
                note("LM Studio is installed but its local server is not running. Start it in LM Studio's Developer tab, or with `lms server start`, and this row finds it.")
            case let .running(models):
                if models.isEmpty {
                    note("LM Studio's server is running with no model loaded. Load one in LM Studio, and it appears here.")
                }
                ForEach(models) { item in modelRow(item, source: LMStudioAPI.source(for: item)) }
                if !models.isEmpty {
                    note("Baton plans for a 4,096 token context with LM Studio, which is its default, so longer tasks go to another source.")
                }
            case let .unexpected(why):
                note(why)
            case nil:
                EmptyView()
            }
        }
    }

    // MARK: - Kokoro

    private var kokoroSection: some View {
        Section {
            LabeledContent("Kokoro") {
                HStack(spacing: 6) {
                    if model.kokoroChecked {
                        Image(systemName: model.kokoroLocalVoices == nil ? "circle.dashed" : "checkmark.circle.fill")
                            .foregroundStyle(model.kokoroLocalVoices == nil ? Color.secondary : Color.green)
                        Text(model.kokoroLocalVoices.map { "Running on this Mac, \($0) voices" } ?? "Not running on this Mac")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            note(model.kokoroPlacement.summary(localVoices: model.kokoroLocalVoices))
            Button("How to Run Kokoro on This Mac") { showKokoroHelp = true }
        }
    }

    // MARK: - Saved

    private var savedSection: some View {
        Section {
            if model.saved.isEmpty {
                note("Nothing saved yet. Test a model above, and save it once it answers.")
            } else {
                ForEach(model.saved, id: \.id) { source in
                    HStack(spacing: 8) {
                        let answering = model.isAnswering(source)
                        Image(systemName: answering ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(answering ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                            Text(answering ? "Answering" : "Not responding")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { model.remove(source) }
                    }
                }
            }
        } header: {
            Text("Saved for documents")
        } footer: {
            Text("Document features try these in this order. Each one answered a test request before it was saved.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Rows

    private func serverRow(_ name: String, state: LocalServerState?, port: Int) -> some View {
        LabeledContent(name) {
            HStack(spacing: 6) {
                switch state {
                case nil:
                    ProgressView().controlSize(.small)
                case .notInstalled:
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Text("Not installed")
                case .notRunning:
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text("Not running")
                case let .running(models):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(models.count == 1 ? "Running, 1 model" : "Running, \(models.count) models")
                case .unexpected:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Something else is on port \(String(port))")
                }
            }
        }
    }

    private func modelRow(_ item: LocalModel, source: ModelSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.body.monospaced())
                    let facts = [item.parameterSize, item.quantization, item.sizeBytes.map(LocalModelFormat.bytes)].compactMap { $0 }
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                let test = model.tests[source.id]
                Button(test == nil ? "Test" : "Test Again") { Task { await model.test(source) } }
                    .disabled(test == .running)
                if model.saved.contains(where: { $0.id == source.id }) {
                    Text("Saved").foregroundStyle(.secondary)
                } else {
                    Button("Save") { model.save(source) }
                        .disabled(!(test?.passed ?? false))
                        .help("Save once it has answered a test")
                }
            }
            switch model.tests[source.id] {
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Asking \(item.name) for a short JSON answer").font(.caption).foregroundStyle(.secondary)
                }
            case let .passed(seconds):
                Label("Answered correctly in \(String(format: "%.1f", seconds)) s", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case let .failed(why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
    }

    private func note(_ text: String, tint: Color = .secondary) -> some View {
        Text(.init(text)).font(.callout).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - The model

@MainActor
@Observable
final class LocalModelsModel {
    enum TestState: Equatable {
        case running
        case passed(seconds: Double)
        case failed(String)

        var passed: Bool {
            if case .passed = self { return true }
            return false
        }
    }

    enum PullState: Equatable {
        case running(OllamaPullProgress)
        case failed(String)
    }

    static let ollamaBundleID = "com.electron.ollama"
    static let lmStudioBundleID = "ai.elementlabs.lmstudio"

    /// Nil until the first check has come back.
    private(set) var ollama: LocalServerState?
    private(set) var lmStudio: LocalServerState?
    private(set) var kokoroLocalVoices: Int?
    private(set) var kokoroChecked = false
    private(set) var kokoroPlacement = KokoroPlacement.none
    private(set) var saved: [ModelSource] = LocalModelSources.configuredSources()
    private(set) var tests: [String: TestState] = [:]
    private(set) var pull: PullState?
    private(set) var freeBytes: Int64?

    let recommended = RecommendedModel.forMac(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    @ObservationIgnored private var pullTask: Task<Void, Never>?

    /// No proxy, no cache: every answer here is about this Mac, right now.
    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    var everythingRunning: Bool {
        (ollama?.isRunning ?? false) && (lmStudio?.isRunning ?? false) && kokoroLocalVoices != nil
    }

    var memoryDescription: String {
        "\(ProcessInfo.processInfo.physicalMemory >> 30) GB"
    }

    var pullRefusal: String? {
        RecommendedModel.pullRefusal(downloadBytes: recommended.downloadBytes, freeBytes: freeBytes)
    }

    func refresh() async {
        async let ollamaProbe = Self.probe(OllamaAPI.tagsRequest())
        async let lmStudioProbe = Self.probe(LMStudioAPI.modelsRequest())
        async let kokoroProbe = Self.probe(KokoroAPI.voicesRequest())
        let (o, l, k) = await (ollamaProbe, lmStudioProbe, kokoroProbe)
        ollama = LocalServerState.detect(installed: Self.ollamaInstalled, probe: o, parse: OllamaAPI.parseTags)
        lmStudio = LocalServerState.detect(installed: Self.lmStudioInstalled, probe: l, parse: LMStudioAPI.parseModels)
        if case let .answered(status, body) = k, (200..<300).contains(status), let voices = try? KokoroAPI.parseVoices(body) {
            kokoroLocalVoices = voices.count
        } else {
            kokoroLocalVoices = nil
        }
        kokoroChecked = true
        kokoroPlacement = KokoroPlacement.classify(configuredBaseURL: SpeechConfig.kokoroBaseURL,
                                                   hasStoredHost: SpeechConfig.hasStoredHost(for: .kokoro))
        saved = LocalModelSources.configuredSources()
        freeBytes = Self.freeSpace()
    }

    /// Whether a saved source's server is up and still has its model. Judged from the latest
    /// detection, which is a request that just happened.
    func isAnswering(_ source: ModelSource) -> Bool {
        let state: LocalServerState? = switch source.baseURL {
        case LocalModelServers.ollamaBaseURL: ollama
        case LocalModelServers.lmStudioBaseURL: lmStudio
        default: nil
        }
        return state?.models.contains { $0.name == source.model } ?? false
    }

    // MARK: Test and save

    /// One small structured request through the same client the router uses, timed.
    func test(_ source: ModelSource) async {
        tests[source.id] = .running
        let start = ContinuousClock.now
        do {
            var request = try HTTPModelClient.request(for: source, system: LocalModelTest.system,
                                                      user: LocalModelTest.user, apiKey: nil, maxTokens: 64)
            request.timeoutInterval = LocalModelTest.timeout
            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                tests[source.id] = .failed("It answered with HTTP \(status).")
                return
            }
            let reply = try HTTPModelClient.text(from: data, provider: source.provider)
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if LocalModelTest.passed(reply) {
                tests[source.id] = .passed(seconds: seconds)
            } else {
                let shown = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
                tests[source.id] = .failed("It answered, but not with the JSON it was asked for: \(shown)")
            }
        } catch let error as URLError where error.code == .timedOut {
            tests[source.id] = .failed("It did not answer within \(Int(LocalModelTest.timeout)) seconds.")
        } catch {
            tests[source.id] = .failed("It did not answer: \(error.localizedDescription)")
        }
    }

    func save(_ source: ModelSource) {
        guard tests[source.id]?.passed == true else { return }
        LocalModelSources.save(source)
        saved = LocalModelSources.configuredSources()
    }

    func remove(_ source: ModelSource) {
        LocalModelSources.remove(id: source.id)
        saved = LocalModelSources.configuredSources()
    }

    // MARK: Pull

    func startPull() {
        guard pullTask == nil, pullRefusal == nil, let request = OllamaAPI.pullRequest(model: recommended.name) else { return }
        pull = .running(OllamaPullProgress())
        pullTask = Task { [weak self] in
            var progress = OllamaPullProgress()
            var lastShown = ContinuousClock.now
            do {
                let (bytes, response) = try await Self.session.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw OllamaPullProgress.Failure.server("HTTP \(status)") }
                for try await line in bytes.lines {
                    let before = progress.status
                    try progress.apply(line: line)
                    // Ollama reports many times a second; the bar needs a few.
                    if progress.status != before || ContinuousClock.now - lastShown > .milliseconds(200) {
                        self?.pull = .running(progress)
                        lastShown = .now
                    }
                }
                guard let self else { return }
                self.pull = progress.succeeded ? nil : .failed("The download stopped before Ollama said it was complete.")
            } catch {
                guard let self else { return }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    self.pull = nil
                } else {
                    self.pull = .failed("The download failed. \(error)")
                }
            }
            self?.pullTask = nil
            await self?.refresh()
        }
    }

    /// Closing the stream is what stops Ollama. What it already fetched stays in its cache, so
    /// pressing Download again picks up where this left off.
    func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        pull = nil
    }

    // MARK: This Mac

    nonisolated static func probe(_ request: URLRequest?) async -> LocalServerProbe {
        guard let request else { return .noAnswer("not a valid address") }
        do {
            let (data, response) = try await session.data(for: request)
            return .answered(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return .noAnswer(error.localizedDescription)
        }
    }

    static var ollamaInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ollamaBundleID) != nil
            || ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var lmStudioInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: lmStudioBundleID) != nil
            || FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/.lmstudio/bin/lms")
    }

    static func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func freeSpace() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Kokoro help

/// How to run Kokoro on this Mac (option B in the spec): Kokoro-FastAPI, natively, on the GPU.
/// Baton shows the commands and finds the server once it is up; it never runs them.
struct KokoroHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    static let commands = """
    brew install uv
    git clone https://github.com/remsky/Kokoro-FastAPI.git
    cd Kokoro-FastAPI && ./start-gpu_mac.sh
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run Kokoro on This Mac").font(.title2.bold())
            Text("Kokoro is the voice Baton reads books in. At home it usually runs on a server. To run it on this Mac instead, use Kokoro-FastAPI, which runs on the graphics processor of a Mac with Apple silicon.")
            Text("It needs Homebrew. In Terminal, run:")
            Text(Self.commands)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("The first start downloads the voice model, about 350 MB. Kokoro runs for as long as that Terminal window is open.")
            Text("Once it is running, Settings says so. Then set Kokoro under Services to \(LocalModelServers.kokoroBaseURL), and Baton reads with it.")
            Text("Baton never runs these commands for you.").foregroundStyle(.secondary)
            HStack {
                Button("Copy Commands") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.commands, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 520)
    }
}
