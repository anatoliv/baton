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

    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]

    private init() {}

    /// Raises the shared `URLCache` so the byte layer stops thrashing too.
    ///
    /// Called once at launch by both apps. The defaults (512KB memory / 10MB disk) predate
    /// anyone streaming a library this size, and the cover-art URLs are byte-identical
    /// across a run — the client's per-instance salt is stable — so they cache perfectly
    /// once there is room.
    public static func configureURLCache() {
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024)
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
        let cacheKey = key(url, side)
        if let hit = cache.object(forKey: cacheKey as NSString) { return hit }
        if let running = inFlight[cacheKey] { return await running.value }

        let task = Task<PlatformImage?, Never> { [side] in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return Self.downsample(data, to: side)
        }
        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil
        if let image { cache.setObject(image, forKey: cacheKey as NSString) }
        return image
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
