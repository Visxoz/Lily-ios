import Foundation
import Synchronization
import YTMAudio
@testable import YTMCore
@testable import YTMPlayback

/// A song for tests: `album` and `number` place it on an album.
func song(_ id: String, album: String? = nil, number: Int? = nil, seconds: Int = 200, video: Bool = false) -> Track {
    Track(
        id: id, title: "Song \(id)", artists: [ArtistRef(id: "UC\(id)", name: "Artist")],
        album: album.map { AlbumRef(id: $0, name: "Album \($0)") }, duration: seconds, trackNumber: number, isVideo: video
    )
}

func songs(_ ids: String...) -> [Track] {
    ids.map { song($0) }
}

/// YouTube Music as the tests set it up: streams for every song unless told
/// otherwise, radios and Premium answers from tables, and a log of what was
/// asked.
final class FakeMusic: MusicService {
    struct State {
        var signedIn = false
        var radios: [String: [Track]] = [:]
        /// The radio of any song without one of its own.
        var anyRadio: [Track] = []
        var failing: Set<String> = []
        /// Premium answers by video ID; songs missing have no Premium formats.
        var premium: [String: Bool] = [:]
        var premiumFails = false
        var lyrics: [String: Lyrics] = [:]
        var ratings: [String: Rating] = [:]
        /// Streams held back until `release`, as a slow resolve, and the
        /// resolves waiting on them.
        var held: Set<String> = []
        var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
        var calls: [String] = []
    }

    let state = Mutex(State())

    func set(_ change: @Sendable (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    var calls: [String] { state.withLock(\.calls) }

    /// Lets `videoId`'s held streams resolve, now and from then on.
    func release(_ videoId: String) {
        let waiting = state.withLock { state in
            state.held.remove(videoId)
            return state.waiting.removeValue(forKey: videoId) ?? []
        }
        for continuation in waiting { continuation.resume() }
    }

    private func log(_ call: String) {
        state.withLock { $0.calls.append(call) }
    }

    var isSignedIn: Bool {
        get async { state.withLock(\.signedIn) }
    }

    static func stream(_ videoId: String, premium: Bool = false) -> ResolvedStream {
        ResolvedStream(
            url: URL(string: "https://rr1.googlevideo.com/videoplayback?id=\(videoId)") ?? URL(filePath: "/"),
            headers: [:], itag: premium ? 774 : 251, codec: .opus, contentLength: 1000, bitrate: 160_000,
            duration: 200, loudnessDb: 3, isPremium: premium
        )
    }

    func stream(videoId: String, quality: AudioQuality) async throws -> ResolvedStream {
        log("stream \(videoId)")
        if state.withLock({ $0.held.contains(videoId) }) {
            await withCheckedContinuation { continuation in
                let wait = state.withLock { state in
                    guard state.held.contains(videoId) else { return false }
                    state.waiting[videoId, default: []].append(continuation)
                    return true
                }
                if !wait { continuation.resume() }
            }
        }
        if state.withLock({ $0.failing.contains(videoId) }) { throw YTMError(.unplayable, "No audio.") }
        return Self.stream(videoId)
    }

    func premiumStream(videoId: String, anyFormat: Bool, maxKbps: Int?) async throws -> PremiumOutcome {
        log("premium \(videoId)")
        let (fails, has) = state.withLock { ($0.premiumFails, $0.premium[videoId]) }
        if fails { throw YTMError(.network, "Premium failed.") }
        switch has {
        case true?: return .stream(Self.stream(videoId, premium: true))
        case false?, nil: return anyFormat ? .stream(Self.stream(videoId)) : .noPremiumFormats
        }
    }

    func preparePremium() async {
        log("prepare")
    }

    func radio(videoId: String) async throws -> [Track] {
        log("radio \(videoId)")
        return state.withLock { $0.radios[videoId] ?? $0.anyRadio }
    }

    func radio(playlistId: String) async throws -> [Track] {
        log("radio \(playlistId)")
        return state.withLock { $0.radios[playlistId] } ?? []
    }

    func tracks(of card: Card) async throws -> [Track] {
        log("tracks \(card.id)")
        return state.withLock { $0.radios[card.id] } ?? []
    }

    func playlistTracks(_ playlistId: String) async throws -> [Track] {
        log("playlist \(playlistId)")
        return state.withLock { $0.radios[playlistId] } ?? []
    }

    func songVersion(of video: Track) async throws -> Track? {
        log("version \(video.id)")
        return nil
    }

    func lyrics(videoId: String) async throws -> Lyrics? {
        log("lyrics \(videoId)")
        return state.withLock { $0.lyrics[videoId] }
    }

    func rating(videoId: String) async throws -> Rating {
        state.withLock { $0.ratings[videoId] } ?? .none
    }

    func rate(videoId: String, _ rating: Rating) async throws {
        log("rate \(videoId) \(rating.rawValue)")
    }

    func createPlaylist(title: String, videoIds: [String]) async throws -> String {
        log("create \(videoIds.count)")
        return "PL1"
    }

    func reportPlay(videoId: String) async throws {
        log("report \(videoId)")
    }
}

/// The audio engine, recording what it was told; tests deliver its events.
@MainActor final class FakeAudio: AudioOutput {
    let events: AsyncStream<AudioEvent>
    var currentTime = 0.0
    var bufferedFraction = 0.0
    var equaliser: (enabled: Bool, gains: [Float]) = (false, [])
    var normalise = true
    var volume: Float = 1
    var isMuted = false
    let crossfadeSeconds = 6.0
    private(set) var played: [(item: AudioItem, from: Double, paused: Bool)] = []
    private(set) var next: AudioItem?
    private(set) var warmed: [AudioItem] = []
    private(set) var nextCrossfades = false
    private(set) var seeks: [Double] = []
    private(set) var log: [String] = []

    init() {
        events = AsyncStream { _ in }
    }

    func play(_ item: AudioItem, from seconds: Double, paused: Bool) {
        played.append((item, seconds, paused))
        currentTime = seconds
        next = nil
        log.append("play \(item.id)")
    }

    func setNext(_ item: AudioItem?, crossfade: Bool) {
        next = item
        nextCrossfades = crossfade
        log.append("next \(item?.id ?? "nil")")
    }

    func warm(_ item: AudioItem) {
        warmed.append(item)
    }

    func pause() { log.append("pause") }
    func resume() { log.append("resume") }

    func stop() {
        next = nil
        log.append("stop")
    }

    func seek(to seconds: Double) {
        seeks.append(seconds)
        currentTime = seconds
    }

    func rebuild() {
        next = nil
        log.append("rebuild")
    }
}

/// Last.fm, recording the plays it was given.
actor FakeLastFM: Scrobbling {
    nonisolated let accessRevoked = AsyncStream<Void> { _ in }
    private(set) var nowPlaying: [String] = []
    private(set) var scrobbled: [String] = []

    func nowPlaying(_ track: Track) async {
        nowPlaying.append(track.id)
    }

    func scrobble(_ track: Track, startedAt: Date) async {
        scrobbled.append(track.id)
    }
}

/// Notes an observed change, for `withObservationTracking`'s `onChange`.
final class ObservedChange: Sendable {
    private let changed = Mutex(false)

    var happened: Bool { changed.withLock { $0 } }

    func mark() {
        changed.withLock { $0 = true }
    }
}

/// A player wired to the fakes, with its own store in a temporary folder.
@MainActor struct Rig {
    let music = FakeMusic()
    let audio = FakeAudio()
    let lastFM = FakeLastFM()
    let store: FileStore
    let settings: SettingsStore
    let history: LocalHistory
    let player: PlayerController

    init(store: FileStore = FileStore(directory: .temporaryDirectory.appending(path: "ytm-tests-\(UUID().uuidString)"))) {
        self.store = store
        settings = SettingsStore(store: store)
        history = LocalHistory(store: store)
        player = PlayerController(
            music: music, settings: settings, history: history, lastFM: lastFM, audio: audio, store: store, system: false
        )
    }

    /// Lets the tasks the player started run as far as they can, waiting on none.
    func yieldToTasks() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Lets the tasks the player started run to their end.
    func settle() async {
        for _ in 0..<3 {
            await yieldToTasks()
            await player.resolving?.value
            await player.queueing?.value
            await player.extending?.value
            await player.autoplay?.value
            await player.pendingPlay?.value
        }
    }

    /// The item the engine plays now.
    var playing: AudioItem? { audio.played.last?.item }

    /// Plays the item the engine was last given until its first sound.
    func soundStarts() async {
        guard let id = playing?.id else { return }
        player.handle(.started(id: id))
        await settle()
    }
}
