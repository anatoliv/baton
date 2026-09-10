import SwiftUI
#if canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif
import ImageIO

/// One decoded cover, once.
///
/// Neither app had a decoded-image cache of any kind. `AsyncImage` caches the *bytes* in
/// `URLCache` and decodes on every appearance, and the default `URLCache` is 512KB in
/// memory — against a 2,600-album library, that is a cache that can hold about four covers.
/// So scrolling a grid re-downloaded and re-decoded artwork it had shown seconds earlier.
///
/// The Mac made it worse: `MusicMediaCard` builds *two* `AsyncImage`s for the same URL —
/// one blurred fill, one cover on top — so every card decoded the same JPEG twice, on
/// twenty grid surfaces. Nothing was wrong with either view on its own, which is why it
/// survived: the cost only exists in the pair.
@MainActor
public final class ArtworkCache {
    public static let shared = ArtworkCache()

    /// Bounded by *count*, not bytes, and deliberately small.
    ///
    /// Downsampled covers are a few hundred KB each; a few hundred of them is a grid's
    /// worth of scrollback and nothing more. An unbounded cache over a 2,600-album library
    /// is just a memory leak with a friendly name — which is exactly what the three
    /// unbounded palette caches were (see W5.2).
    private let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 240
        return cache
    }()

    private var inFlight: [String: Task<(PlatformImage?, LoadOutcome), Never>] = [:]

    /// Internal rather than private so a test can take a fresh one. The app uses `shared`;
    /// a test that used it too would inherit the decoded covers and the refusal debounce of
    /// whichever test ran before it, which is how an order-dependent suite starts.
    init() {}

    /// What a cover-art request actually did, as opposed to whether an image came back.
    ///
    /// The loader used to discard the response entirely, so a 401 from a refused credential,
    /// a 404 for a cover the server no longer has, and a dropped Wi-Fi connection were one
    /// outcome: nil. A whole grid of blank artwork with nothing on screen saying why.
    public enum LoadOutcome: Equatable, Sendable {
        case loaded
        /// The server answered and refused the credential (HTTP 401 or 403).
        case refused(status: Int)
        /// The server answered with some other non-success status.
        case serverError(status: Int)
        /// Nothing answered: offline, TLS, timeout.
        case unreachable
        /// It answered with bytes that are not an image this can decode.
        case undecodable
    }

    /// Called at most once every `refusalNoticeInterval` when the server refuses the
    /// credential on a cover-art request.
    ///
    /// A closure rather than a banner of its own, because both apps already have a surface
    /// for "your sign-in was refused" and neither needed a second one: the Mac raises the
    /// browse store's `lastError`, the phone re-pings and sends you to setup only if the
    /// ping agrees. Wired once at launch, the same shape as `TransportIntentHandler`.
    public var onCredentialRefused: (() -> Void)?

    /// The last refusal this saw, kept so a test (and a support conversation) can name the
    /// status rather than infer it.
    public private(set) var lastRefusal: LoadOutcome?

    private var lastRefusalNotice: Date?
    /// A grid puts sixty covers on screen at once and every one of them is refused by the
    /// same credential. Announce the first and swallow the rest.
    nonisolated static let refusalNoticeInterval: TimeInterval = 30

    /// True when this refusal is the one worth telling the app about.
    @discardableResult
    func noteRefusal(status: Int, now: Date = Date()) -> Bool {
        lastRefusal = .refused(status: status)
        if let last = lastRefusalNotice, now.timeIntervalSince(last) < Self.refusalNoticeInterval {
            return false
        }
        lastRefusalNotice = now
        return true
    }

    /// Sizes the shared `URLCache` and arms the artwork byte cache.
    ///
    /// Called once at launch by both apps. This used to raise `URLCache.shared` to 512MB on
    /// disk on the theory that cover-art URLs are byte-identical across a run. They were not:
    /// the Subsonic salt was stable per `NavidromeClient` instance and both apps build a
    /// client per request, so 645 cover-art entries in the owner's real cache carried 645
    /// distinct salts for 456 distinct covers. The disk tier could never serve a repeat, and
    /// in exchange it wrote a username and 645 `md5(password + salt)` tokens into
    /// `Cache.db`'s `request_key` column in cleartext. Measurements are on TBX-5349.
    ///
    /// TBX-5359 has since moved the salt to a per-server cache, so signed URLs do repeat now.
    /// That does not give this back to `URLCache.shared`: the key would still be a cleartext
    /// username and a password-derived token written to disk, and it would still miss on every
    /// password change. The auth-stripped key below holds no credential and survives one.
    ///
    /// So: `URLCache.shared` keeps a memory tier and stores nothing on disk (the JSON API
    /// bodies it held came to 217KB in total), and artwork gets its own disk cache keyed by
    /// the URL with the auth query items removed, which is the key that actually repeats.
    public static func configureURLCache() {
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 0)
        // Drop what the old posture already wrote, rather than leaving credential-bearing
        // URLs on disk until something else happens to evict them.
        URLCache.shared.removeAllCachedResponses()
        _ = byteCache
    }

    /// The byte layer for cover art, keyed without credentials.
    ///
    /// `URLCache` is documented as safe to use from any thread; the compiler cannot see that
    /// through a `@MainActor` type, and this is deliberately touched off the main actor so a
    /// 300KB disk write does not land in the middle of a scroll.
    /// A `var` so a test can put a memory-only cache here instead of writing the app's real
    /// one. Nothing outside the module can reach it.
    nonisolated(unsafe) static var byteCache: URLCache = {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("BatonArtwork", isDirectory: true)
        return URLCache(memoryCapacity: 32 * 1024 * 1024,
                        diskCapacity: 512 * 1024 * 1024,
                        directory: directory)
    }()

    /// A stored cover older than this is refetched. Album art does change, and a manual
    /// cache does not get `Cache-Control` handling for free.
    nonisolated static let byteCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60
    nonisolated static let storedAtKey = "batonStoredAt"

    /// Query items that identify the caller rather than the resource.
    ///
    /// `u`/`t`/`s` is Subsonic token auth, `p` is the legacy plaintext password, `apiKey` is
    /// the OpenSubsonic form. Everything else (`id`, `size`, `v`, `c`) names the picture.
    nonisolated static let authQueryItems: Set<String> = ["u", "t", "s", "p", "apiKey"]

    /// The URL this cover is cached under: the request with its credentials taken out.
    ///
    /// Two requests for the same cover from two `NavidromeClient` instances differ only in
    /// `t` and `s`, so keying on the full URL stored the same image twice and hit neither.
    nonisolated static func cacheKeyURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return url }
        let kept = items.filter { !authQueryItems.contains($0.name) }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    /// 2xx is an image; 401 and 403 are a refused credential; anything else is the server
    /// having a problem. Kept pure so the mapping can be asserted without a network.
    nonisolated static func classify(status: Int) -> LoadOutcome {
        switch status {
        case 200 ... 299: .loaded
        case 401, 403: .refused(status: status)
        default: .serverError(status: status)
        }
    }

    /// The session artwork fetches through. Its own, with no `URLCache` of its own: the
    /// cache lookup and store are done by hand under the auth-stripped key, and a session
    /// cache would quietly re-add the credential-bearing one alongside it.
    /// A `var` for the same reason as `byteCache`: a test points it at a stub protocol. A
    /// session's `protocolClasses` are fixed when it is built, so registering a stub globally
    /// after the fact would not reach this one.
    nonisolated(unsafe) static var session: URLSession = makeSession()

    nonisolated static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration)
    }

    /// Fetches the bytes for a cover, saying what happened.
    ///
    /// `nonisolated async`, so the request and the disk write run off the main actor.
    nonisolated static func fetchBytes(for url: URL, now: Date = Date()) async -> (Data?, LoadOutcome) {
        let keyRequest = URLRequest(url: cacheKeyURL(for: url))
        if let hit = byteCache.cachedResponse(for: keyRequest), !isStale(hit, now: now) {
            return (hit.data, .loaded)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            // A non-HTTP response (a `file://` cover in the demo library) has no status to
            // check and is treated as delivered.
            let outcome = (response as? HTTPURLResponse).map { classify(status: $0.statusCode) } ?? .loaded
            guard outcome == .loaded else { return (nil, outcome) }
            let stored = CachedURLResponse(response: response, data: data,
                                           userInfo: [storedAtKey: now.timeIntervalSince1970],
                                           storagePolicy: .allowed)
            byteCache.storeCachedResponse(stored, for: keyRequest)
            return (data, .loaded)
        } catch {
            return (nil, .unreachable)
        }
    }

    nonisolated static func isStale(_ response: CachedURLResponse, now: Date) -> Bool {
        guard let storedAt = response.userInfo?[storedAtKey] as? TimeInterval else { return true }
        return now.timeIntervalSince1970 - storedAt > byteCacheMaxAge
    }

    private func key(_ url: URL, _ side: CGFloat) -> String { "\(url.absoluteString)|\(Int(side))" }

    public func cached(_ url: URL, side: CGFloat) -> PlatformImage? {
        cache.object(forKey: key(url, side) as NSString)
    }

    /// Fetches and downsamples, coalescing concurrent requests for the same cover.
    ///
    /// Coalescing matters more here than usual: a card asks for the same URL from its blur
    /// and its cover in the same frame, and a grid scroll can put twenty cards on screen at
    /// once. Without this they would be twenty concurrent identical downloads.
    public func image(for url: URL, side: CGFloat) async -> PlatformImage? {
        await load(url, side: side).0
    }

    /// The same load, with the outcome the caller usually throws away.
    ///
    /// The coalescing covers the whole load, network included: that is the point of it, and
    /// a version that only shared the decode would put twenty identical requests on the wire
    /// for one row of a grid.
    @discardableResult
    func load(_ url: URL, side: CGFloat) async -> (PlatformImage?, LoadOutcome) {
        let cacheKey = key(url, side)
        if let hit = cache.object(forKey: cacheKey as NSString) { return (hit, .loaded) }
        if let running = inFlight[cacheKey] { return await running.value }

        let task = Task<(PlatformImage?, LoadOutcome), Never> { [side] in
            let (data, outcome) = await Self.fetchBytes(for: url)
            guard let data, outcome == .loaded else { return (nil, outcome) }
            guard let image = Self.downsample(data, to: side) else { return (nil, .undecodable) }
            return (image, .loaded)
        }
        inFlight[cacheKey] = task
        let (image, outcome) = await task.value
        inFlight[cacheKey] = nil

        // Nothing about a failure is remembered, so the next scroll past this cover asks
        // again rather than showing a hole for the rest of the session.
        if let image { cache.setObject(image, forKey: cacheKey as NSString) }
        if case let .refused(status) = outcome, noteRefusal(status: status) {
            // Only the first refusal in the window reaches the app: a grid refuses sixty
            // covers at once and they are all the same news.
            onCredentialRefused?()
        }
        return (image, outcome)
    }

    /// Decodes at the size actually being drawn.
    ///
    /// A 1000px cover rendered into a 160pt cell is decoded to a full-size bitmap and then
    /// scaled down for display — several megabytes of memory per card for pixels nobody
    /// sees. `CGImageSourceCreateThumbnailAtIndex` decodes straight to the target instead.
    nonisolated static func downsample(_ data: Data, to side: CGFloat) -> PlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        // Points to pixels. 3x covers the densest screen either app runs on; guessing low
        // here shows as soft artwork on a Retina display, which is worse than the memory.
        let pixels = max(1, side * 3)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        #if canImport(AppKit)
        return NSImage(cgImage: thumbnail, size: .zero)
        #else
        return UIImage(cgImage: thumbnail)
        #endif
    }
}

/// A cover, decoded once and handed to the caller.
///
/// The closure form matters: `MusicMediaCard` needs the *same* image for its blurred fill
/// and its sharp cover, and two `AsyncImage`s cannot share one decode.
public struct CachedArtwork<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let side: CGFloat
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var loaded: PlatformImage?

    public init(url: URL?, side: CGFloat,
                @ViewBuilder content: @escaping (Image) -> Content,
                @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.side = side
        self.content = content
        self.placeholder = placeholder
    }

    public var body: some View {
        Group {
            if let loaded {
                content(Image(platformImage: loaded))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { loaded = nil; return }
            // Synchronous hit first: a cache that still shows a placeholder for one frame
            // makes a scroll flicker, which is the thing this exists to stop.
            if let hit = ArtworkCache.shared.cached(url, side: side) {
                loaded = hit
                return
            }
            loaded = await ArtworkCache.shared.image(for: url, side: side)
        }
    }
}

public extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
