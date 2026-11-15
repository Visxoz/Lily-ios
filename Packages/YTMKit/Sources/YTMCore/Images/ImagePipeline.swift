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

    /// Decoded artwork kept for reuse, in bytes, as ytm-native's budget.
    private static let memoryLimit = 32 << 20
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
private actor Downloads {
    private struct Download {
        /// Its starter's ID, so a cancelled download that ends late never
        /// answers a newer one's waiters.
        let id: UInt64
        let task: Task<Void, Never>
        /// Told the result when it comes, or nil if they stop waiting.
        var waiters: [UInt64: CheckedContinuation<CGImage?, Never>]
    }

    private var downloads: [String: Download] = [:]
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
                    let task = Task { [weak self] in
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
