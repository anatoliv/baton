@testable import BatonMobile
import BatonShareKit
import Foundation
import XCTest

@MainActor
final class SharedMixtapeModelTests: XCTestCase {
    private struct Fixture: Decodable {
        let rootKey: String, containerID: String
        let publicShare: PublicMixtape
        let blobs: [String: String]
    }
    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mixtape-native-fixture", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    /// One public vertical path through independently encrypted real MP3s and AVAudioPlayer.
    /// No player, listening clock, session or completion state is replaced by the test.
    func testRealOrderedMediaRequiresFreshSessionAnalyticsAndReaction() async throws {
        // Opt-in: only the protected-fixture probe (scripts/test-mixtape-native-stage.py
        // --media-fixture) supplies the encrypted MP3s; an ordinary run skips.
        let configured = ProcessInfo.processInfo.environment["BATON_NATIVE_MIXTAPE_MEDIA_FILE"]
        try XCTSkipUnless(configured?.isEmpty == false, "requires the protected real-media fixture")
        let path = try XCTUnwrap(configured)
        let fixture = try MixtapeRealMediaFixture.load(from: URL(fileURLWithPath: path))
        let transport = MixtapeRealMediaTransport(fixture: fixture)
        let model = SharedMixtapeModel(client: try ShareMixtapeReceiver(transport: transport))
        defer { model.clear() }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(120))
        func waitFor(_ message: String, timeout: Duration = .seconds(5), _ predicate: () async -> Bool) async throws {
            let until = min(deadline, clock.now.advanced(by: timeout))
            while clock.now < until {
                if await predicate() { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail(message)
            throw MixtapeRealMediaFixture.Failure.observationTimedOut
        }
        func observedEvents(_ ordinal: Int) async -> [String: Int] {
            let observation = await transport.observed()
            return observation.eventsBySession[ordinal] ?? [:]
        }
        await model.load(fixture.invitation)
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.manifest?.tracks.map(\.metadata.title), fixture.expected.orderedTitles)
        XCTAssertEqual(model.selectedIndex, 0)
        let opened = await transport.observed()
        XCTAssertEqual(opened.admissions, 0); XCTAssertEqual(opened.audioRequests, 0)

        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        try await waitFor("The short authenticated MP3 never advanced its real AV clock") { model.isPlaying && model.position > 0.4 }
        XCTAssertGreaterThan(model.duration, 1.9); XCTAssertLessThan(model.duration, 2.3)
        try await waitFor("The first track never completed through the AV delegate") { !model.isPlaying && model.position >= model.duration && model.duration > 0 }
        XCTAssertTrue(model.canReact)
        await model.react(emoji: "❤️", name: "Synthetic listener", reply: "First session")
        let replied = await transport.observed()
        XCTAssertEqual(replied.reactionsBySession[1], 1); XCTAssertTrue(model.reactionSent)
        XCTAssertEqual(replied.admissions, 1); XCTAssertEqual(replied.audioRequests, 1)
        let firstTrackEvents = await observedEvents(1)
        XCTAssertEqual(firstTrackEvents["play_started"], 1)
        XCTAssertEqual(firstTrackEvents["play_completed", default: 0], 0, "One finished track is not a finished container")

        await model.select(1, pauseLibrary: {}, audioSession: .unmanaged)
        XCTAssertEqual(model.metadata?.title, "Long synthetic MP3")
        XCTAssertEqual(model.duration, 0, "Selecting another track must evict the previous current media")
        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        try await waitFor("The long authenticated MP3 never advanced its real AV clock") { model.isPlaying && model.position > 0.5 }
        XCTAssertGreaterThan(model.duration, 34.9); XCTAssertLessThan(model.duration, 35.3)
        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        XCTAssertFalse(model.isPlaying)
        let paused = model.position
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(model.position, paused, accuracy: 0.05, "Pause must stop the actual media clock")
        model.seek(2)
        XCTAssertEqual(model.position, 2, accuracy: 0.05)
        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        try await waitFor("Resume after seeking never advanced the actual media clock") { model.isPlaying && model.position > 2.5 }
        let resumed = await transport.observed()
        XCTAssertEqual(resumed.admissions, 1); XCTAssertEqual(resumed.audioRequests, 2, "Pause, resume and seek must not readmit or refetch")
        try await waitFor("Thirty real listened seconds were not reported for the first session", timeout: .seconds(45)) {
            (await observedEvents(1))["play_30s"] == 1
        }
        model.seek(model.duration - 0.5)
        try await waitFor("The container never completed after both real tracks finished") {
            (await observedEvents(1))["play_completed"] == 1
        }
        let finishedEvents = await observedEvents(1)
        XCTAssertEqual(finishedEvents, fixture.expected.firstSessionEvents)

        await model.select(0, pauseLibrary: {}, audioSession: .unmanaged)
        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        XCTAssertTrue(model.needsAnotherPlay)
        model.cancelAnotherPlay()
        let canceled = await transport.observed()
        XCTAssertEqual(canceled.admissions, 1); XCTAssertEqual(canceled.audioRequests, 2)
        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        XCTAssertTrue(model.needsAnotherPlay)
        await model.confirmAnotherPlay(pauseLibrary: {}, audioSession: .unmanaged)
        XCTAssertFalse(model.needsAnotherPlay)
        XCTAssertFalse(model.canReact, "A fresh allowance needs its own listening qualification")
        XCTAssertFalse(model.reactionSent, "A new session must allow its own reaction")
        await model.react(emoji: "❤️", name: "Synthetic listener", reply: "Too early")
        let renewed = await transport.observed()
        XCTAssertEqual(renewed.admissions, 2); XCTAssertEqual(renewed.audioRequests, 3)
        XCTAssertEqual(renewed.reactionsBySession[2, default: 0], 0)
        try await waitFor("A new real session never reported its own first listening event") {
            (await observedEvents(2))["play_started"] == 1
        }
        try await waitFor("The renewed short track never finished") { !model.isPlaying && model.position >= model.duration && model.duration > 0 }
        let renewedEvents = await observedEvents(2)
        XCTAssertEqual(renewedEvents, fixture.expected.renewedSessionBeforeAllTracksEvents.filter { $0.value > 0 })
        XCTAssertTrue(model.canReact)
        await model.react(emoji: "❤️", name: "Synthetic listener", reply: "Second session")
        let renewedReply = await transport.observed()
        XCTAssertEqual(renewedReply.reactionsBySession[2], 1)
        await model.select(1, pauseLibrary: {}, audioSession: .unmanaged)
        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        try await waitFor("The renewed session reused the old thirty-second event state", timeout: .seconds(45)) {
            (await observedEvents(2))["play_30s"] == 1
        }
        model.seek(model.duration - 0.5)
        try await waitFor("The renewed session never completed after all its tracks finished") {
            (await observedEvents(2))["play_completed"] == 1
        }
        let finalEvents = await observedEvents(2), final = await transport.observed()
        XCTAssertEqual(finalEvents, fixture.expected.firstSessionEvents)
        XCTAssertEqual(final.admissions, 2); XCTAssertEqual(final.audioRequests, 4)
    }
    func testOpeningAndSelectingOrderedManifestDoesNotAdmitOrFetchAudio() async throws {
        let fixture = try fixture(), transport = MixtapeModelTransport(share: fixture.publicShare, blobs: fixture.blobs)
        let model = SharedMixtapeModel(client: try ShareMixtapeReceiver(transport: transport))
        await model.load(.init(id: fixture.containerID, key: Base64URL.decode(fixture.rootKey), kind: .mixtape))
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.manifest?.tracks.map(\.metadata.title), ["Ordered Second", "Ordered First"])
        await model.select(1, pauseLibrary: {}, audioSession: .unmanaged)
        XCTAssertEqual(model.metadata?.title, "Ordered First")
        let observed1 = await transport.admissions(); XCTAssertEqual(observed1, 0)
        let observed2 = await transport.audioReads(); XCTAssertEqual(observed2, 0)
        model.clear()
    }
    func testLateAuthenticatedManifestCannotReviveClosedPresentation() async throws {
        let fixture = try fixture(), transport = MixtapeModelTransport(share: fixture.publicShare, blobs: fixture.blobs, pause: "details")
        let model = SharedMixtapeModel(client: try ShareMixtapeReceiver(transport: transport))
        let load = Task { await model.load(.init(id: fixture.containerID, key: Base64URL.decode(fixture.rootKey), kind: .mixtape)) }
        await transport.waitForPause(); model.clear(); await transport.release(); await load.value
        XCTAssertNil(model.manifest); XCTAssertNil(model.metadata); XCTAssertFalse(model.isPlaying)
        let observed3 = await transport.admissions(); XCTAssertEqual(observed3, 0)
    }
    func testLateAudioCannotRestoreSupersededTrackAndDoesNotReadmit() async throws {
        let fixture = try fixture(), transport = MixtapeModelTransport(share: fixture.publicShare, blobs: fixture.blobs, pause: "audio")
        let model = SharedMixtapeModel(client: try ShareMixtapeReceiver(transport: transport))
        await model.load(.init(id: fixture.containerID, key: Base64URL.decode(fixture.rootKey), kind: .mixtape))
        let play = Task { await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged) }
        await transport.waitForPause()
        await model.select(1, pauseLibrary: {}, audioSession: .unmanaged)
        await transport.release(); await play.value
        XCTAssertEqual(model.metadata?.title, "Ordered First"); XCTAssertFalse(model.isPlaying); XCTAssertEqual(model.duration, 0)
        let observed4 = await transport.admissions(); XCTAssertEqual(observed4, 1); let observed5 = await transport.audioReads(); XCTAssertEqual(observed5, 1)
        model.clear()
    }
    func testCanceledAdmissionCannotSpendAnotherPlayWithoutConfirmation() async throws {
        let fixture = try fixture(), transport = MixtapeModelTransport(share: fixture.publicShare, blobs: fixture.blobs, pause: "admission", failAudio: true)
        let model = SharedMixtapeModel(client: try ShareMixtapeReceiver(transport: transport))
        await model.load(.init(id: fixture.containerID, key: Base64URL.decode(fixture.rootKey), kind: .mixtape))
        let play = Task { await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged) }
        await transport.waitForPause()
        await model.select(1, pauseLibrary: {}, audioSession: .unmanaged)
        await transport.release(); await play.value
        let first = await transport.admissions(); XCTAssertEqual(first, 1)
        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        XCTAssertTrue(model.needsAnotherPlay, "An unmeasurable admission may already have consumed a cap unit")
        let ordinaryPlay = await transport.admissions(); XCTAssertEqual(ordinaryPlay, 1)
        let reads = await transport.audioReads(); XCTAssertEqual(reads, 0)
        model.cancelAnotherPlay()
        let cancel = await transport.admissions(); XCTAssertEqual(cancel, 1)
        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        await model.confirmAnotherPlay(pauseLibrary: {}, audioSession: .unmanaged)
        let confirmed = await transport.admissions(); XCTAssertEqual(confirmed, 2)
        model.clear()
    }
    func testUnknownDeliveryRemainsChargedAndRenewalNeedsExplicitConfirmation() async throws {
        let fixture = try fixture(), transport = MixtapeModelTransport(share: fixture.publicShare, blobs: fixture.blobs, failAudio: true)
        let model = SharedMixtapeModel(client: try ShareMixtapeReceiver(transport: transport))
        await model.load(.init(id: fixture.containerID, key: Base64URL.decode(fixture.rootKey), kind: .mixtape))
        for _ in 0..<2 { await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged) }
        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        XCTAssertTrue(model.needsAnotherPlay)
        let observed6 = await transport.admissions(); XCTAssertEqual(observed6, 1); let observed7 = await transport.audioReads(); XCTAssertEqual(observed7, 2)
        model.cancelAnotherPlay()
        let observed8 = await transport.admissions(); XCTAssertEqual(observed8, 1)
        await model.togglePlayback(pauseLibrary: {}, audioSession: .unmanaged)
        XCTAssertTrue(model.needsAnotherPlay)
        await model.confirmAnotherPlay(pauseLibrary: {}, audioSession: .unmanaged)
        let observed9 = await transport.admissions(); XCTAssertEqual(observed9, 2); let observed10 = await transport.audioReads(); XCTAssertEqual(observed10, 3)
        XCTAssertFalse(model.isPlaying, "Unavailable media does not establish successful playback")
        model.clear()
    }
}

/// Literal public HTTP fixture backed by independently encrypted Python material.
/// Suspended responses deliberately ignore cancellation to exercise late delivery fences.
private actor MixtapeModelTransport: ShareReceiverTransport {
    let share: PublicMixtape
    let blobs: [String: String]
    var pause: String?
    let failAudio: Bool
    var pending: CheckedContinuation<ShareReceiverResponse, Error>?
    var pendingResponse: ShareReceiverResponse?
    var arrived: CheckedContinuation<Void, Never>?
    var admissionCount = 0, audioCount = 0
    init(share: PublicMixtape, blobs: [String: String], pause: String? = nil, failAudio: Bool = false) {
        self.share = share; self.blobs = blobs; self.pause = pause; self.failAudio = failAudio
    }
    func admissions() -> Int { admissionCount }
    func audioReads() -> Int { audioCount }
    func waitForPause() async { if pending != nil { return }; await withCheckedContinuation { arrived = $0 } }
    func release() { pause = nil; if let response = pendingResponse { pending?.resume(returning: response) }; pending = nil; pendingResponse = nil }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ShareReceiverResponse {
        let path = request.url!.path
        let response: ShareReceiverResponse, category: String
        if path.hasSuffix("/sessions") {
            admissionCount += 1; category = "admission"
            response = .init(status: 201, body: try JSONEncoder().encode(MixtapeSession(token: Base64URL.encode(Data(repeating: 21, count: 32)),
                expiresAt: "2099-01-01T00:00:00Z", remainingBytes: share.tracks.values.reduce(0) { $0 + $1.audioBytes }, remainingPlays: max(0, 2 - admissionCount))))
        } else if path.contains("/tracks/") {
            audioCount += 1; category = "audio"
            response = failAudio ? .init(status: 503, body: Data("{}".utf8)) : .init(status: 200, body: Data(base64Encoded: blobs[request.url!.lastPathComponent]!)!)
        } else { category = "details"; response = .init(status: 200, body: try JSONEncoder().encode(share)) }
        if pause == category {
            pendingResponse = response
            return try await withCheckedThrowingContinuation { pending = $0; arrived?.resume(); arrived = nil }
        }
        return response
    }
}
