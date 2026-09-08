import BatonPlaybackKit
import BatonSubsonicKit
import SwiftUI

/// Tests the services a settings import just configured, in the same flow as the import.
///
/// WHY THIS EXISTS. "Set up from a Mac" used to end at "Imported 74 settings and
/// 9 secrets" and stop. Everything it had configured was untested, and the Friend tab —
/// which appears only once a connection test has passed — stayed hidden. From the outside
/// that is indistinguishable from the settings never having arrived, which is the complaint
/// TBX-5114 began with, surviving its own fix. Finishing a setup should not require knowing
/// that a second button exists on a screen you have not opened.
///
/// **It runs the test rather than assuming it.** The rule is `ServiceStatus`'s own: a green
/// light is the result of a request that just happened. That matters here more than usual,
/// because the honest answer is often "no" — a Mac's model host is routinely a private
/// address on the home network that this phone cannot reach on cellular, so "it worked on
/// the Mac" is evidence about the Mac. Marking the friend verified because a file arrived
/// would put a tab on screen that fails the first time it is used.
///
/// The friend's check is the one that changes what the user sees: `AgentClient
/// .runConnectionTest()` calls `markVerified()` on a pass, so a passing import makes the
/// Friend tab appear by itself, having earned it.
///
/// Every probe here is read-only — `validate-token`, `user.getInfo`, a resolve-only prompt,
/// one authenticated ping. Nothing is submitted, so a check costs nothing but latency.
@MainActor
@Observable
final class ImportedSetupCheck {
    enum Service: String, CaseIterable, Identifiable, Sendable {
        case server, friend, listenBrainz, lastFM

        var id: String { rawValue }

        var name: String {
            switch self {
            case .server: "Music server"
            case .friend: "Music friend"
            case .listenBrainz: "ListenBrainz"
            case .lastFM: "Last.fm"
            }
        }
    }

    /// What the import left configured, as plain booleans.
    ///
    /// Split out so the decision of *what to check* is a pure function with no network and no
    /// model — the half worth testing exhaustively, and the half that silently rots. A list
    /// that always checks everything looks identical to a correct one on a fully configured
    /// device, which is the only device anyone tests this on by hand.
    struct Configured: Equatable, Sendable {
        var server = false
        var friend = false
        var listenBrainz = false
        var lastFM = false
    }

    /// Which services are worth asking about, given what arrived.
    ///
    /// Anything not configured is omitted rather than listed as "not set up". A row reading
    /// "ListenBrainz: no token yet" on a setup that never had one is noise, and noise beside
    /// a real failure is how the real failure gets missed.
    static func services(for configured: Configured) -> [Service] {
        var services: [Service] = []
        if configured.server { services.append(.server) }
        if configured.friend { services.append(.friend) }
        if configured.listenBrainz { services.append(.listenBrainz) }
        if configured.lastFM { services.append(.lastFM) }
        return services
    }

    private(set) var order: [Service] = []
    private(set) var results: [Service: ServiceStatus] = [:]
    private(set) var isRunning = false

    /// Ran, and every service it asked about answered.
    var hasRun: Bool { !order.isEmpty && !isRunning }

    /// The ones worth saying something about. A refused credential and an unreachable host
    /// need different things from the user, so `ServiceStatus` keeps them apart and so does
    /// this — the caller shows the status, not a boolean.
    var failures: [Service] {
        order.filter { service in
            switch results[service] {
            case .refused, .unreachable: true
            default: false
            }
        }
    }

    /// Everything asked about answered successfully.
    var allPassed: Bool {
        hasRun && order.allSatisfy { if case .ok = results[$0] { true } else { false } }
    }

    func status(for service: Service) -> ServiceStatus { results[service] ?? .unknown }

    /// Read what the freshly imported settings left configured.
    ///
    /// Must run AFTER `MobileModel.reloadAfterSettingsImport()`, or every one of these reads
    /// the values this phone had before the import — the exact defect TBX-5114 fixed, which
    /// would come back here wearing a green badge.
    static func configured(from model: MobileModel) -> Configured {
        Configured(
            server: !NavidromeConfig.serverURLString.trimmingCharacters(in: .whitespaces).isEmpty,
            friend: model.agentConfig.isConfigured,
            listenBrainz: !model.listenBrainz.token.trimmingCharacters(in: .whitespaces).isEmpty,
            lastFM: model.lastfm.isConnected
        )
    }

    /// Run every applicable check, concurrently, updating each row as it lands.
    ///
    /// Concurrent because they are independent and the slowest is a model round-trip: run in
    /// series they add up to a wait long enough that people leave the screen, and a check
    /// nobody stays for is a check nobody has.
    func run(on model: MobileModel) async {
        let services = Self.services(for: Self.configured(from: model))
        order = services
        results = Dictionary(uniqueKeysWithValues: services.map { ($0, ServiceStatus.checking) })
        guard !services.isEmpty else { return }
        isRunning = true
        defer { isRunning = false }

        // `Task { @MainActor in … }` rather than a task group: everything here is main-actor
        // isolated, and a group of main-actor child tasks makes Swift 6's region checker give
        // up on the tuple it would have to send back. These start immediately and overlap on
        // their `await`s — which is where the whole latency is — while never leaving the
        // actor, so nothing crosses an isolation boundary and nothing needs to be Sendable.
        let running = services.map { service in
            Task { @MainActor in (service, await Self.probe(service, on: model)) }
        }
        for task in running {
            let (service, status) = await task.value
            results[service] = status
        }
    }

    private static func probe(_ service: Service, on model: MobileModel) async -> ServiceStatus {
        switch service {
        case .server:
            let status = ServerStatus()
            await status.check()
            return status.state

        case .friend:
            // The one with a side effect, and it is the point: a pass calls `markVerified()`,
            // so the Friend tab appears without anyone pressing anything. The mapping lives on
            // `AgentClient` because Settings asks the same question, and two copies
            // is how the two screens start disagreeing about what a failure means.
            return await model.agent.connectionStatus()

        case .listenBrainz:
            switch await model.listenBrainz.checkToken() {
            case .missing: return .notConfigured("No token yet")
            case let .valid(user):
                return .ok(detail: user.isEmpty ? "Scrobbling to ListenBrainz." : "Scrobbling as \(user).")
            case .rejected:
                return .refused("ListenBrainz didn't accept this token. Copy it again from your profile.")
            case let .failed(why): return .unreachable(why)
            }

        case .lastFM:
            switch await model.lastfm.checkSession() {
            case .missing: return .notConfigured("Not connected")
            case let .valid(user):
                return .ok(detail: user.isEmpty ? "Connected to Last.fm." : "Scrobbling as \(user).")
            case .rejected:
                return .refused("Last.fm no longer accepts this session. Authorize it again.")
            case let .failed(why): return .unreachable(why)
            }
        }
    }

}
