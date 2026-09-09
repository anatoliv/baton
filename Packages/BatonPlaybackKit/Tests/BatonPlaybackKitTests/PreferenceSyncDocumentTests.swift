import XCTest
@testable import BatonPlaybackKit

/// What happens when the shared settings document is not what this build expects.
///
/// This is the one that could delete somebody's data. The whole document used to be a single
/// `try?`: `decode([String: Entry].self) ?? [:]`. A decode failure therefore produced exactly the
/// same value as a gateway nobody had ever synced to, and the sync that followed found every key
/// absent, decided it had something to say about all of them, and PUT its whole state. The PUT is
/// a whole-file replace on the gateway, so the other device's podcast unsubscribes, friend-memory
/// ledger and clipping ledger went with it (S-F1).
///
/// The trigger did not have to be exotic. A truncated 200 body does it today, and a newer build
/// adding a required field to `Entry` does it deterministically, because an all-or-nothing
/// dictionary decode fails on one bad element.
@MainActor
final class PreferenceSyncDocumentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "baton.prefsync.doc.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        GatewayStub.reset()
    }

    override func tearDown() {
        GatewayStub.reset()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeSync(device: String = "Mac") -> PreferenceSync {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayStub.self]
        return PreferenceSync(defaults: defaults, deviceName: device,
                              session: URLSession(configuration: configuration))
    }

    /// The finding, end to end: an unparseable 200 must result in **no PUT at all**.
    func testAnUnparseableDocumentPushesNothing() async {
        GatewayStub.body = Data("this is not the document you are looking for".utf8)
        let sync = makeSync()
        defaults.set("Bass Boost", forKey: "tonebox.music.eq.preset")
        sync.noteLocalChange("tonebox.music.eq.preset")

        let ok = await sync.sync(gatewayURL: URL(string: "http://gateway.test")!, token: "t")

        XCTAssertFalse(ok, "a document that cannot be read is a failed sync, reported as one")
        XCTAssertEqual(GatewayStub.puts.count, 0, """
            The shared document could not be read, and this device pushed its own state over it \
            anyway. The PUT is a whole-file replace, so that is the other device's ledgers gone.
            """)
    }

    /// And the case it must stay distinct from: `{}` is the first device's honest answer, and it
    /// still seeds. A fix that refused to push on an empty document would break every new setup.
    func testAnEmptyDocumentStillSeeds() async {
        GatewayStub.body = Data("{}".utf8)
        let sync = makeSync()
        defaults.set("Bass Boost", forKey: "tonebox.music.eq.preset")
        sync.noteLocalChange("tonebox.music.eq.preset")

        let ok = await sync.sync(gatewayURL: URL(string: "http://gateway.test")!, token: "t")

        XCTAssertTrue(ok)
        XCTAssertEqual(GatewayStub.puts.count, 1, "the first device to sync must be able to seed")
    }

    /// An empty body means the same thing as `{}`: a gateway can answer a never-written state with
    /// nothing at all, and treating that as unreadable would leave a fresh install unable to seed
    /// while reporting a failure it could do nothing about.
    func testAnEmptyBodyIsTreatedAsAnEmptyDocument() throws {
        XCTAssertTrue(try PreferenceSync.decodeDocument(Data()).isEmpty)
        XCTAssertTrue(try PreferenceSync.decodeDocument(Data("  \n ".utf8)).isEmpty)
    }

    /// One entry written in a shape this build does not understand must cost that entry, not the
    /// other fifteen. It must also come back untouched, so an older build rewriting the document
    /// does not strip what a newer one wrote.
    func testAnUnreadableEntryIsPreservedAndTheRestStillSync() async throws {
        let good = try Self.entryJSON(value: "Rock", updatedAt: Date(timeIntervalSince1970: 1_000))
        let document: [String: Any] = [
            "tonebox.music.eq.preset": good,
            // The shape a newer build might write: an object that is not an `Entry`.
            "baton.agent.model": ["schema": 2, "payload": ["model": "some-newer-thing"]],
        ]
        GatewayStub.body = try JSONSerialization.data(withJSONObject: document)

        let sync = makeSync()
        defaults.set(4.0, forKey: "tonebox.navidrome.crossfade")
        sync.noteLocalChange("tonebox.navidrome.crossfade")

        let ok = await sync.sync(gatewayURL: URL(string: "http://gateway.test")!, token: "t")
        XCTAssertTrue(ok, "one entry this build cannot read is not a reason to stop syncing")

        let pushed = try XCTUnwrap(GatewayStub.puts.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: pushed) as? [String: Any])

        XCTAssertNotNil(object["tonebox.navidrome.crossfade"], "the readable keys still sync")
        let preserved = try XCTUnwrap(object["baton.agent.model"] as? [String: Any])
        XCTAssertEqual(preserved["schema"] as? Int, 2,
                       "the entry this build could not read was rewritten or dropped")
        XCTAssertEqual((preserved["payload"] as? [String: Any])?["model"] as? String,
                       "some-newer-thing")
        // And the readable entry the other device wrote is still there.
        XCTAssertNotNil(object["tonebox.music.eq.preset"])
    }

    /// The same key, from the other direction: this device must not seed over an entry it cannot
    /// read. Absent means "nobody has said anything and seeding is right"; unreadable means
    /// "somebody said something", and overwriting it is the loss rather than the fix.
    func testThisDeviceDoesNotPushOverAKeyItCannotRead() async throws {
        GatewayStub.body = try JSONSerialization.data(withJSONObject: [
            "tonebox.music.eq.preset": ["schema": 2, "payload": "newer"],
        ])
        let sync = makeSync()
        defaults.set("Bass Boost", forKey: "tonebox.music.eq.preset")
        sync.noteLocalChange("tonebox.music.eq.preset", at: Date())

        _ = await sync.sync(gatewayURL: URL(string: "http://gateway.test")!, token: "t")

        // No push at all is also a correct answer here; what must not happen is a push that
        // replaces the entry.
        guard let pushed = GatewayStub.puts.first else { return }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: pushed) as? [String: Any])
        let entry = try XCTUnwrap(object["tonebox.music.eq.preset"] as? [String: Any])
        XCTAssertEqual(entry["schema"] as? Int, 2,
                       "this device replaced an entry it admits it cannot read")
    }

    /// `check` used to answer "Reachable. Nothing shared yet" for an unreadable document, which is
    /// the sync's own mistake told to the owner's face. It is also the screen someone looks at
    /// when they are already suspicious that sync is misbehaving.
    func testCheckDoesNotCallAnUnreadableDocumentAnEmptyOne() async {
        GatewayStub.body = Data("not json".utf8)
        let sync = makeSync()

        let result = await sync.check(gatewayURL: URL(string: "http://gateway.test")!, token: "t")

        switch result {
        case .ok: XCTFail("an unreadable document reported as a healthy, empty gateway")
        case .rejected: XCTFail("that is a token problem, which this is not")
        case let .failed(why): XCTAssertTrue(why.contains("could not be read"), why)
        }
    }

    private static func entryJSON(value: String, updatedAt: Date) throws -> [String: Any] {
        let plist = try PropertyListSerialization.data(fromPropertyList: value, format: .binary,
                                                       options: 0)
        let entry = PreferenceSync.Entry(value: plist, updatedAt: updatedAt, device: "iPhone")
        let encoded = try JSONEncoder().encode(entry)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    }
}

// MARK: - The observer is taken off (S-F17)

@MainActor
final class PreferenceSyncObserverTests: XCTestCase {
    /// The leak had no symptom: the block captures `self` weakly, so after the object is gone it
    /// wakes on every `UserDefaults` change, finds nil, and does nothing. Forever, once per
    /// instance ever built. Counting the registrations is the only way to see it.
    func testTheObserverIsRemovedWhenTheSyncGoesAway() {
        let suite = "baton.prefsync.observer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let before = PreferenceSync.liveObservationCount
        do {
            let sync = PreferenceSync(defaults: defaults, deviceName: "Mac")
            sync.startObservingChanges()
            XCTAssertEqual(PreferenceSync.liveObservationCount, before + 1,
                           "precondition: it is observing")
        }

        XCTAssertEqual(PreferenceSync.liveObservationCount, before,
                       "the observer outlived the object that registered it")
    }

    /// Stopping explicitly must not then double-count when `deinit` runs.
    func testStoppingAndThenDeallocatingCountsOnce() {
        let suite = "baton.prefsync.observer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let before = PreferenceSync.liveObservationCount
        do {
            let sync = PreferenceSync(defaults: defaults, deviceName: "Mac")
            sync.startObservingChanges()
            sync.stopObservingChanges()
        }

        XCTAssertEqual(PreferenceSync.liveObservationCount, before)
    }
}

/// A gateway that answers whatever the test put in `body`, and records every PUT.
///
/// Recording the PUTs is the point: the finding is not "the wrong thing was pushed", it is that
/// **anything at all** was pushed over a document nobody could read.
final class GatewayStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedBody = Data("{}".utf8)
    nonisolated(unsafe) private static var storedPuts: [Data] = []

    static var body: Data {
        get { lock.lock(); defer { lock.unlock() }; return storedBody }
        set { lock.lock(); defer { lock.unlock() }; storedBody = newValue }
    }

    static var puts: [Data] {
        lock.lock(); defer { lock.unlock() }; return storedPuts
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        storedBody = Data("{}".utf8)
        storedPuts = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if request.httpMethod == "PUT" {
            // `URLSession` hands `URLProtocol` a stream-backed request, so `httpBody` is nil and
            // the bytes are in `httpBodyStream`. Reading the wrong one records every PUT as empty
            // and passes the "no PUT" assertion above for entirely the wrong reason.
            let recorded = request.httpBody ?? Self.readStream(request.httpBodyStream) ?? Data()
            Self.lock.lock()
            Self.storedPuts.append(recorded)
            Self.lock.unlock()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "PUT" { client?.urlProtocol(self, didLoad: Self.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
