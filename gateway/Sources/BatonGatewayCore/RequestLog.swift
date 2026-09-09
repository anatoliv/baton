import Foundation

/// One line per request the gateway serves.
///
/// The gateway logged nothing at all: over a full uptime `docker logs baton-gateway` was a single
/// "listening on :8788" and whatever the Swift runtime shouted on its own. That is how the leaked
/// continuation of TBX-4029 came to light — by accident, while looking for something else.
///
/// It cost a diagnosis too. TBX-4019 was "a rename on the Mac never reaches the phone", and the
/// one question that would have settled it in seconds — *is the phone calling `/v1/state` at all?*
/// — had no answer here. It was settled instead by exporting the Mac's `UserDefaults`, decoding a
/// ledger blob and comparing `device` stamps across 24 keys.
///
/// **A pure function, in the testable target, deliberately.** The routing lives in `main.swift`,
/// which no test can import; putting the decision of *what gets written* there too would repeat
/// the mistake `Package.swift` already records. Everything below is asserted in `RequestLogTests`.
public enum RequestLog {

    /// The device long-poll. Returns every 25 seconds per device whether or not there is anything
    /// to say, so at two devices it alone would be about seven thousand lines a day — enough to
    /// bury every line worth reading.
    static let pollPath = "/v1/device/poll"

    /// The state endpoint, and the User-Agent `compose.yml`'s healthcheck calls it with.
    ///
    /// The container probes `GET /v1/state` **without** a token and requires a 401, which asserts
    /// that the process is up, routing, *and* enforcing the bearer token — an assertion a probe
    /// against the unauthenticated `/health` cannot make, which is why the check was not simply
    /// moved there. The cost was 2,880 identical lines a day: 90.6% of the log over an
    /// eight-day window, against 6.5% for all real device traffic, and it derailed one
    /// investigation that had to strip 93.5% of the lines before anything was legible.
    static let statePath = "/v1/state"
    static let healthcheckAgent = "baton-healthcheck/1"

    /// The line to write, or nil when this request should not be logged at all.
    ///
    /// - Parameters:
    ///   - status: the HTTP status actually sent, so a 401 or a 404 is visible rather than inferred.
    ///   - userAgent: used only to tell callers apart. **No token is accepted by this function at
    ///     all**, which is a stronger guarantee than remembering not to pass one.
    public static func line(method: String, path: String, status: Int,
                            userAgent: String?, milliseconds: Int) -> String? {
        // An empty poll is the gateway working exactly as intended and is worth nothing in a log.
        // A poll that carried a command is worth a great deal, so that one is kept.
        if method == "GET", path == pollPath, status == 204 { return nil }

        // The Docker healthcheck, and **only when it is passing**. Matching on the whole expected
        // shape rather than on the agent alone is the point: the healthcheck exists to notice that
        // auth stopped being enforced, and a filter keyed on "who called" would silence precisely
        // the moment it fires. A 200 here (the token check gone), a 500, or that agent on any other
        // path all still reach the log — a broken healthcheck gets louder, not quieter.
        //
        // What this does hide, stated so it stays chosen: an unauthenticated `GET /v1/state`
        // spoofing this agent. It is loopback-only in practice, the caller still gets a 401 and
        // learns nothing, and the User-Agent is in a public repo — so the honest description is
        // that one class of *refused* probe becomes invisible. When the source address lands in
        // this line (the open recommendation on TBX-5065), gate this on 127.0.0.1 and even that
        // goes away.
        if method == "GET", path == statePath, status == 401, caller(userAgent) == healthcheckAgent {
            return nil
        }
        return "\(method) \(path) \(status) \(milliseconds)ms \(caller(userAgent))"
    }

    /// Write the line for a request that has just been answered, if it deserves one.
    ///
    /// **Every response goes through here, including an upload's** (TBX-5308, S-F26). The logging
    /// used to sit in the router's own wrapper, which the streaming upload never reaches — so the
    /// one route that writes caller-controlled bytes to disk *before* checking a token left no
    /// trace at all, and a phone whose uploads were all refused looked identical to one that never
    /// tried. Moved into the transport, where both paths converge, it cannot be forgotten for a
    /// route again: that is the same reason the wrapper was chosen over per-route calls.
    public static func write(method: String, path: String, response: Data,
                             userAgent: String?, started: Date, now: Date = Date(),
                             to log: (String) -> Void) {
        guard let line = line(
            method: method,
            path: safePath(path),
            status: status(ofResponse: response),
            userAgent: userAgent,
            milliseconds: Int(now.timeIntervalSince(started) * 1000)
        ) else { return }
        log(line)
    }

    /// The default sink.
    ///
    /// `FileHandle.standardOutput.write`, not `print`. Swift buffers stdout when it is a pipe
    /// rather than a terminal, and under Docker it is always a pipe — so `print` left every line
    /// sitting in the buffer and `docker logs` showed nothing at all. Deployed once that way and
    /// caught by looking at the running container, which no test could have told me.
    public static let standardOutput: @Sendable (String) -> Void = { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static let filesPrefix = "/v1/files/"

    /// The path as it is safe to write down.
    ///
    /// A file id is chosen by the caller and becomes part of a line in a file that persists, so it
    /// goes through the same whitelist the store uses before it is written anywhere — the log must
    /// not be the one place a rejected id is quoted back verbatim. Control characters are stripped
    /// from every path for the same reason `caller` filters a User-Agent: one line per request is
    /// a format, and unvalidated input must not be able to break it.
    public static func safePath(_ path: String) -> String {
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let cleaned = String(withoutQuery.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F })
        let capped = cleaned.count <= 120 ? cleaned : String(cleaned.prefix(120))
        guard capped.hasPrefix(filesPrefix) else { return capped.isEmpty ? "/" : capped }
        let id = String(capped.dropFirst(filesPrefix.count))
        guard !id.isEmpty else { return filesPrefix }
        return filesPrefix + (FileStore.sanitize(id) ?? "invalid")
    }

    /// A short, safe name for who called.
    ///
    /// Only the first whitespace-delimited component of the User-Agent, filtered to characters a
    /// product token actually uses, capped, and refused outright if it looks like a credential.
    /// A User-Agent is attacker-controlled input on any other network; here it is at least
    /// unvalidated input being written to a file that persists.
    static func caller(_ userAgent: String?) -> String {
        guard let raw = userAgent?.split(separator: " ").first.map(String.init), !raw.isEmpty
        else { return "unknown" }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789./-_")
        let cleaned = String(raw.unicodeScalars.filter { allowed.contains($0) })
        guard !cleaned.isEmpty, cleaned.count <= 40, !looksLikeSecret(cleaned) else { return "unknown" }
        return cleaned
    }

    /// Deliberately blunt. The cost of dropping a legitimate caller name is a log line reading
    /// "unknown"; the cost of writing a credential into a persistent log is a rotation and an
    /// afternoon. The repo already scans for these shapes before every push.
    static func looksLikeSecret(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if lowered.hasPrefix("bearer") || lowered.hasPrefix("sk-") || lowered.hasPrefix("sntry") {
            return true
        }
        // A long unbroken run of letters and digits is what a token looks like and what a product
        // token does not: real ones carry a slash or a dot ("Baton/1.0", "CFNetwork/3826.500.111").
        let unbroken = value.allSatisfy { $0.isLetter || $0.isNumber }
        return unbroken && value.count >= 24
    }

    /// The status code out of a raw HTTP response, so the logger reports what was actually sent
    /// rather than what the caller believed it sent. Responses are built in a dozen places here.
    public static func status(ofResponse response: Data) -> Int {
        guard let firstLine = String(decoding: response.prefix(64), as: UTF8.self)
            .split(separator: "\r\n", maxSplits: 1).first else { return 0 }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return 0 }
        return code
    }
}
