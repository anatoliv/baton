import BatonShareKit
import BatonSubsonicKit
import Foundation
import UIKit

// The real engine references this constant only in its default provider closure.
// This host always supplies its own synthetic provider and never links SongSharing.
enum SongSharing { static let secretAccount = "baton.share.installSecret" }
// Module-local refusal also protects an accidentally omitted explicit provider.
// It never resolves imported Keychain access or owner preferences.
enum NavidromeKeychain { static func secret(account: String) -> String? { nil } }

@MainActor
enum UploadProbeStorage {
    enum Refusal: Error { case isolation, alreadyStarted }
    static var suite: String {
        get throws {
            guard Bundle.main.bundleIdentifier == "io.tonebox.baton",
                  Bundle.main.object(forInfoDictionaryKey: "BatonBackgroundUploadProbe") as? Bool == true,
                  let value = Bundle.main.object(forInfoDictionaryKey: "BatonBackgroundUploadProbeSuite") as? String,
                  value.hasPrefix("probe-upload-"), (14...53).contains(value.count),
                  value.unicodeScalars.allSatisfy({ "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".unicodeScalars.contains($0) })
            else { throw Refusal.isolation }
            return value
        }
    }
    static var root: URL {
        get throws {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            return support.appendingPathComponent("Baton Probes", isDirectory: true)
                .appendingPathComponent(try suite, isDirectory: true)
                .appendingPathComponent("BackgroundUploadPhysical", isDirectory: true)
        }
    }
    static func directory(_ name: String) throws -> URL {
        guard ["success", "failure"].contains(name) else { throw Refusal.isolation }
        return try root.appendingPathComponent(name, isDirectory: true)
    }
    static func sessionID(_ name: String) throws -> String {
        _ = try directory(name)
        return "io.tonebox.baton.probe.share-uploads." + (try suite) + "." + name
    }
    static func create(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var parent = try root, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try parent.setResourceValues(values)
    }
    static func write(_ data: Data, _ url: URL) throws {
        try BackgroundShareUploadStore.writeProtected(data, to: url)
    }
}

@main
@MainActor
final class BackgroundUploadPhysicalHost: UIResponder, UIApplicationDelegate {
    struct Event: Codable {
        var date: Date
        var kind: String
        var launchGeneration: String
        var jobFingerprints: [String]
        var receiptFingerprints: [String]
        var applicationState: String
        var pendingJobs: Int
        var records: Int
        var failures: Int
        var receipts: Int
        var progress: Double?
        var serverReady: Int?
        var serverPending: Int?
        var serverMatchesLedger: Bool?
    }
    var window: UIWindow?
    private var engines: [String: BackgroundShareUploadEngine] = [:]
    private var events: [String: [Event]] = [:]
    private let status = UILabel()
    private let launchGeneration = UUID().uuidString
    private let origin = URL(string: "https://dev.batonmusic.app")!

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard (try? UploadProbeStorage.suite) != nil else { return false }
        // A system relaunch has no inherited launchEnvironment. Only this signed
        // probe's baked namespace and its explicit-start marker authorize reattachment.
        for name in ["success", "failure"] {
            if let directory = try? UploadProbeStorage.directory(name),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent("started.json").path) {
                do { let engine = try attach(name); capture(name, "launch-restoration"); Task { await engine.restore() } }
                catch { status.text = "Probe restoration refused; original synthetic state retained." }
            }
        }
        return true
    }
    func connect(_ scene: UIWindowScene) {
        guard (try? UploadProbeStorage.suite) != nil else { return }
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        status.numberOfLines = 0
        status.text = "Synthetic background upload probe. No upload starts automatically."
        let success = UIButton(type: .system), failure = UIButton(type: .system), verify = UIButton(type: .system)
        success.setTitle("Start one background upload", for: .normal)
        failure.setTitle("Start one rejected-payload case", for: .normal)
        verify.setTitle("Verify synthetic receipts", for: .normal)
        success.addTarget(self, action: #selector(startSuccess), for: .touchUpInside)
        failure.addTarget(self, action: #selector(startFailure), for: .touchUpInside)
        verify.addTarget(self, action: #selector(verifyReceipts), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, success, failure, verify])
        stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                                     stack.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
                                     stack.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)])
        window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
    }
    func probeDidEnterBackground() {
        for name in engines.keys { capture(name, "did-enter-background") }
    }
    func probeWillEnterForeground() {
        for name in engines.keys { capture(name, "will-enter-foreground") }
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard let name = ["success", "failure"].first(where: { (try? UploadProbeStorage.sessionID($0)) == identifier }),
              let directory = try? UploadProbeStorage.directory(name),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("started.json").path),
              let engine = try? attach(name) else { completionHandler(); return }
        capture(name, "system-background-session-events")
        engine.backgroundCompletionHandler = { [weak self] in
            self?.capture(name, "system-background-events-finished"); completionHandler()
        }
        Task { await engine.restore() }
    }
    private func attach(_ name: String) throws -> BackgroundShareUploadEngine {
        if let existing = engines[name] { return existing }
        let directory = try UploadProbeStorage.directory(name)
        let bearerURL = directory.appendingPathComponent("synthetic-bearer.json")
        // This is only the probe-created device-local bearer, never Keychain or owner data.
        let provider: () -> String? = {
            guard let data = try? Data(contentsOf: bearerURL) else { return nil }
            return try? JSONDecoder().decode(String.self, from: data)
        }
        let configuration = URLSessionConfiguration.background(withIdentifier: try UploadProbeStorage.sessionID(name))
        let engine = BackgroundShareUploadEngine(directory: directory.appendingPathComponent("jobs"),
            ledgerURL: directory.appendingPathComponent("ledger.json"),
            backgroundConfiguration: configuration, secretProvider: provider)
        engine.onCreated = { [weak self, weak engine] in
            if name == "failure", let engine, let job = try? engine.store.load().jobs.first {
                // Intentionally corrupt only this synthetic sealed file before PUT.
                do {
                    let file = engine.store.file(job.id, kind: "audio")
                    var body = try Data(contentsOf: file); body[0] ^= 1
                    try engine.store.write(body, to: file)
                } catch { self?.status.text = "Synthetic fault setup failed." }
            }
            self?.capture(name, "create-acknowledged")
        }
        engine.onProgress = { [weak self] value in self?.capture(name, "upload-progress", progress: value) }
        engine.onLedgerChanged = { [weak self] _ in self?.capture(name, "ledger-committed") }
        engine.onPendingChanged = { [weak self] _ in self?.capture(name, "pending-changed") }
        engines[name] = engine
        if let data = try? Data(contentsOf: directory.appendingPathComponent("evidence.json")),
           let saved = try? JSONDecoder().decode([Event].self, from: data) { events[name] = saved }
        return engine
    }
    @objc private func startSuccess() { start("success") }
    @objc private func startFailure() { start("failure") }
    private func start(_ name: String) {
        Task {
            do {
                let directory = try UploadProbeStorage.directory(name), marker = directory.appendingPathComponent("started.json")
                guard !FileManager.default.fileExists(atPath: marker.path) else { throw UploadProbeStorage.Refusal.alreadyStarted }
                // The ordinary app uses the same unprivileged client-side identity shape.
                // No live network action happens until this explicit one-time button.
                try UploadProbeStorage.create(directory)
                let bearer = ShareClient.newSecret()
                try UploadProbeStorage.write(JSONEncoder().encode(bearer), directory.appendingPathComponent("synthetic-bearer.json"))
                let prepared = try PreparedShare.make(audio: Self.syntheticWAV(),
                    metadata: ShareMetadata(title: "Synthetic background upload", artist: "Baton probe", durationSeconds: 300),
                    isPrivate: true, expiresInSeconds: 86400, playCap: 3,
                    client: ShareClientInfo(platform: "ios", appVersion: "physical-probe"))
                try UploadProbeStorage.write(Data("{\"explicitSyntheticStart\":true}".utf8), marker)
                let engine = try attach(name); capture(name, "explicit-start")
                status.text = "Uploading synthetic payload. Home/lock counts only while a job is pending."
                _ = try await engine.enqueue(prepared, client: ShareClient(base: origin, secret: bearer),
                    songID: "synthetic-background-upload", title: "Synthetic background upload", artist: "Baton probe")
                status.text = "Synthetic upload completed. Verify receipts."
            } catch { status.text = "Case stopped. Synthetic evidence retained; do not repeat automatically." }
        }
    }
    private func capture(_ name: String, _ kind: String, progress: Double? = nil,
                         serverReady: Int? = nil, serverPending: Int? = nil, serverMatchesLedger: Bool? = nil) {
        guard let engine = engines[name] else { return }
        let ledger = ShareLedger.load(from: engine.store.ledgerURL)
        let loaded = try? engine.store.load().jobs
        let receipts = BackgroundShareUploadStore.receipts(at: engine.store.ledgerURL)
        let state = UIApplication.shared.applicationState
        let event = Event(date: Date(), kind: kind, launchGeneration: launchGeneration,
            jobFingerprints: (loaded ?? []).map { ShareHash.sha256Hex(Data($0.id.uuidString.utf8)) }.sorted(),
            receiptFingerprints: receipts.map { ShareHash.sha256Hex(Data($0.utf8)) }.sorted(), applicationState: state == .active ? "active" : state == .background ? "background" : "inactive",
            pendingJobs: loaded?.count ?? -1, records: ledger.records.count,
            failures: ledger.pendingFailures.count, receipts: receipts.count,
            progress: progress, serverReady: serverReady, serverPending: serverPending, serverMatchesLedger: serverMatchesLedger)
        events[name, default: []].append(event)
        do { try UploadProbeStorage.write(JSONEncoder().encode(events[name]), try UploadProbeStorage.directory(name).appendingPathComponent("evidence.json")) }
        catch { status.text = "Evidence unavailable; physical result is inconclusive." }
    }
    @objc private func verifyReceipts() {
        Task {
            for name in engines.keys {
                do {
                    let directory = try UploadProbeStorage.directory(name)
                    let bearer = try JSONDecoder().decode(String.self, from: Data(contentsOf: directory.appendingPathComponent("synthetic-bearer.json")))
                    await engines[name]?.restore()
                    let summaries = try await ShareClient(base: origin, secret: bearer, session: URLSession(configuration: .ephemeral)).list()
                    let ledger = ShareLedger.load(from: engines[name]!.store.ledgerURL)
                    let readyIDs = Set(summaries.filter { $0.status == .ready }.map(\.id))
                    capture(name, "server-owner-list", serverReady: summaries.filter { $0.status == .ready }.count,
                            serverPending: summaries.filter { $0.status == .pending }.count,
                            serverMatchesLedger: readyIDs == Set(ledger.records.map(\.id)))
                } catch { status.text = "Synthetic ownership read unavailable; do not claim completion." }
            }
        }
    }
    private static func syntheticWAV() -> Data {
        // 300 seconds of silent 22050Hz mono PCM16, generated in memory only.
        let count: UInt32 = 300 * 22050 * 2
        var bytes = Data()
        func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
        text("RIFF"); u32(count + 36); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(22050); u32(44100); u16(2); u16(16)
        text("data"); u32(count); bytes.append(Data(repeating: 0, count: Int(count)))
        return bytes
    }
}

/// The current UIKit SDK requires scene lifecycle, including for this isolated host.
@MainActor
final class BackgroundUploadProbeScene: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let host = UIApplication.shared.delegate as? BackgroundUploadPhysicalHost else { return }
        host.connect(scene)
    }
    func sceneDidEnterBackground(_ scene: UIScene) {
        (UIApplication.shared.delegate as? BackgroundUploadPhysicalHost)?
            .probeDidEnterBackground()
    }
    func sceneWillEnterForeground(_ scene: UIScene) {
        (UIApplication.shared.delegate as? BackgroundUploadPhysicalHost)?
            .probeWillEnterForeground()
    }
}
