import Foundation
import Observation
import os
import YTMAudio
import YTMCore

/// The player: the queue, the song playing and everything about it, tying
/// YouTube Music to the audio engine, as ytm-native's `src/app/` does
/// without its UI.
///
/// Call `start()` once at launch. Everything here runs on the main actor and
/// returns at once; network and disk work runs off it, and a result that
/// arrives after the player has moved on is dropped.
///
/// The position is never pushed through observation: read `currentTime`
/// from a `TimelineView`. Everything else that changes is observable.
@MainActor @Observable public final class PlayerController {
    /// How often the player looks at the sound while it plays: to queue the
    /// next song, count scrobbles and keep Now Playing's position right.
    nonisolated static let tick = Duration.milliseconds(250)
    /// Songs in a row that fail before the player stops trying the next.
    static let maxConsecutiveFailures = 3

    /// What plays now and next. Change it through the player's methods.
    public internal(set) var queue = Queue<Track>()
    /// The song shown as playing, also while it loads, and after it stopped
    /// or was restored from the last launch.
    public internal(set) var current: Track?
    /// Whether the player means to play: true from a song's request,
    /// through loading and stalls, until paused or stopped. The play button.
    public internal(set) var isPlaying = false {
        didSet { if isPlaying != oldValue { updateTicking() } }
    }
    /// Loading the song, or stalled waiting on the network while playing.
    public internal(set) var isBuffering = false
    /// The song's length in seconds; 0 until known.
    public internal(set) var duration = 0.0
    /// The playing song's lyrics. They load while `showsLyrics` is set.
    public internal(set) var lyrics = LyricsState.idle
    /// Set while lyrics are on screen, so they load for each song then, as
    /// ytm-native loads them while its Lyrics tab is open.
    public var showsLyrics = false {
        didSet { if showsLyrics, !oldValue { loadLyrics() } }
    }
    /// How the account rated the song playing; `.none` signed out.
    public internal(set) var rating = Rating.none {
        didSet { nowPlaying?.setLike(isLiked: rating == .like, enabled: signedIn) }
    }
    /// The playing song's stream: `badge` ("OPUS 165") and `isPremium` for
    /// the player's quality mark. Nil while it loads.
    public internal(set) var stream: ResolvedStream?
    /// Whether the account plays Premium streams, as found so far; its
    /// `summary` is Settings' line about Premium audio.
    public internal(set) var premiumStatus = PremiumStatus.unknown
    /// Bumped when the account's library changes from here (a song rated, the
    /// queue saved as a playlist), so the app can load cached library pages
    /// and Liked music afresh.
    public internal(set) var libraryRevision = 0
    /// The last seek, so views that pull `currentTime` only while the song
    /// plays still catch one made while paused, at the place sought, which
    /// the engine may not have reached yet.
    public internal(set) var lastSeek = Seek(count: 0, to: 0)

    /// Messages for the user, shown briefly, as ytm-native's toasts: a song
    /// that couldn't play, "“Song” plays next", a rating saved. One consumer,
    /// which must live as long as the player rather than be a view's task:
    /// cancelling the loop that reads it ends the stream for good.
    public nonisolated let toasts: AsyncStream<String>

    /// Where the song has got to, in seconds. Cheap; not observed.
    public var currentTime: Double {
        playback.itemID != nil ? audio.currentTime : playback.heldPosition
    }

    /// How much of the song has downloaded, from 0 to 1, for the seek bar's
    /// buffered fill. Cheap; not observed, so pull it as `currentTime` is.
    public var bufferedFraction: Double {
        playback.itemID != nil ? audio.bufferedFraction : 0
    }

    // MARK: Collaborators

    @ObservationIgnored let music: any MusicService
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let history: LocalHistory
    @ObservationIgnored let audio: any AudioOutput
    @ObservationIgnored let store: FileStore
    @ObservationIgnored let chooser: StreamChooser
    @ObservationIgnored let recorder: PlayRecorder
    @ObservationIgnored var nowPlaying: NowPlayingCenter?
    @ObservationIgnored private var audioSession: AudioSessionController?
    @ObservationIgnored private let toastSink: AsyncStream<String>.Continuation

    // MARK: State, never observed

    @ObservationIgnored var playback = PlaybackState()
    @ObservationIgnored var gapless = GaplessScheduler()
    @ObservationIgnored var prefetcher = StreamPrefetcher()
    @ObservationIgnored var smart = SmartShuffle()
    @ObservationIgnored var songVersions = SongVersionSwapper()
    @ObservationIgnored var signedIn = false
    /// The settings last put into effect, to tell what a change changed.
    @ObservationIgnored var applied: Settings?
    @ObservationIgnored let sessionSaving = Debounce()
    /// The song whose lyrics are shown or loading.
    @ObservationIgnored var lyricsFor: String?
    /// Lyrics found, nil for songs without, so a song played again shows
    /// them at once. Failures are never kept.
    @ObservationIgnored var lyricsCache: [String: Lyrics?] = [:]
    static let lyricsCacheLimit = 32
    /// Bumped as the playing song changes or is rated, so a rating fetched
    /// before then is not shown.
    @ObservationIgnored var ratingGeneration: UInt64 = 0
    @ObservationIgnored private var itemSerial: UInt64 = 0
    @ObservationIgnored private var hasStarted = false

    // MARK: Tasks, cancelled on replacement and with the player

    @ObservationIgnored var listening: [Task<Void, Never>] = []
    @ObservationIgnored private var ticking: Task<Void, Never>?
    /// The playing song's stream being resolved.
    @ObservationIgnored var resolving: Task<Void, Never>?
    /// The next song's stream being resolved to queue it in the engine.
    @ObservationIgnored var queueing: Task<Void, Never>?
    /// A radio carrying the queue on: the one after a song a radio started
    /// from, or the one queued as the last song starts.
    @ObservationIgnored var extending: Task<Void, Never>?
    /// A radio fetched once the queue has played out, to move on to.
    @ObservationIgnored var autoplay: Task<Void, Never>?
    /// What a page or card asked to play, while its tracks load.
    @ObservationIgnored var pendingPlay: Task<Void, Never>?
    /// The rest of a long playlist being added, batch by batch, after its
    /// first batch started playing.
    @ObservationIgnored var continuing: Task<Void, Never>?
    @ObservationIgnored var lyricsLoad: Task<Void, Never>?
    @ObservationIgnored var ratingLoad: Task<Void, Never>?

    /// The player of the app, with Now Playing, the remote commands and the
    /// audio session.
    public convenience init(
        api: YTMusic = .shared, settings: SettingsStore = .shared, history: LocalHistory = .shared,
        lastFM: LastFM = .shared, audio: AudioPlayer = AudioPlayer()
    ) {
        self.init(music: api, settings: settings, history: history, lastFM: lastFM, audio: audio, store: .shared, system: true)
    }

    /// `system` hooks up Now Playing, the remote commands and the audio
    /// session; tests leave them out.
    init(
        music: any MusicService, settings: SettingsStore, history: LocalHistory, lastFM: any Scrobbling,
        audio: any AudioOutput, store: FileStore, system: Bool
    ) {
        self.music = music
        self.settings = settings
        self.history = history
        self.audio = audio
        self.store = store
        chooser = StreamChooser(music: music)
        recorder = PlayRecorder(history: history, music: music, lastFM: lastFM)
        (toasts, toastSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
        if system {
            nowPlaying = NowPlayingCenter(player: self)
            audioSession = AudioSessionController(player: self)
        }
        listening = [
            Task { [weak self, events = audio.events] in
                for await event in events {
                    self?.handle(event)
                }
            },
            Task { [weak self, revoked = lastFM.accessRevoked] in
                for await _ in revoked {
                    self?.say("Last.fm no longer allows access. Connect it again in Settings.")
                }
            },
        ]
    }

    isolated deinit {
        for task in listening + [ticking, resolving, queueing, extending, autoplay, pendingPlay, continuing, lyricsLoad, ratingLoad] {
            task?.cancel()
        }
        toastSink.finish()
    }

    /// Readies the player at launch, as ytm-native's `App::start`: reads the
    /// settings and history, puts the settings into effect and follows their
    /// changes from then on, prepares the Premium path, and shows the last
    /// launch's song, paused, ready to resume where it was. Later calls do
    /// nothing.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await settings.load()
        await history.load()
        signedIn = await music.isSignedIn
        chooser.seed(known: settings.value.premiumAccount, none: settings.value.noPremium)
        premiumStatus = chooser.status
        apply(settings.value)
        followSettings()
        preparePremium()
        await restoreSession()
    }

    // MARK: Engine events

    func handle(_ event: AudioEvent) {
        switch event {
        case .started(let id):
            if id == playback.itemID { soundStarted() }
        case .advanced(let id):
            if let queued = gapless.queued, queued.itemID == id {
                gapless.forget()
                advanceGapless(to: queued)
            } else {
                // A song the player no longer had queued crossed over, as the
                // queue changed at that very moment; play what it says now.
                gapless.forget()
                next(user: false)
            }
        case .finished:
            next(user: false)
        case .failed(let id, let message):
            // The queued song failed to open: the current one ends with
            // `finished`, and the next then loads afresh.
            if id == gapless.queued?.itemID {
                gapless.queuedFailed = true
                // Its stream may be kept too; the song then resolves afresh.
                if let trackID = gapless.queued?.trackID { prefetcher.remove(trackID) }
            } else if id == playback.itemID {
                playbackFailed(current?.title ?? "", message)
            }
        case .buffering(let stalled):
            playback.stalled = stalled
            updateBuffering()
            publishPlayback()
        case .nextDropped:
            gapless.unqueue(into: &prefetcher)
        }
    }

    /// The song's first sound: it counts as played, unless it carries on a
    /// play already recorded, as a Premium song retried on the free stream.
    private func soundStarted() {
        playback.started = true
        playback.loading = false
        playback.failures = 0
        let recorded = playback.playRecorded == playback.generation
        playback.playRecorded = nil
        if !recorded { recordPlay() }
        if let requested = playback.requestedAt {
            let waited = Int(((ContinuousClock.now - requested).seconds * 1000).rounded())
            let path = playback.currentPremium ? "Premium" : "free"
            Logger.playback.info("first sound after \(waited, privacy: .public) ms (\(path, privacy: .public), \(self.stream?.badge ?? "", privacy: .public))")
            playback.requestedAt = nil
        }
        updateBuffering()
        publishPlayback()
        syncPremiumStatus()
        extendWithRadioIfEnding()
        prefetchNext()
    }

    /// The one place a play is recorded, as ytm-native's `record_play`: the
    /// local history, Last.fm and, signed in, the account's YouTube history.
    func recordPlay() {
        guard let track = queue.current else { return }
        recorder.record(track, reportToYouTube: signedIn && settings.value.youtubeHistory)
        persistSoon()
    }

    // MARK: The tick

    /// Runs the tick while playing only, so a paused player does no work.
    private func updateTicking() {
        ticking?.cancel()
        ticking = nil
        guard isPlaying else { return }
        ticking = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: Self.tick, tolerance: .milliseconds(50))
                } catch {
                    return
                }
                self?.onTick()
            }
        }
    }

    func onTick() {
        syncPremiumStatus()
        guard playback.started else { return }
        let position = audio.currentTime
        recorder.heard(position: position, length: playback.duration)
        updateGapless(at: position)
        nowPlaying?.keep(elapsed: position, advancing: isAdvancing)
    }

    // MARK: Shared helpers

    /// The repeat mode every queue move follows.
    var repeatMode: RepeatMode { settings.value.repeatMode }

    /// Nothing is loaded for the song shown, as after a launch or once the
    /// queue has played out.
    var isStopped: Bool { !playback.started && !playback.loading }

    /// Where the engine's sound is; 0 while it has no song.
    var enginePosition: Double { playback.itemID != nil ? audio.currentTime : 0 }

    /// The sound is moving on: playing, started and not stalled.
    var isAdvancing: Bool { isPlaying && playback.started && !playback.stalled }

    func updateBuffering() {
        let buffering = playback.loading || (playback.stalled && isPlaying)
        if isBuffering != buffering { isBuffering = buffering }
    }

    /// Tells Now Playing whether and where the song plays; `position` for a
    /// seek the engine has yet to carry out.
    func publishPlayback(at position: Double? = nil) {
        nowPlaying?.setPlayback(playing: isPlaying, advancing: isAdvancing, elapsed: position ?? currentTime)
    }

    func say(_ message: String) {
        Logger.playback.info("\(message, privacy: .public)")
        toastSink.yield(message)
    }

    func activateAudioSession() {
        audioSession?.activate()
    }

    /// Resolves `videoId`'s stream with the settings and account as they are
    /// now, so the work can run, and run again, off the main actor.
    func resolver(for videoId: String) -> @Sendable () async throws -> ResolvedStream {
        let (chooser, quality, signedIn) = (chooser, settings.value.quality, signedIn)
        let wantPremium = signedIn && quality == .high && playback.forceFree != videoId
        return { try await chooser.resolve(videoId: videoId, wantPremium: wantPremium, signedIn: signedIn, quality: quality) }
    }

    /// The engine's item for `track`'s stream. Each has its own ID, so a song
    /// queued after itself, as on repeat, is told apart. Should googlevideo
    /// refuse its URL partway, the download asks the path that gave it for a
    /// fresh one, taken only for the same file (its format and length), so
    /// the download carries on from the same byte, with the headers of the
    /// client that gave it, as googlevideo checks them. The engine can't import
    /// YTMCore, so every URL, refreshed ones too, is checked against the host
    /// allowlist here.
    func audioItem(for track: Track, stream: ResolvedStream) throws(YTMError) -> AudioItem {
        guard HostAllowlist.allows(stream.url) else { throw Self.blocked }
        itemSerial += 1
        // Only ever turned down, as ytm-native: YouTube's loudness above its
        // reference level, which the engine applies while normalising.
        let loudness = -Float(max(stream.loudnessDb ?? 0, 0))
        let (chooser, quality, signedIn, videoId) = (chooser, settings.value.quality, signedIn, track.id)
        return AudioItem(
            id: "\(track.id)#\(itemSerial)", url: stream.url, headers: stream.headers, contentLength: stream.contentLength,
            cacheKey: "\(track.id)-\(stream.itag)", loudnessDB: loudness
        ) {
            let fresh = try await chooser.refresh(videoId: videoId, wasPremium: stream.isPremium, signedIn: signedIn, quality: quality)
            guard fresh.itag == stream.itag, fresh.contentLength == stream.contentLength else { throw Self.otherFile }
            guard HostAllowlist.allows(fresh.url) else { throw Self.blocked }
            return (url: fresh.url, headers: fresh.headers)
        }
    }

    private nonisolated static let blocked = YTMError(.refused, "The app blocked a request to a site it doesn't use.")
    private nonisolated static let otherFile = YTMError(.unplayable, "YouTube offered a different file partway through the song.")

    /// Replaces the queue, dropping what was on its way for the old one:
    /// Smart Shuffle's batch, a radio carrying it on, a card's tracks, a
    /// playlist's later batches.
    func replaceQueue(with tracks: [Track], start: Int, shuffle: Bool) {
        queue.set(items: tracks, start: start, shuffle: shuffle)
        smart.reset()
        for task in [extending, autoplay, pendingPlay, continuing] { task?.cancel() }
        playback.extending = false
    }
}

/// A seek, and how many there have been, so seeking to the same place again
/// still counts as a change.
public struct Seek: Equatable, Sendable {
    public let count: Int
    /// Where to, in seconds.
    public let to: Double
}
