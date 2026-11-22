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
    /// Seconds the system's reckoning of the position may drift, as through a
    /// stall, before it is told again.
    private static let allowedDrift = 1.0

    private let info = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    /// Given the album's tall clip, which Now Playing lays itself out for.
    private weak var player: PlayerController?
    private var metadata: [String: Any] = [:]
    /// The song shown, so artwork arriving for an earlier one is dropped.
    private var trackID: String?
    private var artwork: Task<Void, Never>?
    private var motion: Task<Void, Never>?
    /// The album and setting whose moving covers `metadata` holds or is finding, so the album's next song keeps them.
    private var motionFor: String?
    /// Whether `motionFor`'s clips were fetched, not only looked for on the phone, as for a restored song.
    private var motionFetched = false
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
        // The row's small copy, scaled up by the system, so the lock screen
        // has artwork while the large one loads.
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

    /// A new dictionary restarts the system's reckoning from its elapsed
    /// time, which must be brought up to now.
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

    /// `playing` sets the play button; `advancing` (not loading or stalled) lets
    /// the system run the position on by itself.
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

    // Nonisolated: MediaPlayer asks for the image on its own queue, and a
    // closure made on the main actor would trap there.
    nonisolated private static func artwork(_ image: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: image.width, height: image.height)
        #if canImport(UIKit)
        return MPMediaItemArtwork(boundsSize: size) { _ in UIImage(cgImage: image) }
        #else
        return MPMediaItemArtwork(boundsSize: size) { _ in NSImage(cgImage: image, size: size) }
        #endif
    }

    /// Offered only once the clips are on the phone, so the lock screen plays them at once; another album or setting
    /// drops the last one's and stops its download, so Wi-Fi only also ends one running on cellular. Without
    /// `fetching`, only clips already on the phone, so playing runs again for what they lacked, keeping those shown.
    func showMotion(of track: Track, _ setting: AnimatedArt, fetching: Bool = true) {
        let album = setting == .off ? nil : track.album?.id
        let wanted = album.map { "\($0) \(setting)" }
        // Nothing wanted always runs, so a cover left up is cleared.
        let same = wanted != nil && wanted == motionFor
        guard !same || (fetching && !motionFetched) else { return }
        motion?.cancel()
        motionFor = wanted
        motionFetched = fetching
        if !same {
            let dropped = Self.motionKeys.filter { metadata.removeValue(forKey: $0.key) != nil }
            if !dropped.isEmpty, published != nil { republish() }
        }
        #if canImport(UIKit)
        guard let album else {
            player?.motionClip = nil
            return
        }
        let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        // The tall one also where the lock screen can't show it, as Now Playing does; one already shown, as when
        // playing a restored song, is left playing.
        let shapes = Self.motionKeys.filter { $0.shape == .tall || supported.contains($0.key) }
        let wanting = shapes.filter { metadata[$0.key] == nil }
        motion = Task { [weak self] in
            var shown = wanting.count < shapes.count
            for (shape, key) in wanting {
                let kept = await MotionArtwork.shared.kept(shape, for: track)
                // The last album's clip stays while this one's first frame is had, so one goes straight to the other,
                // but for a second at most, so a slow network can't leave it under the wrong song.
                let lapse = shape != .tall ? nil : Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled, self?.player?.motionClip?.album != album { self?.player?.motionClip = nil }
                }
                // A clip on the phone never waits on Apple, as its still is made from it where there is none.
                let first = await withTaskCancellationHandler {
                    await MotionArtwork.shared.still(shape, for: track, fetching: fetching && kept == nil, cellular: setting == .on)
                } onCancel: {
                    lapse?.cancel()
                }
                lapse?.cancel()
                guard !Task.isCancelled else { return }
                // Laid out for from the first frame before the clip lands, but only while one is on the phone or coming.
                if shape == .tall {
                    self?.player?.motionClip = kept != nil || fetching ? first.map { MotionClip(album: album, file: kept, frame: $0) } : nil
                }
                let file = if let kept { kept } else if fetching {
                    await MotionArtwork.shared.video(shape, for: track, cellular: setting == .on)
                } else { nil as URL? }
                let frame = if let first { first } else if file != nil {
                    await MotionArtwork.shared.still(shape, for: track, fetching: false, cellular: false)
                } else { nil as CGImage? }
                guard let self, !Task.isCancelled else { return }
                // A still whose clip couldn't be had goes, rather than stand in for it all song.
                if shape == .tall { player?.motionClip = file.flatMap { file in frame.map { MotionClip(album: album, file: file, frame: $0) } } }
                guard let file, let frame else { continue }
                shown = true
                guard supported.contains(key) else { continue }
                metadata[key] = Self.animatedArtwork("\(album).\(shape.rawValue)", file: file, frame: frame)
                republish()
            }
            // None to be had now, as off Wi-Fi, so the album's next song asks again; Apple's misses are remembered.
            guard !shown, let self, !Task.isCancelled, motionFor == wanted else { return }
            motionFor = nil
        }
        #endif
    }

    #if canImport(UIKit)
    /// The phone's full-screen 3:4 first.
    private static let motionKeys: [(shape: MotionShape, key: String)] = [
        (.tall, MPNowPlayingInfoProperty3x4AnimatedArtwork), (.square, MPNowPlayingInfoProperty1x1AnimatedArtwork),
    ]

    // Nonisolated for the same reason as `artwork(_:)`.
    nonisolated private static func animatedArtwork(_ id: String, file: URL, frame: CGImage) -> MPMediaItemAnimatedArtwork {
        MPMediaItemAnimatedArtwork(artworkID: id) { _ in UIImage(cgImage: frame) } videoAssetFileURLRequestHandler: { _ in file }
    }
    #else
    private static let motionKeys: [(shape: MotionShape, key: String)] = []
    #endif
}

private extension MPRemoteCommand {
    /// The system calls handlers from its own thread, so they hop to the main
    /// actor rather than assume it, with the event's values, not the event.
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
