import Foundation

/// Plays `AudioItem`s gaplessly or crossfading, through the equaliser, from
/// a disk cache. The main actor's face of the engine: every call returns at
/// once, and the work happens on the engine's own queue, in the order called.
@MainActor public final class AudioPlayer {
    /// The most silence cut from either side of a crossfade, so a quiet
    /// passage or a hidden track is not mistaken for the end. A crossfade's
    /// next item is queued this much earlier, with the fade's own length.
    nonisolated public static let silenceTrimSeconds = 4.0

    /// What the engine reports, for one consumer. Events of an item replaced
    /// by `play` or `stop` never arrive after the call.
    public let events: AsyncStream<AudioEvent>
    public private(set) var isPlaying = false

    public var equaliser: (enabled: Bool, gains: [Float]) = (false, Array(repeating: 0, count: EqualiserBands.frequencies.count)) {
        didSet {
            let (enabled, gains) = equaliser
            engine.send { $0.setEqualiser(enabled: enabled, gains: gains) }
        }
    }

    /// Silences the app's own output; the level otherwise is the system volume's alone.
    public var isMuted = false {
        didSet {
            let level: Float = isMuted ? 0 : 1
            engine.send { $0.setLevel(level) }
        }
    }

    /// How long a crossfade lasts, for `setNext(_:crossfade:)`.
    public var crossfadeSeconds = 6.0

    /// Whether each item's loudness is corrected, by its `loudnessDB`. A
    /// change reaches the item playing too, once the few seconds of sound
    /// already scheduled have played, gliding to the new level.
    public var normalise = true {
        didSet {
            let normalise = normalise
            engine.send { $0.normalise = normalise }
        }
    }

    private let continuation: AsyncStream<AudioEvent>.Continuation
    private let engine: PlaybackEngine
    private var relay: Task<Void, Never>?
    /// Counts `play` and `stop` calls, so events of what they replaced are dropped.
    private var session: UInt64 = 0
    private var currentID: String?

    public convenience init(cacheLimitBytes: Int64 = 40 << 20) {
        let cache = AudioCache.Location(directory: AudioCache.defaultDirectory, limit: cacheLimitBytes)
        self.init(output: .device, source: HTTPByteSource(), cache: cache)
    }

    init(output: PlaybackEngine.Output, source: any ByteSource, cache: AudioCache.Location) {
        (events, continuation) = AsyncStream.makeStream(of: AudioEvent.self)
        let (stamped, sink) = AsyncStream.makeStream(of: PlaybackEngine.Stamped.self)
        engine = PlaybackEngine(output: output, source: source, cache: cache, events: sink)
        relay = Task { [weak self] in
            for await event in stamped {
                self?.deliver(event)
            }
        }
    }

    deinit {
        relay?.cancel()
        engine.send { $0.shutDown() }
    }

    /// Plays `item` in place of anything playing, skipping without a fade.
    public func play(_ item: AudioItem, from seconds: Double = 0, paused: Bool = false) {
        session += 1
        currentID = item.id
        isPlaying = !paused
        let session = session
        engine.send { $0.play(item, from: seconds, paused: paused, session: session) }
    }

    /// Queues the item to follow the current one without a gap, or fading
    /// into it, replacing any queued before; nil clears it. Its download
    /// starts now. Pass `crossfade` false for tracks of one album in order.
    public func setNext(_ item: AudioItem?, crossfade: Bool) {
        let fade = crossfade ? crossfadeSeconds : 0
        let session = session
        engine.send { $0.setNext(item, fade: fade, session: session) }
    }

    /// Fetches the start of an item likely to play next, so a skip to it
    /// starts sooner; its download, by `play` or `setNext`, carries on from
    /// there. One item is warmed at a time, the last asked for, or a next
    /// item let go, which keeps what it had downloaded.
    public func warm(_ item: AudioItem) {
        engine.send { $0.warm(item) }
    }

    public func pause() {
        isPlaying = false
        engine.send { $0.pause() }
    }

    public func resume() {
        guard currentID != nil else { return }
        isPlaying = true
        engine.send { $0.resume() }
    }

    /// Stops the sound; the output stops after a while, so the device can
    /// sleep, unless `keepingOutput`, for a change of song: a running output
    /// keeps the app awake in the background until the next one plays.
    public func stop(keepingOutput: Bool = false) {
        session += 1
        currentID = nil
        isPlaying = false
        let session = session
        engine.send { $0.stop(session: session, keepingOutput: keepingOutput) }
    }

    /// Stops, and makes the engine's audio graph afresh, as the system's
    /// media services reset takes the old one with it. The mute and
    /// equaliser carry over.
    public func rebuild() {
        stop()
        engine.send { $0.rebuildGraph() }
    }

    public func seek(to seconds: Double) {
        let session = session
        engine.send { $0.seek(to: seconds, session: session) }
    }

    /// Where the sound heard has got to, in seconds; cheap enough to read every frame.
    public var currentTime: Double { engine.clock.position() }

    /// The item heard's length: exact once its file is complete, before that as its container states.
    public var duration: Double? { engine.clock.duration }

    /// How much of the item heard has downloaded, from 0 to 1, for the seek
    /// bar; cheap enough to read every frame.
    public var bufferedFraction: Double { engine.clock.buffered }

    public var cacheSizeBytes: Int64 {
        get async { await engine.cacheSize() }
    }

    public func clearCache() async {
        await engine.clearCache()
    }

    private func deliver(_ stamped: PlaybackEngine.Stamped) {
        guard stamped.session == session else { return }
        switch stamped.event {
        case .advanced(let id):
            currentID = id
        case .finished:
            currentID = nil
            isPlaying = false
        case .failed(let id, _) where id == currentID:
            currentID = nil
            isPlaying = false
        default:
            break
        }
        continuation.yield(stamped.event)
    }
}
