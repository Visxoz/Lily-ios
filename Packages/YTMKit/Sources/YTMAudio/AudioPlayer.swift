import Foundation
import Network

/// Every call returns at once; the work happens on the engine's own queue, in the order called.
@MainActor public final class AudioPlayer {
    /// The most silence cut from either side of a blend, so a quiet passage or a hidden track is not taken for the end.
    nonisolated static let silenceTrimSeconds = 4.0

    /// For one consumer. Events of an item replaced by `play` or `stop` never arrive after the call.
    public let events: AsyncStream<AudioEvent>
    public private(set) var isPlaying = false

    public var equaliser: (enabled: Bool, gains: [Float]) = (false, Array(repeating: 0, count: EqualiserBands.frequencies.count)) {
        didSet {
            let (enabled, gains) = equaliser
            engine.send { $0.setEqualiser(enabled: enabled, gains: gains) }
        }
    }

    /// For headphones: each side's lows fed a little into the other, as from speakers.
    public var crossfeed = false {
        didSet { sendStereo() }
    }

    /// Each side's highs pushed further out, for a wider sound.
    public var widen = false {
        didSet { sendStereo() }
    }

    /// Both sides in each ear.
    public var mono = false {
        didSet { sendStereo() }
    }

    /// From -1, the left side alone, to 1, the right; clamped to that.
    public var balance: Float = 0 {
        didSet { sendStereo() }
    }

    /// Silences the app's own output; the level otherwise is the system volume's alone.
    public var isMuted = false {
        didSet {
            let level: Float = isMuted ? 0 : 1
            engine.send { $0.setLevel(level) }
        }
    }

    /// Record-style, the pitch moving with it. Positions, lengths and fades stay in the song's own time.
    public var speed = 1.0 {
        didSet {
            let speed = speed
            engine.send { $0.setSpeed(speed) }
        }
    }

    /// The level each item is normalised to: 1 for YouTube's reference loudness, 0.5 for 6 dB under it, or nil to
    /// play items as they are. Boosts are capped at 3 dB, and a limiter keeps peaks under full scale. A change
    /// reaches the item playing once the few seconds already scheduled have played.
    public var normalise: Float? = 1 {
        didSet {
            let normalise = normalise
            engine.send { $0.normalise = normalise }
        }
    }

    /// The engine pauses as the device playing goes away, straight from the system's notice, ahead of the controller.
    public var pauseOnUnplug = true {
        didSet {
            let on = pauseOnUnplug
            engine.send { $0.pauseOnUnplug = on }
        }
    }

    /// The cache's cap; a lower one trims at once, sparing files being read.
    public var cacheLimitBytes: Int64 {
        didSet {
            let bytes = cacheLimitBytes
            engine.send { $0.cache.setLimit(bytes) }
        }
    }

    private let continuation: AsyncStream<AudioEvent>.Continuation
    private let engine: PlaybackEngine
    private var relay: Task<Void, Never>?
    /// Counts `play` and `stop` calls, so events of what they replaced are dropped.
    private var session: UInt64 = 0
    private var currentID: String?

    /// `proxies` is asked for at the first download, off the main actor.
    public convenience init(proxies: @escaping @Sendable () -> [ProxyConfiguration]) {
        // Unbounded until the saved settings set the cap, so a launch never trims to the default.
        let cache = AudioCache.Location(directory: AudioCache.defaultDirectory, limit: .max)
        self.init(output: .device, source: HTTPByteSource(proxies: proxies), cache: cache)
    }

    init(output: PlaybackEngine.Output, source: any ByteSource, cache: AudioCache.Location) {
        cacheLimitBytes = cache.limit
        (events, continuation) = AsyncStream.makeStream(of: AudioEvent.self)
        let (stamped, sink) = AsyncStream.makeStream(of: PlaybackEngine.Stamped.self)
        engine = PlaybackEngine(output: output, source: source, cache: cache, events: sink)
        // Made now, on the engine's queue, so stale parts go before the first song's download.
        engine.send { _ = $0.cache }
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

    /// Replaces anything playing without a fade.
    public func play(_ item: AudioItem, from seconds: Double = 0, paused: Bool = false) {
        session += 1
        currentID = item.id
        isPlaying = !paused
        let session = session
        engine.send { $0.play(item, from: seconds, paused: paused, session: session) }
    }

    /// Replaces any item queued before; nil clears it. Its download starts now.
    public func setNext(_ item: AudioItem?, _ transition: Transition) {
        let session = session
        engine.send { $0.setNext(item, transition, session: session) }
    }

    /// Fetches the start of an item likely to play next, so a skip to it starts sooner; only the last is warmed.
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

    /// Pass `keepingOutput` for a change of song: a running output keeps the app awake in the background until the
    /// next one plays. Otherwise the output stops after a while, so the device can sleep.
    public func stop(keepingOutput: Bool = false) {
        session += 1
        currentID = nil
        isPlaying = false
        let session = session
        engine.send { $0.stop(session: session, keepingOutput: keepingOutput) }
    }

    /// For a media services reset, which takes the old graph with it. Mute, sound settings and speed carry over.
    public func rebuild() {
        stop()
        engine.send { $0.rebuildGraph() }
    }

    public func seek(to seconds: Double) {
        let session = session
        engine.send { $0.seek(to: seconds, session: session) }
    }

    /// Of the sound heard; cheap enough to read every frame.
    public var currentTime: Double { engine.clock.position() }

    /// Exact once the file is complete; before that, as its container states.
    public var duration: Double? { engine.clock.duration }

    /// From 0 to 1; cheap enough to read every frame.
    public var bufferedFraction: Double { engine.clock.buffered }

    public var cacheSizeBytes: Int64 {
        get async { await engine.cacheSize() }
    }

    public func clearCache() async {
        await engine.clearCache()
    }

    private func sendStereo() {
        let (crossfeed, widen, mono, balance) = (crossfeed, widen, mono, balance)
        engine.send { $0.setStereo(crossfeed: crossfeed, widen: widen, mono: mono, balance: balance) }
    }

    private func deliver(_ stamped: PlaybackEngine.Stamped) {
        guard stamped.session == session else { return }
        switch stamped.event {
        case .advanced(let id):
            currentID = id
        case .finished:
            currentID = nil
            isPlaying = false
        case .failed(let id, _) where id == currentID, .dropped(let id) where id == currentID:
            currentID = nil
            isPlaying = false
        default:
            break
        }
        continuation.yield(stamped.event)
    }
}
