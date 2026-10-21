@testable import BatonShareKit
import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor ReceiverStub: ShareReceiverTransport {
    var responses: [ShareReceiverResponse]
    var requests: [URLRequest] = []
    init(_ responses: [ShareReceiverResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ShareReceiverResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return responses.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
}

private final class ReceiverURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseLength: Int? = nil
    nonisolated(unsafe) static var chunks: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let headers = Self.responseLength.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ShareReceiverTests: XCTestCase {
    private let id = Base64URL.encode(Data(repeating: 3, count: 16))
    private let key = Data(repeating: 4, count: 16)
    private func payload(preview: ShareMetadata? = ShareMetadata(title: "Song", artist: "Artist", durationSeconds: 35),
                         encryptedMeta: String? = nil, bytes: Int = 100, status: ShareStatus = .ready) throws -> Data {
        try JSONEncoder().encode(PublicShare(status: status, preview: preview, encryptedMeta: encryptedMeta,
            audioBytes: bytes, hasArt: false, hasCard: false,
            expiresAt: ShareDate.string(Date().addingTimeInterval(3600))))
    }
    func testTrustedRoutesRejectConfusableHostsCredentialsQueriesAndEncodedPaths() {
        let suffix = "/s/\(id)#\(Base64URL.encode(key))"
        for host in ["batonmusic.app", "baton.tonebox.io", "www.batonmusic.app"] {
            XCTAssertEqual(ShareInvitation(url: URL(string: "https://\(host)\(suffix)")!)?.key, key)
        }
        for prefix in ["http://batonmusic.app", "https://batonmusic.app.evil.invalid", "https://user@batonmusic.app", "https://batonmusic.app:444"] {
            XCTAssertNil(ShareInvitation(url: URL(string: prefix + suffix)!))
            XCTAssertNil(ShareLink(url: URL(string: prefix + suffix)!))
        }
        for path in ["/s/\(id)/extra", "/s//\(id)", "/s/%41\(id.dropFirst())", "/s/\(id)?web=1"] {
            XCTAssertNil(ShareInvitation(url: URL(string: "https://batonmusic.app\(path)#\(Base64URL.encode(key))")!))
        }
        XCTAssertNotNil(ShareInvitation(url: URL(string: "baton://share/\(id)#\(Base64URL.encode(key))")!))
    }
    func testIncompleteFragmentsRemainRecognizableWithoutAcceptingAliasedKeys() throws {
        for fragment in ["", "#short", "#\(Base64URL.encode(key))=", "#\(Base64URL.encode(key).dropLast())B"] {
            let invitation = try XCTUnwrap(ShareInvitation(url: URL(string: "https://batonmusic.app/s/\(id)\(fragment)")!))
            XCTAssertNil(invitation.key)
            XCTAssertFalse(invitation.description.contains(Base64URL.encode(key)))
        }
        let invitation = ShareInvitation(id: id, key: key)
        XCTAssertEqual(invitation.browserURL.query, "web=1")
        XCTAssertEqual(invitation.browserURL.fragment, Base64URL.encode(key))
        XCTAssertNil(ShareInvitation(url: invitation.browserURL), "explicit browser choice must not loop back")
    }
    func testPrivateMetadataAuthenticatesBeforeReturningAndNoRequestCarriesKey() async throws {
        let metadata = ShareMetadata(title: "Private title", artist: "Artist", durationSeconds: 35)
        let sealed = try ShareCrypto.seal(JSONEncoder().encode(metadata), key: key, purpose: .meta)
        let stub = ReceiverStub([.init(status: 200, body: try payload(preview: nil, encryptedMeta: sealed.base64EncodedString()))])
        let client = try ShareReceiverClient(transport: stub)
        let result = try await client.details(ShareInvitation(id: id, key: key), platform: "ios")
        XCTAssertEqual(result.metadata, metadata)
        let requests = await stub.captured()
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests[0].url?.fragment)
        XCTAssertFalse(requests[0].url!.absoluteString.contains(Base64URL.encode(key)))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(requests[0].httpShouldHandleCookies)
        XCTAssertEqual(requests[0].url?.query, "via=app&platform=ios")
    }
    func testWrongPrivateKeyFailsClosedAndReportsOnlyAllowlistedFailure() async throws {
        let sealed = try ShareCrypto.seal(JSONEncoder().encode(ShareMetadata(title: "Secret", durationSeconds: 30)), key: key, purpose: .meta)
        let stub = ReceiverStub([.init(status: 200, body: try payload(preview: nil, encryptedMeta: sealed.base64EncodedString())), .init(status: 204, body: Data())])
        let client = try ShareReceiverClient(transport: stub)
        do {
            _ = try await client.details(ShareInvitation(id: id, key: Data(repeating: 9, count: 16)), platform: "macos")
            XCTFail("unauthenticated private metadata escaped")
        } catch { XCTAssertEqual(error as? ShareReceiverClient.Failure, .incomplete) }
        let requests = await stub.captured()
        XCTAssertEqual(requests.count, 2)
        let report = try JSONDecoder().decode(PlayerEvent.self, from: XCTUnwrap(requests.last?.httpBody))
        XCTAssertEqual(report.type, .decryptFailed)
        XCTAssertEqual(report.reason, "auth")
        XCTAssertFalse(String(decoding: requests.last!.httpBody!, as: UTF8.self).contains("Secret"))
    }
    func testAudioRequiresExactCiphertextSizeAndAudioPurposeAuthentication() async throws {
        let plaintext = Data("synthetic audio".utf8)
        let sealed = try ShareCrypto.seal(plaintext, key: key, purpose: .audio)
        let client = try ShareReceiverClient(transport: ReceiverStub([.init(status: 200, body: sealed)]))
        let opened = try await client.audio(ShareInvitation(id: id, key: key), expectedBytes: sealed.count)
        XCTAssertEqual(opened, plaintext)
        let wrongPurpose = try ShareCrypto.seal(plaintext, key: key, purpose: .art)
        let wrong = try ShareReceiverClient(transport: ReceiverStub([.init(status: 200, body: wrongPurpose), .init(status: 204, body: Data())]))
        do { _ = try await wrong.audio(ShareInvitation(id: id, key: key), expectedBytes: wrongPurpose.count); XCTFail() }
        catch { XCTAssertEqual(error as? ShareReceiverClient.Failure, .incomplete) }
        let oversized = try ShareReceiverClient(transport: ReceiverStub([.init(status: 200, body: sealed + Data([0]))]))
        do { _ = try await oversized.audio(ShareInvitation(id: id, key: key), expectedBytes: sealed.count); XCTFail() }
        catch { XCTAssertEqual(error as? ShareReceiverClient.Failure, .tooLarge) }
    }
    func testPrivateArtworkAllowsFramingAtRawLimitAndStillBoundsPlaintext() async throws {
        let raw = Data(repeating: 7, count: ShareLimits.standard.maxArtBytes)
        let sealed = try ShareCrypto.seal(raw, key: key, purpose: .art)
        XCTAssertGreaterThan(sealed.count, raw.count)
        let client = try ShareReceiverClient(transport: ReceiverStub([.init(status: 200, body: sealed)]))
        let opened = try await client.artwork(ShareInvitation(id: id, key: key), encrypted: true)
        XCTAssertEqual(opened, raw)

        let tooMuch = try ShareCrypto.seal(raw + Data([0]), key: key, purpose: .art)
        let oversized = try ShareReceiverClient(transport: ReceiverStub([.init(status: 200, body: tooMuch)]))
        do { _ = try await oversized.artwork(ShareInvitation(id: id, key: key), encrypted: true); XCTFail() }
        catch { XCTAssertEqual(error as? ShareReceiverClient.Failure, .tooLarge) }
    }

    func testArtworkRejectsOversizedWireAndWrongPurposeWithoutReturningBytes() async throws {
        let invitation = ShareInvitation(id: id, key: key)
        for encrypted in [false, true] {
            let limit = ShareLimits.standard.maxArtBytes + (encrypted ? 4096 : 0)
            let client = try ShareReceiverClient(transport: ReceiverStub([.init(status: 200, body: Data(repeating: 0, count: limit + 1))]))
            do { _ = try await client.artwork(invitation, encrypted: encrypted); XCTFail() }
            catch { XCTAssertEqual(error as? ShareReceiverClient.Failure, .tooLarge) }
        }
        let sealed = try ShareCrypto.seal(Data([1, 2, 3]), key: key, purpose: .audio)
        let client = try ShareReceiverClient(transport: ReceiverStub([.init(status: 200, body: sealed)]))
        do { _ = try await client.artwork(invitation, encrypted: true); XCTFail() }
        catch { XCTAssertEqual(error as? ShareReceiverClient.Failure, .incomplete) }
    }

    func testTamperedAudioAndTruncatedAudioNeverReturnPlaintext() async throws {
        let sealed = try ShareCrypto.seal(Data(repeating: 1, count: 100), key: key, purpose: .audio)
        var damaged = sealed; damaged[damaged.count - 1] ^= 1
        for bytes in [damaged, Data(sealed.dropLast())] {
            let client = try ShareReceiverClient(transport: ReceiverStub([.init(status: 200, body: bytes), .init(status: 204, body: Data())]))
            do { _ = try await client.audio(ShareInvitation(id: id, key: key), expectedBytes: bytes.count); XCTFail("tampered stream escaped") }
            catch { XCTAssertEqual(error as? ShareReceiverClient.Failure, .incomplete) }
        }
    }
    func testActualTransportCancelsOversizedAdvertisedAndChunkedBodies() async throws {
        let transport = BoundedShareReceiverTransport {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ReceiverURLProtocol.self]
            return config
        }
        let request = URLRequest(url: URL(string: "http://synthetic.invalid/data")!)
        defer { ReceiverURLProtocol.responseLength = nil; ReceiverURLProtocol.chunks = [] }
        for advertised in [1_000, nil] as [Int?] {
            ReceiverURLProtocol.responseLength = advertised
            ReceiverURLProtocol.chunks = [Data(repeating: 1, count: 80), Data(repeating: 2, count: 80)]
            do { _ = try await transport.send(request, maximumBytes: 128); XCTFail("oversized response escaped") }
            catch { XCTAssertEqual(error as? ShareReceiverClient.Failure, .tooLarge) }
        }
        ReceiverURLProtocol.responseLength = 80
        ReceiverURLProtocol.chunks = [Data(repeating: 3, count: 80)]
        let bounded = try await transport.send(request, maximumBytes: 128)
        XCTAssertEqual(bounded.body.count, 80)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(request, maximumBytes: 128)
        }
        do { _ = try await cancelled.value; XCTFail("cancelled response escaped") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTheCallersTotalTimeoutStandsAndASongGetsLongerThanASmallReply() {
        let unset = URLSessionConfiguration.ephemeral.timeoutIntervalForResource
        // A mixtape track upload asks for 300 s and a book chapter for 900 s; neither is cut to 60.
        XCTAssertEqual(BoundedShareReceiverTransport.resourceTimeout(configured: 300, maximumBytes: 4096), 300)
        XCTAssertEqual(BoundedShareReceiverTransport.resourceTimeout(configured: 900, maximumBytes: 16_384), 900)
        XCTAssertEqual(BoundedShareReceiverTransport.resourceTimeout(configured: 15, maximumBytes: 4096), 15)
        // With no choice made, small JSON keeps its 60 s, and a song download is not held to it.
        XCTAssertEqual(BoundedShareReceiverTransport.resourceTimeout(configured: unset, maximumBytes: 16_384), 60)
        XCTAssertGreaterThanOrEqual(BoundedShareReceiverTransport.resourceTimeout(configured: unset, maximumBytes: 12_000_000), 300)
    }

    func testPublicStatesPendingEndedUnknownAndCappedAreExplicit() async throws {
        for (status, body, expected) in [(404, Data(), ShareReceiverClient.Failure.unknown),
                                        (410, Data(), .expired),
                                        (410, try JSONEncoder().encode(ShareErrorBody(error: "Ended", code: "play_cap")), .capped),
                                        (302, Data(), .unavailable)] {
            let client = try ShareReceiverClient(transport: ReceiverStub([.init(status: status, body: body)]))
            do { _ = try await client.details(ShareInvitation(id: id, key: key), platform: "ios"); XCTFail() }
            catch { XCTAssertEqual(error as? ShareReceiverClient.Failure, expected) }
        }
        let client = try ShareReceiverClient(transport: ReceiverStub([.init(status: 200, body: try payload(status: .pending))]))
        let pending = try await client.details(ShareInvitation(id: id, key: key), platform: "ios")
        XCTAssertEqual(pending.share.status, .pending)
    }
    func testPendingPollDoesNotCountAnotherAppOpen() async throws {
        let stub = ReceiverStub([.init(status: 200, body: try payload(status: .pending)),
                                 .init(status: 200, body: try payload())])
        let client = try ShareReceiverClient(transport: stub)
        let invitation = ShareInvitation(id: id, key: key)
        _ = try await client.details(invitation, platform: "ios")
        _ = try await client.details(invitation, platform: "ios", reportOpen: false)
        let requests = await stub.captured()
        XCTAssertNotNil(requests[0].url?.query)
        XCTAssertNil(requests[1].url?.query)
    }
    func testRecordingIDIsOptionalBackwardCompatibleAndValidated() throws {
        let old = try JSONDecoder().decode(ShareMetadata.self, from: Data(#"{"title":"Song","durationSeconds":30}"#.utf8))
        XCTAssertNil(old.recordingID)
        let identity = "83D9EA58-1A5B-4B02-8DC3-2955C705E326"
        let metadata = try ShareMetadata(title: "Song", durationSeconds: 30, recordingID: identity).validated()
        XCTAssertEqual(metadata.recordingID, identity.lowercased())
        XCTAssertEqual(try JSONDecoder().decode(ShareMetadata.self, from: JSONEncoder().encode(metadata)), metadata)
        XCTAssertThrowsError(try ShareMetadata(title: "Song", durationSeconds: 30, recordingID: "not a recording").validated())
    }
    func testActualSchedulingIntervalCountsSlowTimersWithoutCountingSeekOrPause() {
        var listening = SharedSongListening()
        _ = listening.observe(position: 0, wallSeconds: 0, playing: false)
        var events: [PlayerEvent.Kind] = []
        for tick in 1...100 {
            events += listening.observe(position: Double(tick) * 0.4, wallSeconds: 0.4, playing: true)
        }
        XCTAssertEqual(listening.seconds, 40, accuracy: 0.000_001)
        XCTAssertEqual(events, [.playStarted, .played30s])
        listening.resetPosition()
        _ = listening.observe(position: 90, wallSeconds: 0, playing: false) // seek/resume baseline
        _ = listening.observe(position: 90.4, wallSeconds: 0.4, playing: true)
        XCTAssertEqual(listening.seconds, 40.4, accuracy: 0.000_001)
        _ = listening.observe(position: 90.4, wallSeconds: 10, playing: false)
        _ = listening.observe(position: 190, wallSeconds: 0.4, playing: true) // jump is not listening
        XCTAssertEqual(listening.seconds, 40.4, accuracy: 0.000_001)
        _ = listening.observe(position: 195, wallSeconds: 5, playing: true) // unmeasured long stall
        XCTAssertEqual(listening.seconds, 40.4, accuracy: 0.000_001)
    }
    func testReceivedOwnershipDoesNotAutoResumeLibraryAfterStopOrStaleRelease() {
        var ownership = ReceivedAudioOwnership()
        XCTAssertTrue(ownership.allowsLibraryResume)
        let first = ownership.begin()
        XCTAssertFalse(ownership.allowsLibraryResume)
        let second = ownership.begin()
        XCTAssertFalse(ownership.release(first))
        XCTAssertEqual(ownership.token, second)
        XCTAssertTrue(ownership.release(second))
        XCTAssertNil(ownership.token)
        XCTAssertFalse(ownership.allowsLibraryResume, "dismissal/interruption is not permission to resume the old library")
        ownership.libraryWillStart()
        XCTAssertTrue(ownership.allowsLibraryResume)
        XCTAssertFalse(ownership.release(second), "late receiver release cannot steal normal library admission")
    }
    func testListeningCountsTimeOnceAndNeverCountsSeekingOrPausedTime() {
        var listening = SharedSongListening()
        XCTAssertTrue(listening.observe(position: 0, wallSeconds: 1, playing: true).isEmpty)
        XCTAssertEqual(listening.observe(position: 1, wallSeconds: 1, playing: true), [.playStarted])
        XCTAssertTrue(listening.observe(position: 90, wallSeconds: 1, playing: true).isEmpty)
        XCTAssertEqual(listening.seconds, 1)
        listening.resetPosition()
        _ = listening.observe(position: 2, wallSeconds: 1, playing: false)
        var events: [PlayerEvent.Kind] = []
        for position in 3...33 { events += listening.observe(position: Double(position), wallSeconds: 1, playing: true) }
        XCTAssertEqual(events, [.played30s])
        XCTAssertEqual(listening.finished(successfully: true), [.playCompleted])
        XCTAssertTrue(listening.finished(successfully: true).isEmpty)
    }
}
