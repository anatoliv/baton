import Foundation

/// Receives a large request body straight to disk, instead of into memory.
///
/// **Why this exists rather than raising a constant.** Every other route on the gateway goes
/// through `HTTPRequestMessage.parse`, which buffers the whole request and refuses anything over
/// `BatonMCPConstants.maxRequestBytes` (1 MB). That limit is shared with the app's MCP server, so
/// raising it to carry a 7 MB article would widen what a completely unrelated endpoint accepts.
/// A file route needs its own ceiling and its own path, and once it has one there is no reason to
/// hold the bytes in memory at all.
///
/// **It is a sink, not a socket.** It takes whatever arrives, in whatever sized pieces, and says
/// whether it needs more. Both transports (`NWConnection` on Apple, a read loop on Linux) feed the
/// same object, so the framing is written once and, more to the point, can be tested by handing it
/// byte slices. That matters here specifically: the pairing short-read bug shipped
/// because its socket tests would not come up in the time available and were parked as skipped,
/// so nothing ever checked that a payload split across segments reassembled. Splitting is the
/// whole risk in this kind of code, and it is exercised directly below.
///
/// `@unchecked Sendable` because it is confined to one connection by construction: a transport
/// creates it, feeds it from that connection's read loop only, and drops it when the response is
/// written. Nothing else ever holds a reference, so the mutable state inside is never shared —
/// but the compiler cannot see that shape, and marking it is honest about which invariant is
/// carrying the safety.
public final class StreamingUpload: @unchecked Sendable {

    /// What the caller learned from the bytes it just handed over.
    public enum Step: Equatable {
        /// Keep reading; nothing is wrong.
        case needMore
        /// The body is on disk at this URL, with the request that carried it.
        case complete(URL, Request)
        /// Refuse with this status and message. The staging file, if any, is already gone.
        case rejected(status: String, message: String)
    }

    public struct Request: Equatable, Sendable {
        public var method: String
        public var path: String
        public var headers: [String: String]
        public var contentLength: Int

        public func header(_ name: String) -> String? { headers[name.lowercased()] }

        /// `Authorization: Bearer <token>`, parsed the way every other route parses it.
        ///
        /// The upload route used to do its own `replacingOccurrences(of: "Bearer ", with: "")`,
        /// which is case-sensitive, while everything else went through
        /// `HTTPRequestMessage.bearerToken`, which lower-cases the scheme. A spec-legal
        /// `authorization: bearer <token>` was therefore accepted on `GET /v1/files` and refused
        /// on `PUT /v1/files/<id>` (TBX-5308, S-F26). One auth check written twice is one that
        /// will disagree with itself; this is the same rule in the same shape.
        public var bearerToken: String? {
            guard let auth = header("authorization") else { return nil }
            let parts = auth.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Headers must arrive within this much, or the request is refused. Without a bound, a peer
    /// that opens a connection and dribbles bytes forever would hold a staging slot open with no
    /// `Content-Length` ever reached, and no cap ever tested.
    public static let maximumHeaderBytes = 32 * 1024

    /// Everything in flight, together (TBX-5308, S-F13).
    ///
    /// The per-file cap is per *connection*, so it bounds one upload and nothing else: enough
    /// simultaneous uploads, or enough abandoned ones, fill the disk a file at a time while every
    /// individual request stays inside the rules. Four full-size uploads at once is a generous
    /// ceiling for a household gateway and a cheap one to check — a directory listing, once per
    /// upload, before a byte is written.
    public static let defaultMaximumStagingBytes = 4 * FileStore.defaultMaximumFileBytes

    /// The prefix every staged file carries, so a sweep can tell its own litter from anything else
    /// that might one day share the directory.
    static let stagingPrefix = "upload-"

    private let stagingDirectory: URL
    private let maximumBodyBytes: Int
    private let maximumStagingBytes: Int
    private var headerBuffer = Data()
    private var request: Request?
    private var handle: FileHandle?
    private var stagedURL: URL?
    private var written = 0

    public init(stagingDirectory: URL, maximumBodyBytes: Int,
                maximumStagingBytes: Int = StreamingUpload.defaultMaximumStagingBytes) {
        self.stagingDirectory = stagingDirectory
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumStagingBytes = maximumStagingBytes
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    /// Where the body is being written, so a caller that gives up can clean up after itself.
    public var stagingURL: URL? { stagedURL }

    /// The head, once it has been parsed. The transport logs a refused upload and needs to know
    /// what it is refusing.
    public var parsedRequest: Request? { request }

    /// Delete every staged file, and say how many there were.
    ///
    /// Called at start-up, before the listener, and the timing is the whole argument: an upload in
    /// flight belongs to a connection this process is holding, so at start-up there are none, and
    /// anything sitting in here is litter from a kill or a container stop mid-upload. Nothing else
    /// could remove it — `FileStore.prune` cannot see these, because `list()` filters on `.json`
    /// in the parent directory (TBX-5308, S-F13).
    @discardableResult
    public static func sweepStaging(directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(stagingPrefix) {
            let url = directory.appendingPathComponent(name)
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Bytes currently staged, across every upload in flight.
    static func stagedBytes(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(stagingPrefix) }.reduce(0) { total, name in
            let path = directory.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? Int) ?? 0)
        }
    }

    public func consume(_ data: Data) -> Step {
        // Still reading headers.
        if request == nil {
            headerBuffer.append(data)
            guard let split = Self.headerBodySplit(headerBuffer) else {
                return headerBuffer.count > Self.maximumHeaderBytes
                    ? reject("431 Request Header Fields Too Large", "headers too large")
                    : .needMore
            }
            guard let parsed = Self.parseHead(headerBuffer.prefix(split.headEnd)) else {
                return reject("400 Bad Request", "malformed request")
            }
            guard parsed.contentLength >= 0 else {
                return reject("411 Length Required", "content-length is required")
            }
            guard parsed.contentLength <= maximumBodyBytes else {
                // Refused from the declared length, *before* a byte of body is read or written.
                // Checking after the fact would make the limit a way to fill the disk rather
                // than a guard against it.
                return reject("413 Payload Too Large", "at most \(maximumBodyBytes) bytes")
            }
            // Checked against what is already in flight, from the declared length, before a byte
            // is written. Refusing after the fact would make the ceiling a way to fill the disk
            // rather than a guard against it — the same argument as the per-file cap above.
            guard Self.stagedBytes(in: stagingDirectory) + parsed.contentLength <= maximumStagingBytes else {
                request = parsed
                return reject("503 Service Unavailable", "too many uploads in flight")
            }
            request = parsed
            guard open() else { return reject("500 Internal Server Error", "could not stage upload") }

            // Whatever of the body arrived alongside the headers.
            let leftover = headerBuffer.suffix(from: split.bodyStart)
            headerBuffer = Data()
            return leftover.isEmpty ? checkComplete() : append(Data(leftover))
        }
        return append(data)
    }

    /// Give up on a partial upload and take the staging file with it.
    public func cancel() {
        try? handle?.close()
        handle = nil
        if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
        stagedURL = nil
    }

    // MARK: - Body

    private func append(_ data: Data) -> Step {
        guard let request, let handle else { return .needMore }
        // Never write past the declared length. A peer that sends more than it promised must not
        // be able to grow the file beyond the size the limit was checked against.
        let room = request.contentLength - written
        guard room > 0 else { return checkComplete() }
        let slice = data.count <= room ? data : data.prefix(room)
        do {
            try handle.write(contentsOf: slice)
        } catch {
            return reject("500 Internal Server Error", "could not write upload")
        }
        written += slice.count
        return checkComplete()
    }

    private func checkComplete() -> Step {
        guard let request, let stagedURL, written >= request.contentLength else { return .needMore }
        try? handle?.close()
        handle = nil
        return .complete(stagedURL, request)
    }

    private func open() -> Bool {
        let url = stagingDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return false }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        self.stagedURL = url
        self.handle = handle
        return true
    }

    private func reject(_ status: String, _ message: String) -> Step {
        cancel()
        return .rejected(status: status, message: message)
    }

    // MARK: - Parsing

    /// Read the head without committing to anything, so a transport can decide whether this
    /// request belongs on the streaming path before it starts buffering a body it cannot hold.
    /// Nil while the terminator has not arrived.
    public static func peekHead(_ buffer: Data) -> Request? {
        guard let split = headerBodySplit(buffer) else { return nil }
        return parseHead(buffer.prefix(split.headEnd))
    }

    /// Where the head ends and the body begins, or nil while the terminator has not arrived.
    ///
    /// Searched over the whole buffer every call rather than incrementally: a head is at most
    /// 32 KB and this runs once per connection, so the simple version is the right one.
    static func headerBodySplit(_ buffer: Data) -> (headEnd: Int, bodyStart: Int)? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: terminator) else { return nil }
        return (headEnd: range.lowerBound, bodyStart: range.upperBound)
    }

    /// Request line plus headers. `Content-Length` comes back as -1 when absent, which the caller
    /// turns into a 411 rather than guessing at zero: a `PUT` with no length is a client bug, and
    /// silently storing an empty file would be the least helpful possible response to it.
    static func parseHead(_ head: Data) -> Request? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            // `.whitespacesAndNewlines`, not `.whitespaces`. The latter is space and tab only, so
            // a bare LF at either end of a value survived it and was echoed back into a response
            // head as a second line (TBX-5308, S-F26). Trimming is not the guarantee — a control
            // character in the *middle* of a value still gets through, and `safeHeaderValue` on
            // the way out is what closes that — but a value that ends in a newline has no business
            // being stored either.
            let name = line[line.startIndex ..< colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return Request(
            method: String(requestLine[0]).uppercased(),
            path: String(requestLine[1]),
            headers: headers,
            contentLength: headers["content-length"].flatMap { Int($0) } ?? -1
        )
    }
}
