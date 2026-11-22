import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// Apple's 1:1 and 3:4 clips.
public enum MotionShape: String, Sendable, CaseIterable {
    case square, tall
}

/// A moving cover's master playlist, and Apple's still of its first frame.
struct MotionCover: Sendable {
    let video: URL
    let still: URL?
}

/// Apple Music's moving album covers, found for YouTube's albums by name and kept on disk as clips and stills.
public actor MotionArtwork {
    public static let shared = MotionArtwork(
        directory: URL.cachesDirectory.appending(path: "motion", directoryHint: .isDirectory),
        storefront: Locale.current.region?.identifier.lowercased() ?? "us"
    )

    /// Albums whose answer is kept for the launch, at a few hundred bytes each.
    private static let lookupLimit = 500
    /// Clips kept on disk: about 25, at 8 MB each, with stills of about 150 KB.
    private static let diskLimit = 200 << 20
    /// A still's shorter side, as Apple is asked for it.
    private static let stillEdge = 720

    private let directory: URL
    private let catalogue: AppleMusicCatalogue
    /// By album ID, under way or answered; one that couldn't ask is dropped, so the next call asks again.
    private var lookups: [String: Task<[MotionShape: MotionCover]?, Never>] = [:]
    private var downloads: [URL: Download] = [:]
    private var nextID: UInt64 = 0

    private struct Download {
        /// So the old download ending can't clear one started afresh after its waiters left.
        let id: UInt64
        let task: Task<URL?, Never>
        var waiters: Int
    }

    init(directory: URL, storefront: String) {
        self.directory = directory
        catalogue = AppleMusicCatalogue(storefront: storefront, tokenFile: directory.appending(path: "token"))
    }

    /// The clip as a local fMP4 file, nil when there is none or it can't be had now; Apple is asked once per album a
    /// launch, and concurrent calls share one download.
    public func video(_ shape: MotionShape, for track: Track, cellular: Bool) async -> URL? {
        guard let file = file(shape, for: track) else { return nil }
        if Self.touch(file) { return file }
        // A caller skipped during the shared search starts no download only to stop it.
        guard let master = await covers(of: track, cellular: cellular)?[shape]?.video, !Task.isCancelled else { return nil }
        // Another call may have finished it during the search.
        if Self.touch(file) { return file }
        return await share(file, from: master, cellular: cellular)
    }

    /// The clip if it is already on the phone, without asking Apple.
    public func kept(_ shape: MotionShape, for track: Track) -> URL? {
        guard let file = file(shape, for: track), Self.touch(file) else { return nil }
        return file
    }

    /// The clip's first frame, so it can be laid out for before it lands: the JPEG kept beside it, else one made once
    /// from the clip on the phone, else Apple's still; without `fetching`, Apple isn't asked.
    public func still(_ shape: MotionShape, for track: Track, fetching: Bool, cellular: Bool) async -> CGImage? {
        guard let clip = file(shape, for: track) else { return nil }
        let file = clip.deletingPathExtension().appendingPathExtension("jpg")
        // One that won't decode, as cut short, is made again.
        if Self.touch(file), let still = await Self.decode(file) { return still }
        if Self.touch(clip) { return await Self.still(of: clip, savingTo: file) }
        guard fetching, let still = await covers(of: track, cellular: cellular)?[shape]?.still, !Task.isCancelled else {
            return nil
        }
        return await Self.fetch(still, to: file, in: directory, cellular: cellular)
    }

    private func file(_ shape: MotionShape, for track: Track) -> URL? {
        track.album.flatMap { Self.clipName($0.id, shape) }.map { directory.appending(path: $0) }
    }

    /// By album, as covers are an album's; only the ID's safe characters, as YouTube supplied it.
    static func clipName(_ album: String, _ shape: MotionShape) -> String? {
        let name = album.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return name.isEmpty ? nil : "\(name)-\(shape.rawValue).mp4"
    }

    private func covers(of track: Track, cellular: Bool) async -> [MotionShape: MotionCover]? {
        guard let album = track.album, let artist = track.artists.first?.name else { return [:] }
        if let lookup = lookups[album.id] { return await lookup.value }
        // An arbitrary one goes, as asking again costs only a search.
        if lookups.count >= Self.lookupLimit { lookups.remove(at: lookups.startIndex) }
        let task = Task { [catalogue] in await catalogue.covers(album: album.name, artist: artist, cellular: cellular) }
        lookups[album.id] = task
        let covers = await task.value
        if covers == nil, lookups[album.id] == task { lookups[album.id] = nil }
        return covers
    }

    // MARK: - Downloads

    /// Joins the clip's download, or starts it; it stops once every caller waiting for it is cancelled.
    private func share(_ file: URL, from master: URL, cellular: Bool) async -> URL? {
        let download = downloads[file] ?? start(file, from: master, cellular: cellular)
        downloads[file]?.waiters += 1
        return await withTaskCancellationHandler {
            await download.task.value
        } onCancel: {
            Task { await self.leave(file, id: download.id) }
        }
    }

    private func start(_ file: URL, from master: URL, cellular: Bool) -> Download {
        let id = nextID
        nextID += 1
        let task = Task { [weak self, directory] in
            let saved = await Self.download(master, to: file, in: directory, cellular: cellular)
            await self?.finish(file, id: id)
            return saved
        }
        let download = Download(id: id, task: task, waiters: 0)
        downloads[file] = download
        return download
    }

    private func finish(_ file: URL, id: UInt64) {
        if downloads[file]?.id == id { downloads[file] = nil }
    }

    private func leave(_ file: URL, id: UInt64) {
        guard downloads[file]?.id == id else { return }
        downloads[file]?.waiters -= 1
        if downloads[file]?.waiters == 0 { downloads.removeValue(forKey: file)?.task.cancel() }
    }

    /// Master, variant, then the one file its segments are ranges of, to a temporary file moved into place, so a clip
    /// is whole or absent.
    @concurrent
    private static func download(_ master: URL, to file: URL, in directory: URL, cellular: Bool) async -> URL? {
        do {
            let masterText = String(decoding: try await AppleMusicCatalogue.fetch(master, cellular: cellular), as: UTF8.self)
            guard let variant = HLSPlaylist.variant(inMaster: masterText, at: master) else {
                throw YTMError(.parse, "The cover's playlist has no video.")
            }
            let variantText = String(decoding: try await AppleMusicCatalogue.fetch(variant, cellular: cellular), as: UTF8.self)
            guard let media = HLSPlaylist.mediaFile(inVariant: variantText, at: variant) else {
                throw YTMError(.parse, "The cover's video isn't one file.")
            }
            let downloaded = try await HTTP.download(AppleMusicCatalogue.request(media, cellular: cellular))
            // Gone once moved; left behind only by a failure.
            defer { try? FileManager.default.removeItem(at: downloaded) }
            // Recreated each time, as the system may empty Caches.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(at: downloaded, to: file)
            } catch where FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                // An earlier download of it landed first, as whole as this one.
            }
            trim(directory, keeping: file)
            return file
        } catch is CancellationError {
            return nil
        } catch {
            Logger.motion.error("A moving cover couldn't be downloaded: \(sentence(for: error), privacy: .public)")
            return nil
        }
    }

    @concurrent
    private static func decode(_ file: URL) async -> CGImage? {
        (try? Data(contentsOf: file)).flatMap { ImagePipeline.decode($0, edge: stillEdge) }
    }

    /// For a clip with no still beside it, as where Apple has none or the clip landed first.
    @concurrent
    private static func still(of clip: URL, savingTo file: URL) async -> CGImage? {
        let frames = AVAssetImageGenerator(asset: AVURLAsset(url: clip))
        frames.maximumSize = CGSize(width: stillEdge, height: stillEdge * 4 / 3)
        frames.appliesPreferredTrackTransform = true
        guard let still = try? await frames.image(at: .zero).image else { return nil }
        let data = NSMutableData()
        if let jpeg = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(jpeg, still, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(jpeg) { try? (data as Data).write(to: file, options: .atomic) }
        }
        return still
    }

    /// Kept only if it decodes, so a bad answer isn't kept for good.
    @concurrent
    private static func fetch(_ still: URL, to file: URL, in directory: URL, cellular: Bool) async -> CGImage? {
        do {
            let data = try await AppleMusicCatalogue.fetch(still, cellular: cellular)
            guard let image = ImagePipeline.decode(data, edge: stillEdge) else { throw YTMError(.parse, "The cover's still isn't an image.") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            trim(directory, keeping: file)
            return image
        } catch is CancellationError {
            return nil
        } catch {
            Logger.motion.error("A moving cover's still couldn't be had: \(sentence(for: error), privacy: .public)")
            return nil
        }
    }

    /// Marks a kept clip or still as just used, for the trim's order; false when there is none.
    private static func touch(_ file: URL) -> Bool {
        let path = file.path(percentEncoded: false)
        return (try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: path)) != nil
    }

    /// Deletes the clips and stills used longest ago until the rest fit the limit, never the cover just kept.
    static func trim(_ directory: URL, keeping kept: URL, limit: Int = diskLimit) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let entries = files.filter { ["mp4", "jpg"].contains($0.pathExtension) }.compactMap { file -> (file: URL, used: Date, size: Int)? in
            guard let values = try? file.resourceValues(forKeys: keys), let used = values.contentModificationDate,
                  let size = values.fileSize
            else { return nil }
            return (file, used, size)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        // A cover's clip and still go together, so neither is left without the other.
        let kept = kept.deletingPathExtension().lastPathComponent
        let covers = Dictionary(grouping: entries) { $0.file.deletingPathExtension().lastPathComponent }
            .filter { $0.key != kept }.values
            .sorted { ($0.map(\.used).max() ?? .distantPast) < ($1.map(\.used).max() ?? .distantPast) }
        for cover in covers where total > limit {
            for entry in cover where (try? FileManager.default.removeItem(at: entry.file)) != nil { total -= entry.size }
        }
    }
}

extension Logger {
    /// What finding and downloading moving covers did, for Console; never a URL or Apple's token.
    static let motion = Logger(subsystem: "Lily", category: "motion")
}
