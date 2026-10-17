import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A response read only up to a limit: a voice server that answers with more than
/// any clip or voice list could be is cut off as it streams, before the whole of it is held in
/// memory. Works the same on the Mac, the iPhone and the Baton server (Linux), which is why it
/// is a delegate and not `URLSession.bytes`.
public enum CappedDownload {
    /// The most a speech server's audio for one request may be: a sentence-sized chunk is about
    /// 25 s, 2.4 MB at 48 kHz float stereo, so 32 MB is far beyond any real answer.
    public static let speechLimit = 32 * 1_024 * 1_024
    /// The most a voice list may be.
    public static let listingLimit = 1_024 * 1_024

    public struct TooLarge: Error, Equatable, CustomStringConvertible {
        public var limit: Int
        public var description: String { "the answer was larger than \(limit / 1_024 / 1_024 > 0 ? "\(limit / 1_024 / 1_024) MB" : "\(limit) bytes")" }
    }

    /// Protocol classes put in front of the session's own, for tests that stand in for a server
    /// without a socket. Empty in production.
    nonisolated(unsafe) public static var testProtocolClasses: [AnyClass] = []

    public static func data(for request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let collector = Collector(limit: limit)
        let configuration = URLSessionConfiguration.ephemeral
        if !testProtocolClasses.isEmpty {
            configuration.protocolClasses = testProtocolClasses + (configuration.protocolClasses ?? [])
        }
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.begin(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var received = Data()
        private var response: URLResponse?
        private var tooLarge = false
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

        init(limit: Int) { self.limit = limit }

        func begin(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let declared = response.expectedContentLength
            let refuse = lock.withLock { () -> Bool in
                self.response = response
                if declared > Int64(limit) { tooLarge = true }
                return tooLarge
            }
            completionHandler(refuse ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over = lock.withLock { () -> Bool in
                if received.count + data.count > limit { tooLarge = true; return true }
                received.append(data)
                return false
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, result): (CheckedContinuation<(Data, URLResponse), Error>?, Result<(Data, URLResponse), Error>) =
                lock.withLock {
                    let c = self.continuation
                    self.continuation = nil
                    if tooLarge { return (c, .failure(TooLarge(limit: limit))) }
                    if let error { return (c, .failure(error)) }
                    guard let response else { return (c, .failure(URLError(.badServerResponse))) }
                    return (c, .success((received, response)))
                }
            continuation?.resume(with: result)
        }
    }
}
