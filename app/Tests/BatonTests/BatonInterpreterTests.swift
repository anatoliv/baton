@testable import Baton
import Foundation
import Network
import XCTest

@MainActor
private final class InterpreterTestRoute: InterpreterRoute {
    var onFailure: (@MainActor () -> Void)?
    var stopped = false
    var chunks: [Data] = []
    var blocked = false
    var ending: CheckedContinuation<(Double, Double), any Error>?
    func begin() throws {
        guard !stopped else { throw InterpreterRouteError.cancelled }
    }

    func append(_ pcm: Data) async throws {
        chunks.append(pcm)
    }

    func end() async throws -> (Double, Double) {
        if blocked {
            return try await withCheckedThrowingContinuation { ending = $0 }
        }
        return (10, 25)
    }

    func stop() {
        stopped = true; ending?.resume(throwing: CancellationError()); ending = nil
    }
}

@MainActor
final class BatonInterpreterTests: XCTestCase {
    private let headphones = InterpreterDevices.Device(uid: "fixture-headphones", name: "Headphones", id: 1, input: false, output: true, virtual: false)
    private let virtualMic = InterpreterDevices.Device(uid: "fixture-loopback", name: "Virtual microphone", id: 2, input: true, output: true, virtual: true)
    private var connections: [NWConnection] = []
    private var hub: BatonInterpreterHub?
    private var routes: [String: InterpreterTestRoute] = [:]
    private var model: MusicModel?

    override func tearDown() {
        hub?.close(); hub = nil
        connections.forEach { $0.cancel() }; connections = []
        model = nil; routes = [:]
    }

    private func opened() async throws -> [String: Any] {
        let model = MusicModel(); self.model = model
        let devices = [headphones, virtualMic]
        let hub = BatonInterpreterHub(devices: { devices }, makeRoute: { [weak self] device in
            let route = InterpreterTestRoute(); self?.routes[device.uid] = route; return route
        })
        self.hub = hub
        let text = try await hub.open(["incoming_device_uid": headphones.uid, "outgoing_device_uid": virtualMic.uid, "voice_engine": "native"], music: model, focus: BatonAudioFocusRegistry())
        XCTAssertTrue(model.speech.interpretationActive)
        return try object(Data(text.utf8))
    }

    private func connected(_ opened: [String: Any], lane: String, token: String? = nil) async throws -> NWConnection {
        let connection = try NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(XCTUnwrap(opened["port"] as? Int)))!, using: .tcp)
        connections.append(connection)
        connection.start(queue: .main)
        let deadline = Task { do { try await Task.sleep(for: .seconds(4)); connection.cancel() } catch {} }
        defer { deadline.cancel() }
        try await InterpreterFrames.send(connection, data: JSONSerialization.data(withJSONObject: ["type": "authenticate", "session_id": opened["session_id"] ?? "", "lane": lane, "token": token ?? opened["token"] ?? ""]))
        let reply = try await object(InterpreterFrames.receive(connection))
        if token == nil {
            XCTAssertEqual(reply["type"] as? String, "authenticated")
        } else {
            XCTAssertEqual(reply["type"] as? String, "error")
        }
        return connection
    }

    private func packet(_ opened: [String: Any], lane: String, type: String, id: String, sequence: Int = 0, generation: Int = 0) -> [String: Any] {
        ["type": type, "session_id": opened["session_id"] ?? "", "lane": lane, "generation": generation, "sequence": sequence,
         "commit_id": id, "source_span_id": id, "source_revision": String(repeating: "a", count: 64), "target_language": "es"]
    }

    private func exchange(_ connection: NWConnection, _ packet: [String: Any]) async throws -> [String: Any] {
        let deadline = Task { do { try await Task.sleep(for: .seconds(4)); connection.cancel() } catch {} }
        defer { deadline.cancel() }
        try await InterpreterFrames.send(connection, data: JSONSerialization.data(withJSONObject: packet))
        return try await object(InterpreterFrames.receive(connection))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testUnauthenticatedConnectionCannotOccupyOrPlayALane() async throws {
        let opened = try await opened()
        _ = try await connected(opened, lane: "outgoing", token: "wrong-token")
        let connection = try await connected(opened, lane: "outgoing")
        let reply = try await exchange(connection, ["type": "heartbeat"])
        XCTAssertEqual(reply["type"] as? String, "pong")
        XCTAssertTrue(try XCTUnwrap(routes[virtualMic.uid]).chunks.isEmpty)
    }

    func testPCMCompletesOnlyAfterRenderAndCancellationLeavesIncomingAlive() async throws {
        let opened = try await opened()
        let incoming = try await connected(opened, lane: "incoming")
        let outgoing = try await connected(opened, lane: "outgoing")
        let id = UUID().uuidString
        let accepted = try await exchange(outgoing, packet(opened, lane: "outgoing", type: "begin_pcm", id: id))
        XCTAssertEqual(accepted["type"] as? String, "accepted")
        var pcm = packet(opened, lane: "outgoing", type: "pcm", id: id)
        pcm["audio"] = Data([1, 0, 2, 0]).base64EncodedString(); pcm["chunk_sequence"] = 0
        _ = try await exchange(outgoing, pcm)
        let route = try XCTUnwrap(routes[virtualMic.uid]); route.blocked = true
        try await InterpreterFrames.send(outgoing, data: JSONSerialization.data(withJSONObject: packet(opened, lane: "outgoing", type: "end_pcm", id: id)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while route.ending == nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertNotNil(route.ending, "No receipt may advance before route completion")
        route.ending?.resume(returning: (10, 25)); route.ending = nil
        let receipt = try await object(InterpreterFrames.receive(outgoing))
        XCTAssertEqual(receipt["type"] as? String, "rendered")
        XCTAssertEqual(receipt["commit_id"] as? String, id)
        XCTAssertEqual(route.chunks, [Data([1, 0, 2, 0])])
        _ = try hub?.cancel(["session_id": opened["session_id"] ?? "", "lane": "outgoing", "generation": 0])
        XCTAssertTrue(route.stopped)
        let pong = try await exchange(incoming, ["type": "heartbeat"])
        XCTAssertEqual(pong["type"] as? String, "pong")
        XCTAssertFalse(try XCTUnwrap(routes[headphones.uid]).stopped)
        hub?.close()
        XCTAssertFalse(try XCTUnwrap(model).speech.interpretationActive)
    }

    func testDuplicateSourceCommitIsRejectedAndNeverPlayedAgain() async throws {
        let opened = try await opened()
        _ = try await connected(opened, lane: "incoming")
        let outgoing = try await connected(opened, lane: "outgoing")
        let id = UUID().uuidString
        _ = try await exchange(outgoing, packet(opened, lane: "outgoing", type: "begin_pcm", id: id))
        _ = try await exchange(outgoing, packet(opened, lane: "outgoing", type: "end_pcm", id: id))
        let duplicate = try await exchange(outgoing, packet(opened, lane: "outgoing", type: "begin_pcm", id: id, sequence: 1))
        XCTAssertEqual(duplicate["type"] as? String, "error")
        XCTAssertTrue(try XCTUnwrap(routes[virtualMic.uid]).chunks.isEmpty)
    }

    func testResumePreservesOtherLaneAndIgnoresOldCancellation() async throws {
        let opened = try await opened()
        let incoming = try await connected(opened, lane: "incoming")
        let outgoing = try await connected(opened, lane: "outgoing")
        let oldID = UUID().uuidString
        _ = try await exchange(outgoing, packet(opened, lane: "outgoing", type: "begin_pcm", id: oldID))
        _ = try await exchange(outgoing, packet(opened, lane: "outgoing", type: "end_pcm", id: oldID))
        _ = try hub?.cancel(["session_id": opened["session_id"] ?? "", "lane": "outgoing", "generation": 0])
        let configured = try object(Data(XCTUnwrap(hub).configure(["session_id": opened["session_id"] ?? "", "lane": "outgoing", "device_uid": virtualMic.uid]).utf8))
        var resumed = opened
        resumed["token"] = configured["token"]
        let generation = try XCTUnwrap(configured["generation"] as? Int)
        XCTAssertEqual(generation, 2)
        let replacement = try XCTUnwrap(routes[virtualMic.uid])
        let connection = try await connected(resumed, lane: "outgoing")
        _ = try hub?.cancel(["session_id": opened["session_id"] ?? "", "lane": "outgoing", "generation": 0])
        XCTAssertFalse(replacement.stopped, "Late cancellation must not stop a resumed generation")
        let newID = UUID().uuidString
        _ = try await exchange(connection, packet(opened, lane: "outgoing", type: "begin_pcm", id: newID, generation: generation))
        var pcm = packet(opened, lane: "outgoing", type: "pcm", id: newID, generation: generation)
        pcm["audio"] = Data([3, 0, 4, 0]).base64EncodedString(); pcm["chunk_sequence"] = 0
        _ = try await exchange(connection, pcm)
        let rendered = try await exchange(connection, packet(opened, lane: "outgoing", type: "end_pcm", id: newID, generation: generation))
        XCTAssertEqual(rendered["type"] as? String, "rendered")
        XCTAssertEqual(replacement.chunks, [Data([3, 0, 4, 0])])
        let duplicate = try await exchange(connection, packet(opened, lane: "outgoing", type: "begin_pcm", id: oldID, sequence: 1, generation: generation))
        XCTAssertEqual(duplicate["type"] as? String, "error", "Resuming must retain delivery history")
        let pong = try await exchange(incoming, ["type": "heartbeat"])
        XCTAssertEqual(pong["type"] as? String, "pong")
        XCTAssertFalse(try XCTUnwrap(routes[headphones.uid]).stopped)
    }

    func testRepeatedPCMChunkFailsClosedWithoutPlayingItTwice() async throws {
        let opened = try await opened()
        let incoming = try await connected(opened, lane: "incoming")
        let outgoing = try await connected(opened, lane: "outgoing")
        let id = UUID().uuidString
        _ = try await exchange(outgoing, packet(opened, lane: "outgoing", type: "begin_pcm", id: id))
        var pcm = packet(opened, lane: "outgoing", type: "pcm", id: id)
        pcm["audio"] = Data([1, 0, 2, 0]).base64EncodedString(); pcm["chunk_sequence"] = 0
        _ = try await exchange(outgoing, pcm)
        let duplicate = try await exchange(outgoing, pcm)
        XCTAssertEqual(duplicate["type"] as? String, "error")
        XCTAssertEqual(try XCTUnwrap(routes[virtualMic.uid]).chunks.count, 1)
        let pong = try await exchange(incoming, ["type": "heartbeat"])
        XCTAssertEqual(pong["type"] as? String, "pong")
    }

    func testRouteFailureStopsOnlyItsDirection() async throws {
        let opened = try await opened()
        let incoming = try await connected(opened, lane: "incoming")
        _ = try await connected(opened, lane: "outgoing")
        let outgoingRoute = try XCTUnwrap(routes[virtualMic.uid])
        outgoingRoute.onFailure?()
        XCTAssertTrue(outgoingRoute.stopped)
        let pong = try await exchange(incoming, ["type": "heartbeat"])
        XCTAssertEqual(pong["type"] as? String, "pong")
        XCTAssertFalse(try XCTUnwrap(routes[headphones.uid]).stopped)
    }

    func testOutgoingCannotBeOpenedOnPhysicalSpeakers() async throws {
        let model = MusicModel()
        let devices = [headphones, virtualMic]
        let hub = BatonInterpreterHub(devices: { devices })
        do {
            _ = try await hub.open(["incoming_device_uid": virtualMic.uid, "outgoing_device_uid": headphones.uid], music: model, focus: BatonAudioFocusRegistry())
            XCTFail("Must reject physical output before constructing any graph")
        } catch { XCTAssertFalse(hub.isActive); XCTAssertFalse(model.speech.interpretationActive) }
    }
}
