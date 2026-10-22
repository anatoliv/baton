import AppKit
import BatonAgentKit
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import Observation

/// Documents sent from the iPhone with "Send to my Mac", waiting to be imported here.
///
/// The phone parks the original on the home gateway (`PendingImportRelay`); this Mac picks it up
/// at launch, when Baton becomes active, and every minute while Baton is active, but only while
/// **Documents** is on. Each one opens in the import sheet in turn, and while a sheet is open the
/// rest wait in a short list at the top of Clippings.
///
/// - **Import** (Make Audiobook) and **Discard** remove it here and on the gateway.
/// - **Not Now** keeps it: it stays in the list, held by this Mac, and does not open again by
///   itself. That is why the gateway copy stays too; nothing is lost if this Mac's copy is.
///
/// - A document the gateway already removed (its fourteen-day limit, or its total cap) never
///   arrives. It is listed as "didn't arrive, send it again" and finished on the gateway at
///   once, so its record is not asked for every minute.
///
/// Two Macs never both take one: the relay's claim decides (see `PendingImportRelay`).
@MainActor
@Observable
final class DocumentInbox {
    struct Item: Codable, Equatable, Identifiable {
        let record: PendingImport
        /// The document on this Mac, or nil for a link.
        let file: URL?
        /// "Not Now": listed, not opened by itself again.
        var notNow = false
        /// The record came and its document did not: listed until dismissed, never opened.
        /// Optional so an inbox saved before it existed still loads.
        var missing: Bool?

        var isMissing: Bool { missing == true }

        var id: String { record.id }
        /// What the import sheet reads: the file, or the page.
        var source: URL? { file ?? record.link.flatMap(URL.init(string:)) }
    }

    /// Everything picked up and not yet imported or discarded, oldest first.
    private(set) var items: [Item] = []
    /// Bumped each time something new arrives, so the window can bring Clippings forward.
    private(set) var arrivals = 0

    /// The next one to open by itself.
    var nextOffer: Item? { items.first { !$0.notNow && !$0.isMissing } }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let documentsOn: @MainActor () -> Bool
    @ObservationIgnored private let relay: @MainActor () -> PendingImportRelay?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pickingUp = false
    /// Imported or discarded here, and still to be removed from the gateway. Kept on disk, so a
    /// gateway that was away when the person decided cannot hand the same document back later.
    @ObservationIgnored private var finished: Set<String>
    @ObservationIgnored private var removing: Set<String> = []
    /// How many times the gateway was asked, for the tests of when it is asked.
    @ObservationIgnored private(set) var pickups = 0

    init(directory: URL = BatonStorage.supportSubdirectory("Inbox"),
         documentsOn: @escaping @MainActor () -> Bool,
         relay: @escaping @MainActor () -> PendingImportRelay? = DocumentInbox.configuredRelay,
         pollInterval: Duration = .seconds(60),
         isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false }) {
        self.directory = directory
        self.documentsOn = documentsOn
        self.relay = relay
        self.pollInterval = pollInterval
        self.isAppActive = isAppActive
        items = Self.load(from: directory)
        finished = Self.loadFinished(from: directory)
    }

    /// The gateway as Settings configures it, the same pair books and kept readings use.
    ///
    /// None for a probe or test instance (`BATON_DEBUG_PREFERENCE_SYNC=off`, DEBUG only): one
    /// pointed at the household gateway would otherwise claim a document the person sent to
    /// their own Mac, and hold it where nobody looks.
    static func configuredRelay() -> PendingImportRelay? {
        if let relay = debugRelay() { return relay }
        guard !PreferenceSyncScheduler.isSwitchedOff() else { return nil }
        // Never the token over plain HTTP to an address off the home network.
        guard let gateway = BearerGateway.configured() else { return nil }
        return PendingImportRelay(files: GatewayFiles(gatewayURL: gateway.url, token: gateway.token))
    }

    /// DEBUG only, and nil in a release build: a probe's own relay, so the "Sent from" sheet and
    /// list can be walked on screen against a throwaway gateway on this Mac.
    /// `BATON_DEBUG_INBOX_GATEWAY_URL` and `BATON_DEBUG_INBOX_GATEWAY_TOKEN`, environment variables
    /// rather than launch arguments. Loopback addresses only, so a probe can never be
    /// pointed at the household gateway this way.
    static func debugRelay(environment: [String: String] = ProcessInfo.processInfo.environment) -> PendingImportRelay? {
        #if DEBUG
        let raw = (environment["BATON_DEBUG_INBOX_GATEWAY_URL"] ?? "").trimmingCharacters(in: .whitespaces)
        let token = (environment["BATON_DEBUG_INBOX_GATEWAY_TOKEN"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !token.isEmpty, let url = URL(string: raw),
              let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        return PendingImportRelay(files: GatewayFiles(gatewayURL: url, token: token))
        #else
        return nil
        #endif
    }

    // MARK: - When to ask

    /// Ask now, then on every activation and every `pollInterval` while Baton is active.
    func start() {
        guard observers.isEmpty else { return }
        Task { await pickUp() }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPolling() }
        })
        if isAppActive() { startPolling() }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        stopPolling()
    }

    func becameActive() {
        Task { await pickUp() }
        startPolling()
    }

    /// A light loop: one listing a minute, only while Baton is in front and Documents is on.
    func startPolling() {
        guard poller == nil else { return }
        poller = Task { @MainActor [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                guard self.isAppActive() else { self.stopPolling(); return }
                await self.pickUp()
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    var isPolling: Bool { poller != nil }

    // MARK: - Picking up

    /// Claim what the phone sent and bring each new one down. Quiet on failure: a gateway that
    /// is away now is asked again in a minute.
    func pickUp() async {
        guard documentsOn(), !pickingUp, let relay = relay() else { return }
        pickingUp = true
        defer { pickingUp = false }
        pickups += 1
        for id in finished where !removing.contains(id) { await removeFromGateway(id) }
        do {
            // Ids name folders here, so one the gateway's own rule would refuse ("..") is never used.
            let held = try await relay.claim(as: deviceID).filter(FileStoreID.isValid)
            var arrived = 0
            for id in held where !items.contains(where: { $0.id == id }) && !finished.contains(id) {
                do {
                    let fetched = try await relay.fetch(id, into: directory.appendingPathComponent(id, isDirectory: true))
                    items.append(Item(record: fetched.record, file: fetched.file))
                    arrived += 1
                    documentsLog.notice("picked up a document sent from \(fetched.record.fromDevice, privacy: .private)")
                } catch let PendingImportRelay.FetchError.documentMissing(record) {
                    // It will never arrive: say so here, and clear the record on the gateway.
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
                    items.append(Item(record: record, file: nil, notNow: true, missing: true))
                    finished.insert(id)
                    arrived += 1
                    documentsLog.error("a document sent from \(record.fromDevice, privacy: .private) was gone from the gateway")
                } catch {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
                    documentsLog.error("could not pick up a sent document: \(error.localizedDescription, privacy: .public)")
                }
            }
            if arrived > 0 {
                save()
                arrivals += 1
            }
            for id in finished where !removing.contains(id) { await removeFromGateway(id) }
        } catch {
            documentsLog.error("could not ask the gateway for sent documents: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - What the person decided

    /// "Not Now": keep it, listed, and stop offering it by itself.
    func notNow(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].notNow = true
        save()
    }

    /// Open it again from the list: it becomes the next offer.
    func reopen(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.notNow = false
        items.insert(item, at: 0)
        save()
    }

    /// Imported or discarded: gone here at once, and from the gateway as soon as it answers.
    /// A gateway that is away keeps its copy until this Mac asks again; it is still this Mac's.
    func finish(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        finished.insert(id)
        save()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
        Task { await removeFromGateway(id) }
    }

    /// Remove a finished one from the gateway; on failure it stays in `finished` and the next
    /// pickup tries again.
    func removeFromGateway(_ id: String) async {
        guard let relay = relay(), !removing.contains(id) else { return }
        removing.insert(id)
        defer { removing.remove(id) }
        do {
            try await relay.finish(id)
            finished.remove(id)
            save()
        } catch {
            documentsLog.error("could not remove a sent document from the gateway: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Wait, up to two seconds, for the gateway removals to finish (tests).
    func settle() async {
        for _ in 0 ..< 200 where !finished.isEmpty || !removing.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    var awaitingRemoval: Set<String> { finished }

    // MARK: - Storage

    /// This Mac's own id for claims: a file in the inbox folder, so it never syncs to another
    /// Mac the way a preference might, and two Macs never share one.
    var deviceID: String {
        let url = directory.appendingPathComponent("device-id")
        if let id = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           FileStoreID.isValid(id) {
            return id
        }
        let id = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(id.utf8).write(to: url, options: .atomic)
        return id
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.inbox.encode(items) {
            try? data.write(to: directory.appendingPathComponent("inbox.json"), options: .atomic)
        }
        if let data = try? JSONEncoder.inbox.encode(finished.sorted()) {
            try? data.write(to: directory.appendingPathComponent("finished.json"), options: .atomic)
        }
    }

    private static func loadFinished(from directory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("finished.json")),
              let ids = try? JSONDecoder.inbox.decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    private static func load(from directory: URL) -> [Item] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("inbox.json")),
              let items = try? JSONDecoder.inbox.decode([Item].self, from: data) else { return [] }
        // A document whose file has gone is not worth offering.
        return items.filter { $0.file.map { FileManager.default.fileExists(atPath: $0.path) } ?? true }
    }
}

/// The gateway's id rule (hex and dashes), for the one id this Mac makes up and keeps, and for
/// the ids the gateway hands back before they become folder names.
private enum FileStoreID {
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { "0123456789abcdef-".contains($0) }
    }
}

private extension JSONEncoder {
    static var inbox: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var inbox: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
