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

/// A moving cover's master playlist, or a Canvas's one file, and a still of its first frame.
struct MotionCover: Sendable {
    let video: URL
    let still: URL?
}

/// Where a song's clip in one shape comes from, named as its file, so songs sharing their album's cover play it on.
public struct MotionSource: Sendable {
    public let name: String
    let shape: MotionShape
    let track: Track
    public let canvas: Bool
}

/// Moving art kept on disk as clips and stills: a song's Spotify Canvas once signed in, and its album's Apple cover.
public actor MotionArtwork {
    public static let shared = MotionArtwork(
        directory: URL.cachesDirectory.appending(path: "motion", directoryHint: .isDirectory),
        storefront: Locale.current.region?.identifier.lowercased() ?? "us"
    )

    /// Songs and albums whose answer is kept for the launch, at a few hundred bytes each.
    private static let lookupLimit = 500
    /// Clips kept on disk: about 25 Apple covers at 8 MB each, or 50 Canvases at 4 MB, with stills of about 150 KB.
    private static let diskLimit = 200 << 20
    /// A still's shorter side, as Apple is asked for it.
    private static let stillEdge = 720
    /// Prefixes a Canvas's lookup, so they can be forgotten together.
    private static let spotify = "spotify "

    private let directory: URL
    private let catalogue: AppleMusicCatalogue
    private let canvas: SpotifyCanvas
    /// By song or album, under way or answered; one that couldn't ask is dropped, so the next call asks again.
    private var lookups: [String: Task<[MotionShape: MotionCover]?, Never>] = [:]
    private var downloads: [URL: Download] = [:]
    private var nextID: UInt64 = 0

    private struct Download {
        /// So the old download ending can't clear one started afresh after its waiters left.
        let id: UInt64
        let task: Task<URL?, Never>
        let cellular: Bool
        var waiters: Int
        /// Every join, so a linger ends it only if no one joined since.
        var joins = 0
    }

    init(directory: URL, storefront: String) {
        self.directory = directory
        catalogue = AppleMusicCatalogue(storefront: storefront, tokenFile: directory.appending(path: "token"))
        canvas = SpotifyCanvas(configFile: directory.appending(path: "spotify.json"))
    }

    // MARK: - Spotify

    public var isSignedInToSpotify: Bool {
        get async { await canvas.isSignedIn }
    }

    /// Keeps the session once Spotify takes it as signed in; throws a sentence for the user otherwise.
    public func signInToSpotify(cookie: String) async throws {
        try await canvas.signIn(cookie: cookie)
        forgetCanvases()
    }

    public func signOutOfSpotify() async {
        await canvas.signOut()
        forgetCanvases()
    }

    /// Answers had under another session aren't this one's.
    private func forgetCanvases() {
        lookups = lookups.filter { !$0.key.hasPrefix(Self.spotify) }
    }

    // MARK: - Clips

    /// The tall shape's Canvas where it has one, else the album's Apple cover; unless `fetching`, only a kept Canvas.
    public func source(_ shape: MotionShape, for track: Track, fetching: Bool, cellular: Bool) async -> MotionSource? {
        if shape == .tall, let name = Self.clipName(track.id, "canvas3x4"), await canvas.isSignedIn {
            let source = MotionSource(name: name, shape: shape, track: track, canvas: true)
            if Self.touch(clip(source)) { return source }
            if fetching, await covers(of: source, cellular: cellular)?[shape] != nil { return source }
        }
        return track.album.flatMap { Self.clipName($0.id, shape.rawValue) }
            .map { MotionSource(name: $0, shape: shape, track: track, canvas: false) }
    }

    /// The clip as a local MP4 file, nil when there is none or it can't be had now; each song or album is asked once
    /// a launch, and concurrent calls share one download.
    public func video(_ source: MotionSource, cellular: Bool) async -> URL? {
        let file = clip(source)
        if Self.touch(file) { return file }
        // A caller skipped during the shared search starts no download only to stop it.
        guard let video = await covers(of: source, cellular: cellular)?[source.shape]?.video, !Task.isCancelled else { return nil }
        // Another call may have finished it during the search.
        if Self.touch(file) { return file }
        return await share(file, from: video, cellular: cellular)
    }

    /// The clip if it is already on the phone, never the network.
    public func kept(_ source: MotionSource) -> URL? {
        let file = clip(source)
        return Self.touch(file) ? file : nil
    }

    /// The first frame, laid out before the clip lands: the kept JPEG, else one made from the clip, else (`fetching`)
    /// the source's.
    public func still(_ source: MotionSource, fetching: Bool, cellular: Bool) async -> CGImage? {
        let clip = clip(source)
        let file = clip.deletingPathExtension().appendingPathExtension("jpg")
        // One that won't decode, as cut short, is made again.
        if Self.touch(file), let still = await Self.decode(file) { return still }
        if Self.touch(clip) { return await Self.still(of: clip, savingTo: file) }
        guard fetching, let still = await covers(of: source, cellular: cellular)?[source.shape]?.still, !Task.isCancelled else {
            return nil
        }
        return await Self.fetch(still, to: file, in: directory, cellular: cellular)
    }

    private func clip(_ source: MotionSource) -> URL {
        directory.appending(path: source.name + ".mp4")
    }

    /// A Canvas's by song, Apple's by album; only the ID's safe characters, as YouTube supplied it.
    static func clipName(_ id: String, _ kind: String) -> String? {
        let name = id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return name.isEmpty ? nil : "\(name)-\(kind)"
    }

    private func covers(of source: MotionSource, cellular: Bool) async -> [MotionShape: MotionCover]? {
        let track = source.track
        let key: String
        let ask: @Sendable () async -> [MotionShape: MotionCover]?
        if source.canvas {
            key = Self.spotify + track.id
            ask = { [canvas] in
                await canvas.covers(
                    title: track.title, artists: track.artists.map(\.name), album: track.album?.name, duration: track.duration,
                    cellular: cellular
                )
            }
        } else {
            guard let album = track.album, let artist = track.artists.first?.name else { return [:] }
            key = album.id
            ask = { [catalogue] in await catalogue.covers(album: album.name, artist: artist, cellular: cellular) }
        }
        if let lookup = lookups[key] { return await lookup.value }
        // An arbitrary one goes, as asking again costs only a search.
        if lookups.count >= Self.lookupLimit { lookups.remove(at: lookups.startIndex) }
        let task = Task { await ask() }
        lookups[key] = task
        let covers = await task.value
        if covers == nil, lookups[key] == task { lookups[key] = nil }
        return covers
    }

    // MARK: - Downloads

    /// Joins the clip's download, or starts it; it stops a few seconds after every caller waiting for it is cancelled.
    private func share(_ file: URL, from video: URL, cellular: Bool) async -> URL? {
        // One allowed on cellular isn't joined once only Wi-Fi is.
        if !cellular, downloads[file]?.cellular == true { downloads.removeValue(forKey: file)?.task.cancel() }
        let download = downloads[file] ?? start(file, from: video, cellular: cellular)
        downloads[file]?.waiters += 1
        downloads[file]?.joins += 1
        return await withTaskCancellationHandler {
            await download.task.value
        } onCancel: {
            Task { await self.leave(file, id: download.id) }
        }
    }

    private func start(_ file: URL, from video: URL, cellular: Bool) -> Download {
        let id = nextID
        nextID += 1
        let task = Task { [weak self, directory] in
            let saved = await Self.download(video, to: file, in: directory, cellular: cellular)
            await self?.finish(file, id: id)
            return saved
        }
        let download = Download(id: id, task: task, cellular: cellular, waiters: 0)
        downloads[file] = download
        return download
    }

    private func finish(_ file: URL, id: UInt64) {
        if downloads[file]?.id == id { downloads[file] = nil }
    }

    private func leave(_ file: URL, id: UInt64) async {
        guard downloads[file]?.id == id else { return }
        downloads[file]?.waiters -= 1
        guard let joins = downloads[file]?.joins, downloads[file]?.waiters == 0 else { return }
        // So the next song sharing the clip, as its album's, joins it rather than starting again.
        try? await Task.sleep(for: .seconds(5))
        if downloads[file]?.id == id, downloads[file]?.joins == joins { downloads.removeValue(forKey: file)?.task.cancel() }
    }

    /// A Canvas's file cut to 3:4, or the one file an Apple cover's segments are ranges of, moved into place so it's
    /// whole or absent.
    @concurrent
    private static func download(_ video: URL, to file: URL, in directory: URL, cellular: Bool) async -> URL? {
        do {
            let playlist = video.pathExtension == "m3u8"
            let media = playlist ? try await mediaFile(of: video, cellular: cellular) : video
            let downloaded = try await HTTP.download(MotionLookup.request(media, cellular: cellular))
            // Gone once moved or cut into another file.
            defer { try? FileManager.default.removeItem(at: downloaded) }
            // Apple's covers come in 3:4 already.
            let clip = try (playlist ? nil : CleanAperture.tall(downloaded)) ?? downloaded
            defer { if clip != downloaded { try? FileManager.default.removeItem(at: clip) } }
            // Recreated each time, as the system may empty Caches.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(at: clip, to: file)
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

    private static func mediaFile(of master: URL, cellular: Bool) async throws -> URL {
        let masterText = String(decoding: try await MotionLookup.fetch(master, cellular: cellular), as: UTF8.self)
        guard let variant = HLSPlaylist.variant(inMaster: masterText, at: master) else {
            throw YTMError(.parse, "The cover's playlist has no video.")
        }
        let variantText = String(decoding: try await MotionLookup.fetch(variant, cellular: cellular), as: UTF8.self)
        guard let media = HLSPlaylist.mediaFile(inVariant: variantText, at: variant) else {
            throw YTMError(.parse, "The cover's video isn't one file.")
        }
        return media
    }

    @concurrent
    private static func decode(_ file: URL) async -> CGImage? {
        (try? Data(contentsOf: file)).flatMap { ImagePipeline.decode($0, edge: stillEdge) }
    }

    /// For a clip with no still beside it, as a Canvas, or where Apple has none or the clip landed first.
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
            let data = try await MotionLookup.fetch(still, cellular: cellular)
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

/// What every catalogue's lookup shares: names as a match compares them, and requests kept to the setting's networks.
enum MotionLookup {
    /// The whole credit and each name it joins, never part of one, as "Low" in "Flowers".
    static func credits(_ name: String) -> [String] {
        [normalised(name)] + name.split { $0 == "," || $0 == "&" }.map { normalised(String($0)) }
    }

    /// Lowercase, without accents, without Apple's " - Single" or " - EP", and only letters and digits.
    static func normalised(_ name: String) -> String {
        var name = name[...]
        for suffix in [" - Single", " - EP"] where name.hasSuffix(suffix) {
            name = name.dropLast(suffix.count)
        }
        let folded = name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        return String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// Requests never use Low Data Mode, and metered networks only when allowed.
    static func request(_ url: URL, cellular: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.allowsExpensiveNetworkAccess = cellular
        request.allowsConstrainedNetworkAccess = false
        return request
    }

    /// On `HTTP.clips`, so a script of several MB ends only on silence, and playlists share their clip's connection.
    static func fetch(_ url: URL, cellular: Bool) async throws -> Data {
        try await HTTP.data(for: request(url, cellular: cellular), session: HTTP.clips).0
    }
}

extension Logger {
    /// What finding and downloading moving covers did, for Console; never a URL, token or cookie.
    static let motion = Logger(subsystem: "Lily", category: "motion")
}
