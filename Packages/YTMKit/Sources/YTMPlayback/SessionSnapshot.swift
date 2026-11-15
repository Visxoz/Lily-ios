import Foundation
import YTMCore

/// The queue and position kept between launches as session.json, restored
/// paused on the next start, as ytm-native's `settings::Session`.
struct SessionSnapshot: Codable, Equatable, Sendable {
    /// Longest queue kept between launches.
    static let limit = 500

    var queue: [Track]
    var index: Int
    var position: Double
    /// Length of the current song, which feed cards do not carry.
    var duration: Double
    /// Queue entries Smart Shuffle put in.
    var recommended: [Int]

    /// The part of a queue `count` long that is kept: all of it, or the
    /// window around the entry at `index` if it is long.
    static func window(count: Int, index: Int) -> Range<Int> {
        guard count > limit else { return 0..<count }
        let start = max(index - limit / 2, 0)
        return start..<min(start + limit, count)
    }

    /// The window of `queue` around its current entry; nil for an empty queue.
    init?(_ queue: Queue<Track>, position: Double, duration: Double) {
        guard let current = queue.currentIndex else { return nil }
        let window = Self.window(count: queue.count, index: current)
        self.queue = Array(queue.items[window])
        index = current - window.lowerBound
        self.position = position
        self.duration = duration
        recommended = queue.recommendedIndices.filter(window.contains).map { $0 - window.lowerBound }
    }

    /// Reads session.json off the main actor; nil when it is missing, can't
    /// be read or names no entry.
    @concurrent
    static func load(from store: FileStore) async -> SessionSnapshot? {
        store.load(SessionSnapshot.self, from: .session).flatMap { $0.queue.indices.contains($0.index) ? $0 : nil }
    }
}

extension PlayerController {
    /// Writes the session shortly, once things settle, so skipping through
    /// songs costs one write.
    func persistSoon() {
        sessionSaving.schedule { [weak self] in self?.writeSession() }
    }

    /// Writes the session, history and settings now, as when the app leaves
    /// the foreground, so nothing waiting on a delayed save is lost.
    public func persistSession() {
        sessionSaving.cancel()
        writeSession()
        history.saveNow()
        settings.saveNow()
    }

    private func writeSession() {
        let position = if let resume = playback.resume, resume.id == current?.id { resume.position }
            else if playback.started { audio.currentTime } else { 0.0 }
        guard let snapshot = SessionSnapshot(queue, position: position, duration: playback.duration) else { return }
        store.save(snapshot, to: .session)
    }

    /// Shows the last launch's song, paused, ready to resume where it was,
    /// and returns it.
    func restoreSession() async -> Track? {
        guard let session = await SessionSnapshot.load(from: store), current == nil else { return nil }
        let track = session.queue[session.index]
        replaceQueue(with: session.queue, start: session.index, shuffle: false)
        queue.markRecommended(session.recommended)
        playback.resume = (track.id, session.position)
        playback.duration = track.duration.map(Double.init) ?? session.duration
        playback.heldPosition = session.position
        current = track
        duration = playback.duration
        nowPlaying?.show(track, duration: duration)
        publishPlayback()
        return track
    }

    /// The launch's network work: Premium's player script, and the restored
    /// song's rating and stream while it is still the song shown. The rating
    /// only while none has been set or loaded since `rating`, the rating
    /// generation at restore.
    func warmUp(_ restored: Track?, rating: UInt64) {
        preparePremium()
        guard let restored, current?.id == restored.id else { return }
        if ratingGeneration == rating { loadRating(of: restored.id) }
        // So the launch's first play starts without waiting on YouTube,
        // unless a play is already fetching or playing it. Not warmed: the
        // play fetches the start itself.
        guard isStopped else { return }
        resolveAhead(restored, warming: false)
    }
}
