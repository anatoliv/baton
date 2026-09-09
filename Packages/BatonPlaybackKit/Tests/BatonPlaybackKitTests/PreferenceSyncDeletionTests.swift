import XCTest
@testable import BatonPlaybackKit

/// Clearing a setting, and deciding a conflict between two devices whose clocks disagree (S-F17).
///
/// Both halves were silent. Removing a synced key stamped a local timestamp, and then the push
/// loop skipped it because there was no value to encode, so the shared document kept the old value
/// for ever and the other device handed it straight back: resetting the EQ or clearing the agent
/// base URL on the phone came back from the Mac, with nothing anywhere saying why. And the
/// timestamps being compared were stamped independently on each device, so a Mac an hour ahead won
/// every argument about a key until the phone edited past that future time.
///
/// These run against `FakeGateway`, which is the real `/v1/state` contract rather than a stub that
/// always says yes: it holds the document, counts a revision on every write, refuses a write made
/// against a revision that has moved, and sends its own clock. A test that lets a push always
/// succeed cannot see a lost update, which is the defect the revision exists to close.
@MainActor
final class PreferenceSyncDeletionTests: XCTestCase {
    private let key = "tonebox.music.eq.preset"
    private let gatewayURL = URL(string: "http://gateway.test")!

    private var suites: [String] = []

    override func setUp() {
        super.setUp()
        FakeGateway.reset()
    }

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        FakeGateway.reset()
        super.tearDown()
    }

    /// One device, with its own settings store and its own session pointed at the fake gateway.
    private func device(_ name: String) -> (sync: PreferenceSync, defaults: UserDefaults) {
        let suite = "baton.prefsync.deletion.\(name).\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeGateway.self]
        let sync = PreferenceSync(defaults: defaults, deviceName: name,
                                  session: URLSession(configuration: configuration))
        return (sync, defaults)
    }

    /// One sync, asserted to have worked. A sync that quietly failed would make every assertion
    /// below it pass for the wrong reason.
    private func syncs(_ device: (sync: PreferenceSync, defaults: UserDefaults),
                       _ message: String = "the sync failed",
                       file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await device.sync.sync(gatewayURL: gatewayURL, token: "t")
        XCTAssertTrue(ok, message, file: file, line: line)
    }

    // MARK: - A deletion travels

    /// The finding, end to end and through a real round trip: clear a setting on one device and it
    /// must be cleared on the other, and stay cleared on the sync after that.
    func testClearingASettingOnOneDeviceClearsItOnTheOther() async {
        let mac = device("Mac")
        let phone = device("iPhone")

        mac.defaults.set("Bass Boost", forKey: key)
        mac.sync.noteLocalChange(key, at: Date(timeIntervalSinceNow: -120))
        await syncs(mac)

        await syncs(phone)
        XCTAssertEqual(phone.defaults.string(forKey: key), "Bass Boost",
                       "precondition: the phone has the Mac's value")

        // Cleared on the Mac.
        mac.defaults.removeObject(forKey: key)
        mac.sync.noteLocalChange(key, at: Date(timeIntervalSinceNow: -60))
        await syncs(mac)

        await syncs(phone)
        XCTAssertNil(phone.defaults.object(forKey: key), """
            The Mac cleared this setting and the phone still has it. The push had no value to \
            encode, so the deletion never left the Mac and the old value sits in the shared \
            document for ever.
            """)

        // And it stays cleared: a second sync must not resurrect it from the document.
        await syncs(phone)
        XCTAssertNil(phone.defaults.object(forKey: key), "the shared document handed the value back")
    }

    /// A device that never had the key must not start announcing that it was deleted. Absent with
    /// no local stamp is "no opinion", and a tombstone from it would clear the setting everywhere.
    func testADeviceThatNeverHadTheKeyPushesNoTombstone() async throws {
        let phone = device("iPhone")
        phone.defaults.set(4.0, forKey: "tonebox.navidrome.crossfade")
        phone.sync.noteLocalChange("tonebox.navidrome.crossfade")

        await syncs(phone)

        let document = try FakeGateway.decodedDocument()
        XCTAssertNil(document[key], "a key this device never held was announced as deleted")
    }

    /// The tombstone is written once. Re-stamping it on every sync would push a document every
    /// time two devices are both running, over a fact that has not changed.
    func testAnExistingTombstoneIsNotRewrittenOnEverySync() async throws {
        let mac = device("Mac")
        mac.defaults.set("Rock", forKey: key)
        mac.sync.noteLocalChange(key, at: Date(timeIntervalSinceNow: -120))
        await syncs(mac)

        mac.defaults.removeObject(forKey: key)
        mac.sync.noteLocalChange(key, at: Date(timeIntervalSinceNow: -60))
        await syncs(mac)
        let writes = FakeGateway.puts.count

        await syncs(mac)

        XCTAssertEqual(FakeGateway.puts.count, writes, "an unchanged document was pushed again")
    }

    /// Setting the value again after a deletion brings it back, which is the other half of a
    /// tombstone being a record rather than a permanent ban.
    func testSettingTheValueAgainAfterADeletionWins() async {
        let mac = device("Mac")
        mac.defaults.set("Rock", forKey: key)
        mac.sync.noteLocalChange(key, at: Date(timeIntervalSinceNow: -180))
        await syncs(mac)
        mac.defaults.removeObject(forKey: key)
        mac.sync.noteLocalChange(key, at: Date(timeIntervalSinceNow: -120))
        await syncs(mac)

        mac.defaults.set("Jazz", forKey: key)
        mac.sync.noteLocalChange(key, at: Date(timeIntervalSinceNow: -60))
        await syncs(mac)

        let phone = device("iPhone")
        await syncs(phone)
        XCTAssertEqual(phone.defaults.string(forKey: key), "Jazz")
    }

    // MARK: - A tombstone reaching a build that has never heard of one

    /// The stated risk of adding a field to `Entry`: a build without it must **ignore** the
    /// tombstone rather than adopt it as a value.
    ///
    /// That is why the tombstone carries an empty `value`. The old build decodes the entry happily
    /// — `Codable` skips keys it does not know, so the document does not become unreadable either
    /// — and then fails to read an empty property list and skips the key. It keeps its own copy of
    /// the setting, which is the safe direction, and the moment it is updated the deletion lands.
    func testATombstoneIsIgnoredByABuildThatDoesNotKnowTheField() throws {
        /// `Entry` exactly as builds before this change declared it.
        struct LegacyEntry: Codable {
            var value: Data
            var updatedAt: Date
            var device: String
        }

        let tombstone = PreferenceSync.Entry.tombstone(at: Date(), device: "Mac")
        let wire = try JSONEncoder().encode(tombstone)

        let legacy = try JSONDecoder().decode(LegacyEntry.self, from: wire)

        XCTAssertTrue(legacy.value.isEmpty, """
            A tombstone must carry no value. With one, an older build would adopt whatever it \
            decodes to and the deletion would arrive as a setting.
            """)
        XCTAssertThrowsError(
            try PropertyListSerialization.propertyList(from: legacy.value, options: [], format: nil),
            "the old build's adopt path reads this; it has to fail so the key is skipped")
    }

    /// And the same entry read by a build that *does* know the field is a deletion, not an empty
    /// value. Both readings come from the same bytes, which is the point.
    func testTheSameBytesAreADeletionToABuildThatKnowsTheField() throws {
        let wire = try JSONEncoder().encode(PreferenceSync.Entry.tombstone(at: Date(), device: "Mac"))

        let entry = try JSONDecoder().decode(PreferenceSync.Entry.self, from: wire)

        XCTAssertTrue(entry.isTombstone)
    }

    // MARK: - Clocks

    /// The clock half of the finding. A device an hour ahead used to win every conflict for a key
    /// until the other device edited past that future time, which for a wrongly set clock is
    /// hours of a setting refusing to stay changed.
    func testARemoteEntryStampedInTheFutureDoesNotBeatALaterLocalEdit() async throws {
        let now = Date()
        FakeGateway.document = try documentJSON([
            key: PreferenceSync.Entry(value: try plist("From the fast clock"),
                                      updatedAt: now.addingTimeInterval(3_600), device: "Mac"),
        ])

        let phone = device("iPhone")
        phone.defaults.set("Edited here", forKey: key)
        phone.sync.noteLocalChange(key, at: now)

        await syncs(phone)

        XCTAssertEqual(phone.defaults.string(forKey: key), "Edited here", """
            An entry stamped an hour into the future overwrote an edit made here now. The device \
            that pushed it has a clock that is wrong, which is not a reason for it to win.
            """)
        let document = try FakeGateway.decodedDocument()
        let pushed = try XCTUnwrap(document[key])
        XCTAssertEqual(try entryValue(pushed), "Edited here",
                       "the local edit did not replace the future entry, so it wins again next time")
    }

    /// A remote entry from the future still seeds a device that has never had an opinion about the
    /// key. Refusing it would leave a fresh phone with nothing rather than with a settled value.
    func testAFutureEntryStillSeedsADeviceWithNoOpinion() async throws {
        FakeGateway.document = try documentJSON([
            key: PreferenceSync.Entry(value: try plist("From the fast clock"),
                                      updatedAt: Date().addingTimeInterval(3_600), device: "Mac"),
        ])
        let phone = device("iPhone")

        await syncs(phone)

        XCTAssertEqual(phone.defaults.string(forKey: key), "From the fast clock")
    }

    /// What stops entries from the future arising in the first place: the shared document is
    /// written in the gateway's clock, so two devices that disagree about the time still order
    /// their edits the same way.
    func testEntriesArePushedInTheGatewaysClockNotTheDevices() async throws {
        // A gateway two hours ahead of this machine stands in for the ordinary case, which is this
        // machine being two hours behind the gateway. Only the difference matters.
        FakeGateway.serverTimeOffset = 7_200
        let stamp = Date(timeIntervalSinceNow: -30)
        let phone = device("iPhone")
        phone.defaults.set("Rock", forKey: key)
        phone.sync.noteLocalChange(key, at: stamp)

        await syncs(phone)

        let entry = try XCTUnwrap(try FakeGateway.decodedDocument()[key])
        XCTAssertEqual(entry.updatedAt.timeIntervalSince(stamp), 7_200, accuracy: 5, """
            The stamp went out in this device's clock. Two devices whose clocks differ then \
            compare numbers that mean different things, which is the conflict rule failing \
            silently.
            """)
    }

    // MARK: - The revision

    /// The lost update the revision exists to catch. The other device writes between this one's
    /// read and its push, so the merge was made against a document that is no longer there. The
    /// push must be refused and redone, not applied.
    func testAPushOverADocumentThatMovedIsRefusedAndTheMergeIsRedone() async throws {
        let peerKey = "tonebox.navidrome.crossfade"
        // The peer writes once, after this device has read and while it is merging.
        FakeGateway.afterFirstGet = {
            let entry = PreferenceSync.Entry(
                value: (try? PropertyListSerialization.data(fromPropertyList: 6.5, format: .binary,
                                                            options: 0)) ?? Data(),
                updatedAt: Date(), device: "Mac")
            FakeGateway.writeAsPeer(try! documentJSON([peerKey: entry]))
        }

        let phone = device("iPhone")
        phone.defaults.set("Rock", forKey: key)
        phone.sync.noteLocalChange(key)

        await syncs(phone, "a document that moved is a retry, not a failed sync")

        XCTAssertEqual(FakeGateway.refusals, 1, "the stale push was accepted")
        let document = try FakeGateway.decodedDocument()
        XCTAssertNotNil(document[peerKey], """
            The other device's write was replaced by a merge made before it happened. The PUT is a \
            whole-file replace, so this is how a setting disappears with both devices reporting a \
            successful sync.
            """)
        XCTAssertNotNil(document[key], "and this device's own edit still has to land")
    }

    /// A gateway older than this change sends no revision. The client must not start refusing to
    /// sync with it, because that would break every pair where only one side had been updated.
    func testAGatewayThatSendsNoRevisionStillSyncs() async throws {
        FakeGateway.sendsRevision = false
        let phone = device("iPhone")
        phone.defaults.set("Rock", forKey: key)
        phone.sync.noteLocalChange(key)

        await syncs(phone)

        XCTAssertEqual(FakeGateway.puts.count, 1)
        XCTAssertNil(FakeGateway.puts.first?.revision, "nothing to name, so nothing is named")
    }

}

// MARK: - Test helpers, at file scope so the fake gateway can use them too

private func plist(_ value: Any) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
}

private func entryValue(_ entry: PreferenceSync.Entry) throws -> String? {
    try PropertyListSerialization.propertyList(from: entry.value, options: [], format: nil) as? String
}

private func documentJSON(_ entries: [String: PreferenceSync.Entry]) throws -> Data {
    var object: [String: Any] = [:]
    for (key, entry) in entries {
        object[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
    }
    return try JSONSerialization.data(withJSONObject: object)
}

/// The `/v1/state` contract, as the gateway actually implements it.
///
/// A stub that answers 200 to everything cannot show a lost update, so this one keeps the
/// document, counts a revision on every write, refuses a write whose named revision has moved, and
/// carries its own clock. `afterFirstGet` is the seam for the race: it runs once, after this
/// device has read the document and before it pushes, which is exactly when the other device
/// writes.
final class FakeGateway: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedDocument = Data("{}".utf8)
    nonisolated(unsafe) private static var storedRevision = 0
    nonisolated(unsafe) private static var storedPuts: [(body: Data, revision: Int?)] = []
    nonisolated(unsafe) private static var storedRefusals = 0
    nonisolated(unsafe) private static var storedSendsRevision = true
    nonisolated(unsafe) private static var storedOffset: TimeInterval = 0
    nonisolated(unsafe) private static var storedAfterFirstGet: (@Sendable () -> Void)?

    static var document: Data {
        get { lock.withLock { storedDocument } }
        set { lock.withLock { storedDocument = newValue } }
    }

    /// Whether this gateway is new enough to stamp writes. False stands in for a deployment that
    /// has not been updated yet.
    static var sendsRevision: Bool {
        get { lock.withLock { storedSendsRevision } }
        set { lock.withLock { storedSendsRevision = newValue } }
    }

    /// How far this gateway's clock is from the machine running the test.
    static var serverTimeOffset: TimeInterval {
        get { lock.withLock { storedOffset } }
        set { lock.withLock { storedOffset = newValue } }
    }

    /// Runs once, immediately after the first GET is answered.
    static var afterFirstGet: (@Sendable () -> Void)? {
        get { lock.withLock { storedAfterFirstGet } }
        set { lock.withLock { storedAfterFirstGet = newValue } }
    }

    static var puts: [(body: Data, revision: Int?)] { lock.withLock { storedPuts } }
    static var refusals: Int { lock.withLock { storedRefusals } }

    /// The other device writing, which is what makes this device's in-flight merge stale.
    static func writeAsPeer(_ body: Data) {
        lock.withLock {
            storedDocument = body
            storedRevision += 1
        }
    }

    static func decodedDocument() throws -> [String: PreferenceSync.Entry] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: document) as? [String: Any])
        var entries: [String: PreferenceSync.Entry] = [:]
        for (key, value) in object {
            let data = try JSONSerialization.data(withJSONObject: value)
            entries[key] = try JSONDecoder().decode(PreferenceSync.Entry.self, from: data)
        }
        return entries
    }

    static func reset() {
        lock.withLock {
            storedDocument = Data("{}".utf8)
            storedRevision = 0
            storedPuts = []
            storedRefusals = 0
            storedSendsRevision = true
            storedOffset = 0
            storedAfterFirstGet = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        request.httpMethod == "PUT" ? put() : get()
    }

    private func get() {
        let (body, headers, after): (Data, [String: String], (@Sendable () -> Void)?) =
            Self.lock.withLock {
                let after = Self.storedAfterFirstGet
                Self.storedAfterFirstGet = nil
                return (Self.storedDocument, Self.headers(), after)
            }
        finish(status: 200, headers: headers, body: body)
        after?()
    }

    private func put() {
        // `URLSession` hands `URLProtocol` a stream-backed request, so the bytes are in
        // `httpBodyStream` rather than `httpBody`.
        let body = request.httpBody ?? Self.readStream(request.httpBodyStream) ?? Data()
        let named = request.value(forHTTPHeaderField: PreferenceSync.revisionHeader).flatMap(Int.init)

        let (status, headers): (Int, [String: String]) = Self.lock.withLock {
            Self.storedPuts.append((body, named))
            if let named, named != Self.storedRevision {
                Self.storedRefusals += 1
                return (409, Self.headers())
            }
            Self.storedRevision += 1
            Self.storedDocument = body
            return (200, Self.headers())
        }
        finish(status: status, headers: headers, body: Data(#"{"ok":true}"#.utf8))
    }

    /// Call with the lock already held.
    private static func headers() -> [String: String] {
        guard storedSendsRevision else { return [:] }
        return [
            PreferenceSync.revisionHeader: String(storedRevision),
            PreferenceSync.serverTimeHeader:
                String(format: "%.3f", Date().timeIntervalSince1970 + storedOffset),
        ]
    }

    private func finish(status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
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
