import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os

/// Artwork decoded off the main actor at the size shown, from memory, then the
/// downloads' artwork, then `HTTP.media`'s disk URL cache, then the network.
public final class ImagePipeline: Sendable {
    public static let shared = ImagePipeline()

    /// Now Playing's artwork in pixels (the phone's width less its margins,
    /// at 3x), shared with the lock screen so both use one decode.
    public static let playerEdge = 1080
    /// Any artwork drawn 56 points or smaller (56 at 3x), in pixels, so a
    /// row's copy, the mini player's and the prefetched one share one decode.
    public static let smallEdge = 168

    /// Decoded artwork kept, in bytes: enough for a Home feed's cards and the
    /// player's 1080-pixel copy to outlast a scroll.
    private static let memoryLimit = 96 << 20
    /// Prefetches at once per page, besides any its last run left finishing: few, so the
    /// artwork a view asks for itself never queues behind a page's worth for the media host's connections.
    private static let prefetchWidth = 4
    private static let log = Logger(subsystem: "Lily", category: "ImagePipeline")
    /// Downloaded songs' artwork, at the player's size, which serves every smaller one.
    private static let kept = FileStore.shared.downloads.appending(path: "Artwork", directoryHint: .isDirectory)

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

    /// Downloads artwork into the disk URL cache without decoding it, so memory
    /// stays bounded. Nothing more starts once the caller is cancelled.
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

    /// Opens the artwork hosts' connections while YouTube builds Home, so its first art needn't.
    @concurrent
    public static func preconnect() async {
        await withTaskGroup(of: Void.self) { group in
            for host in ["lh3.googleusercontent.com", "i.ytimg.com"] {
                guard let url = URL(string: "https://\(host)/") else { continue }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.httpMethod = "HEAD"
                group.addTask { _ = try? await HTTP.data(for: request, session: HTTP.media) }
            }
        }
    }

    /// Keeps `url`'s artwork on the phone until `keepOnly` lets it go, so it shows offline.
    @concurrent
    public func keep(_ url: String) async {
        let file = Self.keptFile(url)
        guard !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
              let request = Self.requestURL(url, edge: Self.playerEdge),
              let data = try? await HTTP.data(for: URLRequest(url: request), session: HTTP.media).0
        else { return }
        try? FileManager.default.createDirectory(at: Self.kept, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    @concurrent
    public func keepOnly(_ urls: Set<String>) async {
        let names = Set(urls.map { Self.keptFile($0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.kept, includingPropertiesForKeys: nil)) ?? []
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func keptFile(_ url: String) -> URL {
        let name = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return kept.appending(path: name)
    }

    /// Keyed by what is requested, so artwork stored at different sizes
    /// shares one decode and one download.
    static func key(_ url: String, _ edge: Int) -> String {
        "\(edge):\(isWide(url) ? url : Thumbnail.resized(url, edge: edge))"
    }

    @concurrent
    private static func fetch(_ url: String, edge: Int) async -> CGImage? {
        if let data = try? Data(contentsOf: keptFile(url)), let image = decode(data, edge: edge) {
            return image
        }
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
        guard !FileManager.default.fileExists(atPath: keptFile(url).path(percentEncoded: false)),
              let request = requestURL(url, edge: edge).map({ URLRequest(url: $0) }),
              HTTP.artworkCache.cachedResponse(for: request) == nil
        else { return }
        _ = try? await HTTP.data(for: request, session: HTTP.media)
    }

    /// googleusercontent renders any size, so ask for the pixels drawn; a wide
    /// banner keeps the rendition it came with, as a square size would crop it.
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
    /// A request for an image being prefetched waits for that download, then
    /// reads it from the URL cache rather than fetching it twice.
    private var prefetches: [String: Task<Void, Never>] = [:]
    private var nextID: UInt64 = 0

    /// Waits for `key`'s image, starting `load` unless it is on its way. A
    /// cancelled caller gets nil at once; the download stops with the last.
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
    /// its way already. Once started it outlives its caller, as the page's next
    /// prefetch, or a view waiting on it, wants the same bytes.
    func prefetch(_ key: String, download: @escaping @Sendable () async -> Void) async {
        guard downloads[key] == nil, prefetches[key] == nil else { return }
        let task = Task { await download() }
        prefetches[key] = task
        await task.value
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
