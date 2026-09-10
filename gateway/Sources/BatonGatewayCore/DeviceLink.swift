import Foundation

/// Lets the gateway reach a user's *player*. Curation runs at the server, but
/// "play it" has to happen where the speakers are — so a device (the phone, the
/// Mac) holds an authenticated long-poll open, receives commands, and posts the
/// results back.
///
/// Long-polling rather than a WebSocket on purpose: it reuses the HTTP parser
/// already in BatonMCPProtocol, survives every proxy, and needs no RFC-6455
/// framing/masking code of our own — bespoke frame parsing is bug surface with
/// nothing to show for it at one command per few seconds.
public actor DeviceLink {
    public struct Command: Sendable {
        public let id: String
        public let name: String
        /// The tool arguments as serialized JSON. `[String: Any]` is not Sendable
        /// and this crosses an actor boundary, so the bytes travel instead of the
        /// dictionary — they were about to become bytes on the wire anyway.
        public let argumentsJSON: Data
        /// When the tool call that produced this command was made (TBX-5308, S-F12).
        public let createdAt: Date
        /// How long it is worth delivering — the same wait the caller is giving it.
        ///
        /// Past this the agent has already told the user "the device didn't answer in time", so
        /// handing the command to a phone that polls a minute later starts music nobody asked for
        /// any more. A command is only worth delivering while somebody is still waiting for it.
        public let lifetime: TimeInterval

        init(id: String, name: String, argumentsJSON: Data,
             createdAt: Date = Date(), lifetime: TimeInterval = 20) {
            self.id = id
            self.name = name
            self.argumentsJSON = argumentsJSON
            self.createdAt = createdAt
            self.lifetime = lifetime
        }

        /// Still worth handing to a device.
        public func isFresh(at now: Date = Date()) -> Bool {
            now.timeIntervalSince(createdAt) < lifetime
        }

        public var json: [String: Any] {
            let arguments = (try? JSONSerialization.jsonObject(with: argumentsJSON)) as? [String: Any] ?? [:]
            return ["id": id, "name": name, "arguments": arguments]
        }
    }

    public init() {}

    /// Commands waiting for a device to pick up.
    ///
    /// Bounded and aged, both (TBX-5308, S-F12). A command used to be appended here and never
    /// removed by anything but a poll: the 20-second `dispatch` wait expired the *result* slot and
    /// left the command itself in the queue for ever. So the agent said "the device didn't answer
    /// in time" and the phone, polling a minute later, started playing — and a phone that had been
    /// away a while came back to a burst of stale play/pause/next, in order.
    private var queue: [Command] = []
    /// A ceiling for the pathological case: turns arriving faster than any device collects them.
    /// Freshness alone bounds it in practice; this bounds it in principle.
    private let maximumQueued = 16
    /// Devices parked in `poll` waiting for work, oldest first.
    ///
    /// **Plural, and that is the fix.** This was one slot, and `awaitCommand` assigned into it —
    /// so a second device polling while the first was parked overwrote that continuation without
    /// resuming it. The first poll then never returned: its task stayed suspended for ever and
    /// the runtime said so, four times over one uptime, as
    /// `SWIFT TASK CONTINUATION MISUSE: awaitCommand(timeout:) leaked its continuation!`
    ///
    /// Two devices is the ordinary case here, not an edge one — the Mac and the phone both hold
    /// this poll open whenever both are running — so the single slot was being clobbered as a
    /// matter of routine rather than in some rare race.
    ///
    /// Each waiter carries its own id so its own timer expires it. The old `expirePoll` resumed
    /// whatever happened to be waiting, which meant one device's timeout could cut another
    /// device's hold short.
    private var waitingDevices: [(id: UUID, continuation: CheckedContinuation<Command?, Never>)] = []
    /// Tool calls waiting for the device's answer, keyed by command id.
    private var pendingResults: [String: CheckedContinuation<(text: String, isError: Bool), Never>] = [:]
    /// When the device last polled — "connected" means recently enough to trust.
    private var lastPollAt: Date?

    /// Polls this process has served, and the most waiters it has ever held at once.
    ///
    /// The empty poll is invisible in the request log on purpose (TBX-4045: a 25-second hold per
    /// device is ~7,000 lines a day), and that is the only trace `awaitCommand` leaves — a poll
    /// logs 200 only when it carries a command, which needs a `/v1/agent` turn to exist. So over
    /// seven days and 25,118 lines `/v1/device/poll` appeared **zero** times, identically whether
    /// it had been called ten thousand times or never. Counting here restores the answer without
    /// putting a single line back in the log.
    private var pollsServed = 0
    private var commandsDelivered = 0
    /// The high-water mark of `waitingDevices.count`, and the point of the whole exercise.
    ///
    /// The TBX-4029 leak needed **two waiters parked at the same time**; with one it cannot fire.
    /// So `grep -c MISUSE` → 0 only means something next to a peak of 2 or more — below that the
    /// zero says the bug was never given the chance, not that it is fixed. That distinction is
    /// exactly what the 2026-09-05 audit could not make.
    private var peakWaitersParked = 0

    /// True when a device has polled recently enough to route playback to it.
    public var isDeviceConnected: Bool {
        guard let lastPollAt else { return false }
        return Date().timeIntervalSince(lastPollAt) < 90
    }

    /// What the device link has been doing this uptime — the whole of it, read in one actor hop
    /// so the numbers agree with each other and with the waiter list they were taken from.
    ///
    /// Counts and ages only. No device identifier, no address, no token: this is served on
    /// `/health`, which is the one unauthenticated route.
    public var pollStats: PollStats {
        PollStats(
            pollsServed: pollsServed,
            commandsDelivered: commandsDelivered,
            waitersParked: waitingDevices.count,
            peakWaitersParked: peakWaitersParked,
            lastPollAt: lastPollAt,
            isDeviceConnected: isDeviceConnected
        )
    }

    /// A snapshot of the poll counters.
    public struct PollStats: Sendable, Equatable {
        /// Every call to `awaitCommand`, whether it returned a command or expired empty.
        public let pollsServed: Int
        /// Polls that carried a command back — the ones the request log can already see.
        public let commandsDelivered: Int
        /// Devices parked in a hold right now.
        public let waitersParked: Int
        /// The most that have been parked simultaneously since this process started.
        public let peakWaitersParked: Int
        /// When a device last polled or posted a result, or nil if none ever has.
        public let lastPollAt: Date?
        public let isDeviceConnected: Bool

        public init(pollsServed: Int, commandsDelivered: Int, waitersParked: Int,
                    peakWaitersParked: Int, lastPollAt: Date?, isDeviceConnected: Bool) {
            self.pollsServed = pollsServed
            self.commandsDelivered = commandsDelivered
            self.waitersParked = waitersParked
            self.peakWaitersParked = peakWaitersParked
            self.lastPollAt = lastPollAt
            self.isDeviceConnected = isDeviceConnected
        }
    }

    // MARK: - Device side

    /// Called by `GET /v1/device/poll`. Returns the next command, or nil when the
    /// hold expires (the device immediately polls again).
    public func awaitCommand(timeout: TimeInterval = 25) async -> Command? {
        lastPollAt = Date()
        pollsServed += 1
        // Anything nobody is waiting for any more is dropped rather than delivered. Dropped here
        // as well as on expiry because a queued command's own timer is the only other thing that
        // would remove it, and a process that was busy elsewhere can leave that late.
        queue.removeAll { !$0.isFresh() }
        if !queue.isEmpty {
            commandsDelivered += 1
            return queue.removeFirst()
        }

        let id = UUID()
        let command = await withCheckedContinuation { (continuation: CheckedContinuation<Command?, Never>) in
            waitingDevices.append((id: id, continuation: continuation))
            peakWaitersParked = max(peakWaitersParked, waitingDevices.count)
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                await self.expirePoll(id)
            }
        }
        // Back on the actor, so this counts once per poll and cannot race the other waiters.
        if command != nil { commandsDelivered += 1 }
        return command
    }

    /// Expire **this** poll, named by id. Resuming "whoever is waiting" would let one device's
    /// timer end another device's hold early, and would resume a continuation twice once more
    /// than one device can be parked at a time.
    private func expirePoll(_ id: UUID) {
        guard let index = waitingDevices.firstIndex(where: { $0.id == id }) else { return }
        let waiting = waitingDevices.remove(at: index).continuation
        waiting.resume(returning: nil)
    }

    /// Called by `POST /v1/device/result` — hands the answer to the waiting tool.
    public func deliverResult(id: String, text: String, isError: Bool) {
        lastPollAt = Date()
        guard let continuation = pendingResults.removeValue(forKey: id) else { return }
        continuation.resume(returning: (text, isError))
    }

    // MARK: - Tool side

    /// Sends a command to the connected device and waits for its answer. Returns
    /// nil when no device is listening, so the caller can answer honestly instead
    /// of pretending something played.
    public func dispatch(name: String, argumentsJSON: Data, timeout: TimeInterval = 20) async -> (text: String, isError: Bool)? {
        guard isDeviceConnected else { return nil }
        let command = Command(id: UUID().uuidString, name: name, argumentsJSON: argumentsJSON,
                              createdAt: Date(), lifetime: timeout)

        // The most recently parked device, which is what the single slot effectively chose
        // before: a newer poll replaced an older one, so the newest always won. Routing is
        // deliberately unchanged here; only the leaking of everyone else is fixed.
        if let waiting = waitingDevices.popLast()?.continuation {
            waiting.resume(returning: command)
        } else {
            queue.removeAll { !$0.isFresh() }
            queue.append(command)
            if queue.count > maximumQueued { queue.removeFirst(queue.count - maximumQueued) }
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(text: String, isError: Bool), Never>) in
            pendingResults[command.id] = continuation
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                await self.expireResult(id: command.id)
            }
        }
        return result
    }

    /// Give up waiting for this command's answer, and take the command with it.
    ///
    /// Removing the queue entry is the fix: the caller has been told nothing happened, so the
    /// command must not still be sitting there for the next poll to pick up and play.
    private func expireResult(id: String) {
        queue.removeAll { $0.id == id }
        guard let continuation = pendingResults.removeValue(forKey: id) else { return }
        continuation.resume(returning: ("The device didn't answer in time.", true))
    }

    /// How many commands are waiting for a device right now. Bounded, and asserted to be.
    public var queuedCommandCount: Int { queue.count }
}

/// The body of `GET /health`.
///
/// **Here, not in `main.swift`, for the reason `RequestLog` gives:** the routing lives in an
/// executable target no test can import, so anything decided there is decided untested. What
/// this returns is asserted in `GatewayHealthTests` instead.
///
/// `/health` is the one unauthenticated route, so what goes in is counts, ages and a sentence —
/// never a device identifier, an address or a token. There is nothing here for an anonymous
/// caller to learn beyond "a Baton device is or is not currently talking to this gateway", which
/// is what the route exists to say.
public enum GatewayHealth {

    /// Render the health body.
    ///
    /// Every counter is **since `started_at`**, and a container restart silently sets them all
    /// back to zero — which is how a healthy gateway that bounced a minute ago can look exactly
    /// like one nothing has ever polled. Rather than leave that to the reader, uptime travels
    /// beside the counters and `summary` says the two of them together in a sentence.
    ///
    /// `status` is **derived** from the Navidrome probe rather than passed in beside it.
    /// The route used to compute the string itself, which made it possible for the headline and
    /// the detail to disagree; here they cannot, because there is only one of them.
    public static func body(navidrome: HealthProbe.Report, startedAt: Date,
                            polls: DeviceLink.PollStats, now: Date = Date()) -> String {
        let status = navidrome.reachable ? "ok" : "navidrome-unreachable"
        let uptime = max(0, Int(now.timeIntervalSince(startedAt).rounded()))
        var link: [String: Any] = [
            "polls_served": polls.pollsServed,
            "commands_delivered": polls.commandsDelivered,
            "waiters_parked": polls.waitersParked,
            "peak_waiters_parked": polls.peakWaitersParked,
            "device_connected": polls.isDeviceConnected,
            "counters_since": "started_at: they reset on restart, so read them next to uptime_seconds",
            "summary": summary(polls: polls, uptime: uptime, now: now),
        ]
        if let lastPollAt = polls.lastPollAt {
            link["last_poll_seconds_ago"] = max(0, Int(now.timeIntervalSince(lastPollAt).rounded()))
        } else {
            link["last_poll_seconds_ago"] = NSNull()
        }
        let payload: [String: Any] = [
            "status": status,
            "started_at": iso8601(startedAt),
            "uptime_seconds": uptime,
            "device_link": link,
            "navidrome": [
                "reachable": navidrome.reachable,
                "probe": navidrome.outcome.rawValue,
                "probe_ms": max(0, Int((navidrome.elapsed * 1000).rounded())),
                "probe_timeout_ms": max(0, Int((navidrome.timeout * 1000).rounded())),
                "summary": navidromeSummary(navidrome),
            ],
        ]
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"status":"\#(status)"}"# }
        return text
    }

    /// What the probe is entitled to claim, in a sentence.
    ///
    /// `status: navidrome-unreachable` is a headline, and a short probe cannot fully earn it: two
    /// seconds of silence means the server did not answer in two seconds, which is consistent with
    /// a dead server, a sleeping NAS, a saturated link and a reverse proxy still waking up. The
    /// `failed` case is weaker still — `ping.view` authenticates, so wrong credentials land here
    /// too. Both are said out loud rather than left for the reader to infer from a status string.
    static func navidromeSummary(_ report: HealthProbe.Report) -> String {
        let took = max(0, Int((report.elapsed * 1000).rounded()))
        let bound = max(0, Int((report.timeout * 1000).rounded()))
        switch report.outcome {
        case .answered:
            return "ping answered in \(took)ms"
        case .timedOut:
            return "ping did not answer within \(bound)ms; the server may be down, or merely "
                + "slower than the probe waits: this is not proof it is down"
        case .failed:
            return "ping failed after \(took)ms; the server refused or rejected it: that is "
                + "usually unreachable, but a credential or proxy error looks the same from here"
        }
    }

    /// One sentence a person can act on, so nobody has to reason about restart amnesia to read
    /// the numbers. This is the line that answers "has anything polled recently?".
    static func summary(polls: DeviceLink.PollStats, uptime: Int, now: Date) -> String {
        guard let lastPollAt = polls.lastPollAt else {
            return "no device has polled in the \(uptime)s this process has been up"
        }
        let ago = max(0, Int(now.timeIntervalSince(lastPollAt).rounded()))
        return "last device poll \(ago)s ago; \(polls.pollsServed) polls served over \(uptime)s of uptime"
    }

    /// Built per call rather than cached in a static: `ISO8601DateFormatter` is a mutable class
    /// and not `Sendable`, so a shared one is a data race the compiler rightly refuses. `/health`
    /// is polled every 30 seconds at most — one formatter allocation there is free.
    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
