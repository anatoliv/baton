import CryptoKit
import Foundation
import OSLog

private let gatewayFilesLog = Logger(subsystem: "io.tonebox.baton", category: "GatewayFiles")

/// Moving a file between this household's devices, through the home gateway.
///
/// The first thing to cross is an exported reading, but nothing here knows what a reading is.
/// Podcast episode audio and downloaded tracks would want the same road, and the repo already
/// learned this lesson the expensive way with sync: TBX-2800 surveyed three transports for
/// podcast subscriptions and radio stations, and the answer was to ride the one that already
/// existed rather than invent a second.
///
/// **In `BatonPlaybackKit` rather than the Mac app**, because both ends need it: the Mac uploads,
/// the phone collects. Putting the client next to the app that happened to need it first is how
/// you end up writing it twice, differently.
///
/// **The digest is the point.** `upload` computes SHA-256 and sends it as a header; `download`
/// recomputes it and refuses a file that does not match. The gateway never checks — it cannot,
/// on Linux, without a crypto dependency it deliberately avoids — so verification is end to end
/// between the two devices. That is stronger than hop-by-hop anyway: it catches corruption in
/// the gateway's own storage, not only in transit, exactly as `publish.sh` verifies a DMG as the
/// download host actually serves it rather than trusting the local hash.
public struct GatewayFiles: Sendable {

    public struct RemoteFile: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var contentType: String
        public var size: Int
        public var sha256: String?
        public var createdAt: Date
        public var origin: String?
    }

    public enum TransferError: LocalizedError, Equatable {
        case notConfigured
        case rejected(Int, String)
        case corrupted(expected: String, got: String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "No home gateway is set up. Add its address in Settings → Shared settings."
            case let .rejected(status, detail):
                return detail.isEmpty ? "The gateway answered with HTTP \(status)."
                                      : "The gateway refused it: \(detail)"
            case .corrupted:
                // The digests are in the log, not the message: a user can act on "it arrived
                // damaged, try again", and cannot act on two hex strings.
                return "The file arrived damaged and was discarded. Try again."
            }
        }
    }

    let gatewayURL: URL
    let token: String
    let session: URLSession

    public init(gatewayURL: URL, token: String, session: URLSession = .shared) {
        self.gatewayURL = gatewayURL
        self.token = token
        self.session = session
    }

    private func request(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: GatewayAddress.root(gatewayURL).appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Send a file. The id *is* its digest, so re-sending the same file is idempotent and two
    /// devices that export the same reading do not store it twice.
    @discardableResult
    public func upload(_ fileURL: URL, name: String, contentType: String,
                       origin: String) async throws -> RemoteFile {
        let digest = try Self.sha256(of: fileURL)
        var request = self.request("PUT", "v1/files/\(digest)")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(name, forHTTPHeaderField: "X-Baton-Name")
        request.setValue(digest, forHTTPHeaderField: "X-Baton-SHA256")
        request.setValue(origin, forHTTPHeaderField: "X-Baton-Origin")
        // `upload(fromFile:)` streams from disk rather than loading the file into memory, which
        // matters for the same reason it matters on the gateway: an article can be tens of MB.
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        try Self.check(response, data)
        return try JSONDecoder.gatewayISO8601.decode(RemoteFile.self, from: data)
    }

    public func list() async throws -> [RemoteFile] {
        let (data, response) = try await session.data(for: request("GET", "v1/files"))
        try Self.check(response, data)
        return try JSONDecoder.gatewayISO8601.decode([RemoteFile].self, from: data)
    }

    /// Fetch a file to `destination`, **verifying it before returning**.
    ///
    /// A mismatch deletes what arrived and throws. Handing back a file that failed its own
    /// checksum would make the digest decorative, and the whole reason it travels is so the
    /// receiving end is the one that decides whether the bytes are good.
    public func download(id: String, expecting sha256: String?, to destination: URL) async throws {
        let (temporary, response) = try await session.download(for: request("GET", "v1/files/\(id)"))
        try Self.check(response, Data())

        if let sha256 {
            let got = try Self.sha256(of: temporary)
            guard got == sha256 else {
                try? FileManager.default.removeItem(at: temporary)
                gatewayFilesLog.error("downloaded file failed its checksum — discarded")
                throw TransferError.corrupted(expected: sha256, got: got)
            }
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public func delete(id: String) async throws {
        let (data, response) = try await session.data(for: request("DELETE", "v1/files/\(id)"))
        try Self.check(response, data)
    }

    // MARK: - Helpers

    /// Streamed in 1 MB slices rather than `Data(contentsOf:)`, so hashing a large file costs a
    /// buffer instead of the whole file. The upload itself streams; hashing it into memory first
    /// would have given that back.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TransferError.rejected(0, "no response")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .flatMap { $0["error"] as? String } ?? ""
            throw TransferError.rejected(http.statusCode, detail)
        }
    }
}

extension JSONDecoder {
    /// Matches the gateway, which writes ISO-8601 rather than Foundation's since-2001 float.
    static var gatewayISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
