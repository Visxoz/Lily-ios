import CoreGraphics
import Foundation
import MediaPlayer
import YTMCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor final class NowPlayingCenter {
    /// Seconds the system's reckoning of the position may drift, as through a stall, before it is told again.
    private static let allowedDrift = 1.0

    private let info = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    /// Given the song's tall clip, which Now Playing lays itself out for.
    private weak var player: PlayerController?
    private var metadata: [String: Any] = [:]
    /// The song shown, so artwork arriving for an earlier one is dropped.
    private var trackID: String?
    private var artwork: Task<Void, Never>?
    private var motion: Task<Void, Never>?
    /// The song and setting whose moving art `metadata` holds or is finding.
    private var motionFor: String?
    /// Whether `motionFor`'s clips were fetched, not only looked for on the phone, as for a restored song.
    private var motionFetched = false
    /// Counts runs of `showMotion`, so a lapse left from an earlier one does nothing.
    private var motionRun: UInt64 = 0
    /// Each lock-screen key's clip by name, shown and wanted for the song, so a clip both share plays on.
    private var motionNames: [String: String] = [:]
    private var motionWanted: [String: String] = [:]
    private var published: (elapsed: Double, rate: Double, at: ContinuousClock.Instant)?
    /// The system runs the position on at this rate; times stay in the song's own.
    var speed = 1.0

    init(player: PlayerController) {
        self.player = player
        commands.playCommand.addTarget(on: player) { $0.setPaused(false) }
        commands.pauseCommand.addTarget(on: player) { $0.setPaused(true) }
        commands.togglePlayPauseCommand.addTarget(on: player) { $0.togglePlayPause() }
        commands.nextTrackCommand.addTarget(on: player) { $0.next() }
        commands.previousTrackCommand.addTarget(on: player) { $0.previous() }
        commands.changePlaybackPositionCommand.addTarget(on: player, reading: { ($0 as? MPChangePlaybackPositionCommandEvent)?.positionTime }) {
            $0.seek(to: $1)
        }
        commands.likeCommand.localizedTitle = "Like"
        commands.likeCommand.addTarget(on: player) { $0.rate(.like) }
        setLike(isLiked: false, enabled: false)
    }

    func show(_ track: Track, duration: Double, animatedArt: AnimatedArt, fetching: Bool = true) {
        artwork?.cancel()
        trackID = track.id
        published = nil
        metadata = metadata.filter { key, _ in Self.motionKeys.contains { $0.key == key } }
        metadata[MPMediaItemPropertyTitle] = track.title
        metadata[MPMediaItemPropertyArtist] = track.artistNames
        metadata[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        metadata[MPMediaItemPropertyAlbumTitle] = track.album?.name
        setDuration(duration)
        showMotion(of: track, animatedArt, fetching: fetching)
        guard let url = track.thumbnail else { return }
        if let image = ImagePipeline.shared.cachedImage(for: url, pixelEdge: ImagePipeline.playerEdge) {
            metadata[MPMediaItemPropertyArtwork] = Self.artwork(image)
            return
        }
        // The row's small copy, scaled up by the system, so the lock screen has artwork while the large one loads.
        if let small = ImagePipeline.shared.cachedImage(for: url, pixelEdge: ImagePipeline.smallEdge) {
            metadata[MPMediaItemPropertyArtwork] = Self.artwork(small)
        }
        let id = track.id
        artwork = Task { [weak self] in
            guard let image = await ImagePipeline.shared.image(for: url, pixelEdge: ImagePipeline.playerEdge),
                  let self, trackID == id else { return }
            metadata[MPMediaItemPropertyArtwork] = Self.artwork(image)
            republish()
        }
    }

    /// A new dictionary restarts the system's reckoning from its elapsed time, which must be brought up to now.
    private func republish() {
        if let published {
            let elapsed = reckoned(published)
            metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(elapsed, 0)
            self.published = (elapsed, published.rate, .now)
        }
        info.nowPlayingInfo = metadata
    }

    func setDuration(_ duration: Double) {
        metadata[MPMediaItemPropertyPlaybackDuration] = duration > 0 ? duration : nil
    }

    /// `playing` sets the play button; `advancing` (not loading or stalled) lets the system run the position on.
    func setPlayback(playing: Bool, advancing: Bool, elapsed: Double) {
        guard trackID != nil else { return }
        let rate = advancing ? speed : 0
        metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(elapsed, 0)
        metadata[MPNowPlayingInfoPropertyPlaybackRate] = rate
        published = (elapsed, rate, .now)
        info.nowPlayingInfo = metadata
        info.playbackState = playing ? .playing : .paused
    }

    /// Run each tick: tells the system the position again only when its reckoning has drifted.
    func keep(elapsed: Double, advancing: Bool) {
        guard let published else { return }
        if abs(reckoned(published) - elapsed) > Self.allowedDrift || (published.rate > 0) != advancing {
            setPlayback(playing: true, advancing: advancing, elapsed: elapsed)
        }
    }

    private func reckoned(_ published: (elapsed: Double, rate: Double, at: ContinuousClock.Instant)) -> Double {
        published.elapsed + (ContinuousClock.now - published.at).seconds * published.rate
    }

    func setLike(isLiked: Bool, enabled: Bool) {
        commands.likeCommand.isEnabled = enabled
        commands.likeCommand.isActive = isLiked
    }

    // Nonisolated: MediaPlayer asks for the image on its own queue, and a closure made on the main actor would trap
    // there.
    nonisolated private static func artwork(_ image: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: image.width, height: image.height)
        #if canImport(UIKit)
        return MPMediaItemArtwork(boundsSize: size) { _ in UIImage(cgImage: image) }
        #else
        return MPMediaItemArtwork(boundsSize: size) { _ in NSImage(cgImage: image, size: size) }
        #endif
    }

    /// Offered only once on the phone, so the lock screen plays them at once; a clip the last song shares plays on, the
    /// rest go as this one starts, with their downloads. Without `fetching`, only clips on the phone, kept while playing
    /// runs again for the rest; `again` runs even for the same song, as its sources changed.
    func showMotion(of track: Track, _ setting: AnimatedArt, fetching: Bool = true, again: Bool = false) {
        let wanted = setting == .off ? nil : "\(track.id) \(setting)"
        // Nothing wanted always runs, so a cover left up is cleared.
        let same = !again && wanted != nil && wanted == motionFor
        guard !same || (fetching && !motionFetched) else { return }
        motion?.cancel()
        motionFor = wanted
        motionFetched = fetching
        motionRun += 1
        motionWanted = [:]
        #if canImport(UIKit)
        guard wanted != nil else { return keepMotion() }
        let run = motionRun
        let cellular = setting == .on
        let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        // The tall one also where the lock screen can't show it, as Now Playing does.
        let shapes = Self.motionKeys.filter { $0.shape == .tall || supported.contains($0.key) }
        // Old clips stay a second at most while this song's are found, so none lingers under the wrong song.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, motionRun == run else { return }
            keepMotion()
        }
        motion = Task { [weak self] in
            var shown = false
            // What's on the phone first, shown at once, so the last song's clip goes as this one starts, not once
            // Spotify answers; one this song shares plays on.
            for pass in fetching ? [false, true] : [false] {
                var sources = await Self.motionSources(shapes, of: track, fetching: pass, cellular: cellular)
                var unsure = false
                if !pass, fetching, sources[Self.tallKey]?.canvas == false { unsure = await MotionArtwork.shared.isSignedInToSpotify }
                guard let self, !Task.isCancelled else { return }
                // A Canvas may yet be found, so an Apple cover isn't put up only to be swapped; one already up plays on.
                if unsure, player?.motionClip?.id != sources[Self.tallKey]?.name { sources[Self.tallKey] = nil }
                motionWanted = sources.mapValues(\.name)
                // Now Playing's goes once replaced, or at the lapse, so one clip goes straight to the next.
                keepMotion(clip: sources[Self.tallKey] == nil)
                shown = await show(sources, shapes, supported: supported, fetching: pass, followed: fetching && !pass, cellular: cellular)
                guard !Task.isCancelled else { return }
            }
            // None to be had now, as off Wi-Fi, so asking again runs; misses are remembered for the launch.
            guard let self, !shown, motionFor == wanted else { return }
            motionFor = nil
        }
        #endif
    }

    #if canImport(UIKit)
    /// Puts the sources' clips on the lock screen and in Now Playing; true when any is shown. When `followed` by a
    /// fetching pass, a still already up of one not on the phone stays for it.
    private func show(
        _ sources: [String: MotionSource], _ shapes: [(shape: MotionShape, key: String)], supported: [String], fetching: Bool,
        followed: Bool, cellular: Bool
    ) async -> Bool {
        var shown = false
        for (shape, key) in shapes {
            guard let source = sources[key] else { continue }
            let onLockScreen = !supported.contains(key) || motionNames[key] == source.name
            let inNowPlaying = shape != .tall || player?.motionClip.map { $0.id == source.name && $0.file != nil } == true
            if onLockScreen, inNowPlaying {
                shown = true
                continue
            }
            let kept = await MotionArtwork.shared.kept(source)
            guard !Task.isCancelled else { return shown }
            guard kept != nil || fetching else {
                if shape == .tall, !followed || player?.motionClip?.id != source.name { player?.motionClip = nil }
                continue
            }
            // A clip on the phone never waits on the network, as its still is made from it where there is none.
            let first = await MotionArtwork.shared.still(source, fetching: fetching && kept == nil, cellular: cellular)
            guard !Task.isCancelled else { return shown }
            // Laid out for from the first frame, before an Apple clip lands.
            if shape == .tall { player?.motionClip = first.map { MotionClip(id: source.name, file: kept, frame: $0) } }
            let file = if let kept { kept } else if fetching {
                await MotionArtwork.shared.video(source, cellular: cellular)
            } else { nil as URL? }
            let frame = if let first { first } else if file != nil {
                await MotionArtwork.shared.still(source, fetching: false, cellular: false)
            } else { nil as CGImage? }
            guard !Task.isCancelled else { return shown }
            // A still whose clip couldn't be had goes, rather than stand in for it all song.
            if shape == .tall { player?.motionClip = file.flatMap { file in frame.map { MotionClip(id: source.name, file: file, frame: $0) } } }
            guard let file, let frame else { continue }
            shown = true
            guard !onLockScreen else { continue }
            metadata[key] = Self.animatedArtwork(source.name, file: file, frame: frame)
            motionNames[key] = source.name
            republish()
        }
        return shown
    }

    /// The phone's full-screen 3:4 first.
    private static let motionKeys: [(shape: MotionShape, key: String)] = [
        (.tall, tallKey), (.square, MPNowPlayingInfoProperty1x1AnimatedArtwork),
    ]
    private static let tallKey = MPNowPlayingInfoProperty3x4AnimatedArtwork

    private static func motionSources(
        _ shapes: [(shape: MotionShape, key: String)], of track: Track, fetching: Bool, cellular: Bool
    ) async -> [String: MotionSource] {
        var sources: [String: MotionSource] = [:]
        for (shape, key) in shapes {
            sources[key] = await MotionArtwork.shared.source(shape, for: track, fetching: fetching, cellular: cellular)
        }
        return sources
    }

    /// Drops the lock screen's clips that aren't this song's, and with `clip`, Now Playing's.
    private func keepMotion(clip: Bool = true) {
        let dropped = motionNames.filter { motionWanted[$0.key] != $0.value }.keys
        for key in dropped {
            metadata[key] = nil
            motionNames[key] = nil
        }
        if !dropped.isEmpty, published != nil { republish() }
        if clip, let shown = player?.motionClip, shown.id != motionWanted[Self.tallKey] { player?.motionClip = nil }
    }

    // Nonisolated for the same reason as `artwork(_:)`.
    nonisolated private static func animatedArtwork(_ id: String, file: URL, frame: CGImage) -> MPMediaItemAnimatedArtwork {
        MPMediaItemAnimatedArtwork(artworkID: id) { _ in UIImage(cgImage: frame) } videoAssetFileURLRequestHandler: { _ in file }
    }
    #else
    private static let motionKeys: [(shape: MotionShape, key: String)] = []
    #endif
}

private extension MPRemoteCommand {
    /// The system calls handlers from its own thread, so they hop to the main actor rather than assume it, with the
    /// event's values, not the event.
    func addTarget<Value: Sendable>(
        on player: PlayerController, reading read: @escaping @Sendable (MPRemoteCommandEvent) -> Value?,
        _ action: @escaping @MainActor @Sendable (PlayerController, Value) -> Void
    ) {
        addTarget { [weak player] event in
            guard let value = read(event) else { return .commandFailed }
            Task { @MainActor in
                guard let player else { return }
                action(player, value)
            }
            return .success
        }
    }

    func addTarget(on player: PlayerController, _ action: @escaping @MainActor @Sendable (PlayerController) -> Void) {
        addTarget(on: player, reading: { _ in () }) { player, _ in action(player) }
    }
}
