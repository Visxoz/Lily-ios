import CoreGraphics
import Foundation
import ImageIO
import os

/// Artwork, fetched and decoded off the main actor at the size it is shown,
/// as ytm-native's `images.rs`.
///
/// Three tiers: decoded images in memory, bounded by bytes; the downloads
/// in `HTTP.media`'s disk URL cache; then the network. Requests for an image
/// already on its way share its download, which is cancelled once no one
/// waits for it, as a page's artwork is once the page is left.
public final class ImagePipeline: Sendable {
    public static let shared = ImagePipeline()

    /// The playing song's artwork, in pixels: Now Playing's (the phone's
    /// width less its margins, at 3x) and the lock screen's, so both share
    /// one decode, fetched ahead with the song.
    public static let playerEdge = 1080
    /// Any artwork drawn 56 points or smaller (56 at 3x), in pixels. Small
    /// artwork shares this one size, as ytm-native's fixed buckets, so a row's
    /// copy, the mini player's and the one fetched ahead are the same decode.
    public static let smallEdge = 168

    /// Decoded artwork kept for reuse, in bytes: ytm-native's 32 MB scaled
    /// for decodes at 3x rather than a desktop's 1x, so a Home feed's cards
    /// and the playing song's 1080-pixel copy, fetched ahead, outlast a
    /// scroll. NSCache still sheds it under memory pressure.
    private static let memoryLimit = 96 << 20
    /// Prefetches at once: few, so the artwork a view asks for itself never
    /// queues behind a page's worth for the media host's connections.
    private static let prefetchWidth = 4
    private static let log = Logger(subsystem: "YTMusic", category: "ImagePipeline")

    private let memory = MemoryCache(limit: memoryLimit)
    private let downloads = Downloads()

    /// Artwork from `url` scaled so its shorter side is `pixelEdge` pixels,
    /// or nil when it can't be had or the caller was cancelled.
    public func image(for url: String, pixelEdge: Int) async -> CGImage? {
        let key = Self.key(url, pixelEdge)
        if let image = memory[key] { return image }
        return await downloads.image(for: key) { [memory] in
            // Another request may have finished it since the check above.
            if let image = memory[key] { return image }
            guard let image = await Self.fetch(url, edge: pixelEdge) else { return nil }
            memory.insert(image, for: key)
            return image
        }
    }

    /// Artwork already decoded at `pixelEdge`, without fetching.
    public func cachedImage(for url: String, pixelEdge: Int) -> CGImage? {
        memory[Self.key(url, pixelEdge)]
    }

    /// Downloads artwork into the disk URL cache without decoding it, so a
    /// page's art is on the device before it scrolls in, as ytm-native's
    /// `load_art`; memory stays bounded as nothing is decoded. Artwork
    /// already decoded, on its way or downloaded is skipped, and nothing more
    /// starts once the caller is cancelled.
    public func prefetch(_ urls: [String], pixelEdge: Int) async {
        await withTaskGroup(of: Void.self) { group in
            var seen = Set<String>()
            var running = 0
            for url in urls {
                if running == Self.prefetchWidth {
                    _ = await group.next()
                    running -= 1
                }
                guard !Task.isCancelled else { return }
                let key = Self.key(url, pixelEdge)
                guard seen.insert(key).inserted, memory[key] == nil else { continue }
                group.addTask { [downloads] in
                    await downloads.prefetch(key) { await Self.download(url, edge: pixelEdge) }
                }
                running += 1
            }
        }
    }

    /// Keyed by what is requested, so artwork stored at different sizes, as
    /// a row's and an album header's copies are, shares one decode and one
    /// download.
    static func key(_ url: String, _ edge: Int) -> String {
        "\(edge):\(isWide(url) ? url : Thumbnail.resized(url, edge: edge))"
    }

    @concurrent
    private static func fetch(_ url: String, edge: Int) async -> CGImage? {
        guard let request = requestURL(url, edge: edge) else {
            log.debug("Skipped artwork from a host the app doesn't use.")
            return nil
        }
        do {
            let (data, _) = try await HTTP.data(for: URLRequest(url: request), session: HTTP.media)
            try Task.checkCancellation()
            guard let image = decode(data, edge: edge) else {
                log.debug("Undecodable artwork.")
                return nil
            }
            return image
        } catch {
            return nil
        }
    }

    /// Fetches `url` at `edge` for the URL cache to keep, unless it already
    /// holds it. The bytes are dropped: `fetch` reads them back from the cache.
    @concurrent
    private static func download(_ url: String, edge: Int) async {
        guard let request = requestURL(url, edge: edge).map({ URLRequest(url: $0) }),
              HTTP.media.configuration.urlCache?.cachedResponse(for: request) == nil
        else { return }
        _ = try? await HTTP.data(for: request, session: HTTP.media)
    }

    /// The URL to fetch: googleusercontent renders any size, so it is asked
    /// for the pixels drawn rather than a larger rendition. A wide one, an
    /// artist's banner, keeps the rendition it came with, as a square size
    /// would crop it; ytm-native leaves its banners alone the same way.
    static func requestURL(_ url: String, edge: Int) -> URL? {
        guard isWide(url) else { return Thumbnail.url(url, edge: edge) }
        return URL(string: url).flatMap { HTTP.isAllowed($0) ? $0 : nil }
    }

    /// Whether a googleusercontent URL's size, as `=w1440-h600-p-l90-rj`,
    /// names a width and height that differ.
    static func isWide(_ url: String) -> Bool {
        guard url.contains("googleusercontent.com"), let eq = url.lastIndex(of: "=") else { return false }
        let size = url[url.index(after: eq)...].split(separator: "-", maxSplits: 2)
        guard size.count >= 2, size[0].first == "w", size[1].first == "h",
              let width = Int(size[0].dropFirst()), let height = Int(size[1].dropFirst())
        else { return false }
        return width != height
    }

    /// `data` decoded with its shorter side at most `edge` pixels, the
    /// orientation applied, and decoded now rather than on first draw.
    static func decode(_ data: Data, edge: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // ImageIO bounds the longer side, while the view crops to fill, so
        // the shorter side is what has to reach the edge drawn. Never scaled up.
        let shorter = max(min(width, height), 1)
        let longer = max(width, height)
        let longest = shorter > edge ? (longer * edge + shorter - 1) / shorter : longer
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(longest, 1),
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

/// Decoded images by key, bounded by their bytes, and emptied under memory
/// pressure.
private final class MemoryCache: @unchecked Sendable {
    // `@unchecked`: NSCache is thread-safe, and this holds nothing else.
    private let cache = NSCache<NSString, CGImage>()

    init(limit: Int) {
        cache.totalCostLimit = limit
    }

    subscript(key: String) -> CGImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: CGImage, for key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }
}

/// Downloads under way, each shared by everyone waiting for its image.
actor Downloads {
    private struct Download {
        /// Its starter's ID, so a cancelled download that ends late never
        /// answers a newer one's waiters.
        let id: UInt64
        let task: Task<Void, Never>
        /// Told the result when it comes, or nil if they stop waiting.
        var waiters: [UInt64: CheckedContinuation<CGImage?, Never>]
    }

    private var downloads: [String: Download] = [:]
    /// Prefetches under way: a request for the same image meanwhile waits
    /// for its download, then reads it from the URL cache, rather than
    /// fetching it a second time.
    private var prefetches: [String: Task<Void, Never>] = [:]
    private var nextID: UInt64 = 0

    /// Waits for `key`'s image, starting `load` unless it is already on its
    /// way. A cancelled caller gets nil at once; the download stops when the
    /// last of its waiters goes.
    func image(for key: String, load: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        let id = nextID
        nextID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Still on this actor: `leave` can only run once this has
                // registered the waiter.
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if downloads[key] != nil {
                    downloads[key]?.waiters[id] = continuation
                } else {
                    let prefetch = prefetches[key]
                    let task = Task { [weak self] in
                        await prefetch?.value
                        let image = await load()
                        await self?.finish(key, id: id, with: image)
                    }
                    downloads[key] = Download(id: id, task: task, waiters: [id: continuation])
                }
            }
        } onCancel: {
            Task { await self.leave(key, id: id) }
        }
    }

    /// Runs `download`, a prefetch of `key`'s image, unless the image is on
    /// its way already, so it is never fetched twice. It stops with its caller.
    func prefetch(_ key: String, download: @escaping @Sendable () async -> Void) async {
        guard downloads[key] == nil, prefetches[key] == nil else { return }
        let task = Task { await download() }
        prefetches[key] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        prefetches[key] = nil
    }

    private func finish(_ key: String, id: UInt64, with image: CGImage?) {
        guard downloads[key]?.id == id, let download = downloads.removeValue(forKey: key) else { return }
        for waiter in download.waiters.values { waiter.resume(returning: image) }
    }

    private func leave(_ key: String, id: UInt64) {
        guard let waiter = downloads[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: nil)
        if downloads[key]?.waiters.isEmpty == true {
            downloads.removeValue(forKey: key)?.task.cancel()
        }
    }
}
