import Foundation
import os
import YTMCore

/// Streams resolved ahead of time, so the next song starts without waiting
/// on YouTube, as ytm-native's `Playback::prefetched`. Each is kept with when
/// it was resolved: stream URLs last about six hours, and one older than an
/// hour is asked for again.
struct StreamPrefetcher {
    static let freshFor = Duration.seconds(60 * 60)

    struct Prefetched {
        let stream: ResolvedStream
        let resolvedAt: ContinuousClock.Instant
    }

    private var streams: [String: Prefetched] = [:]
    /// Streams being resolved ahead now, so each is asked for once, and a
    /// song started or queued meanwhile waits on its resolve rather than
    /// asking again.
    private var pending: [String: Task<ResolvedStream, any Error>] = [:]

    /// Whether a fresh stream for `id` is waiting.
    func has(_ id: String, at now: ContinuousClock.Instant = .now) -> Bool {
        streams[id].map { now - $0.resolvedAt < Self.freshFor } == true
    }

    /// Takes the stream resolved ahead for `id`, if still fresh.
    mutating func take(_ id: String, at now: ContinuousClock.Instant = .now) -> Prefetched? {
        streams.removeValue(forKey: id).flatMap { now - $0.resolvedAt < Self.freshFor ? $0 : nil }
    }

    /// Keeps a stream for `id`, dropping stale ones, such as those of songs
    /// skipped past. One handed back keeps the time it was first resolved.
    mutating func store(_ id: String, _ prefetched: Prefetched, at now: ContinuousClock.Instant = .now) {
        streams = streams.filter { now - $0.value.resolvedAt < Self.freshFor }
        streams[id] = prefetched
    }

    mutating func remove(_ id: String) {
        streams[id] = nil
    }

    /// Whether a stream for `id` is being resolved ahead.
    func isPending(_ id: String) -> Bool {
        pending[id] != nil
    }

    /// Starts resolving `id` ahead; hand the task to `finish` as it lands.
    mutating func begin(_ id: String, _ resolve: @escaping @Sendable () async throws -> ResolvedStream) -> Task<ResolvedStream, any Error> {
        let task = Task { try await resolve() }
        pending[id] = task
        return task
    }

    /// Hands a resolve still running for `id` to whatever now needs the
    /// stream, which then keeps it; its own completion stores nothing.
    mutating func takePending(_ id: String) -> Task<ResolvedStream, any Error>? {
        pending.removeValue(forKey: id)
    }

    /// Ends `task`, resolving `id`. Returns false, changing nothing, when it
    /// was taken meanwhile, or dropped by `clear` as its stream is for the
    /// old quality or account.
    mutating func finish(_ id: String, _ task: Task<ResolvedStream, any Error>) -> Bool {
        guard pending[id] == task else { return false }
        pending[id] = nil
        return true
    }

    /// Drops them all, and cancels any still resolving, as after a quality
    /// change or a Premium retry.
    mutating func clear() {
        streams.removeAll()
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
}

extension PlayerController {
    /// Gets the next song ready ahead of time, as each song starts and as
    /// the queue changes: Smart Shuffle's recommendations first, as the next
    /// song may be one of them, then a music video's song version, the next
    /// artwork, and its stream. Never waits.
    func prefetchNext() {
        topUpSmartShuffle()
        guard let next = queue.peekNext(repeat: repeatMode) else { return }
        if next.isVideo { swapInSongVersion(next) }
        // Both sizes the playing song shows, so its artwork and colours are
        // there on the first frame.
        if let art = next.thumbnail {
            Task { await ImagePipeline.shared.image(for: art, pixelEdge: ImagePipeline.playerEdge) }
            Task { await ImagePipeline.shared.image(for: art, pixelEdge: ImagePipeline.smallEdge) }
        }
        // A video whose song version is known has that resolving in its
        // place, unless it is playing, as on repeat, and stays. One still
        // being looked up resolves too, for a quick skip.
        let replaced = songVersions.knownSong(for: next.id) != nil && current?.id != next.id
        guard !replaced, !prefetcher.has(next.id), !prefetcher.isPending(next.id) else { return }
        let task = prefetcher.begin(next.id, resolver(for: next.id))
        Task { [weak self] in
            let result = await task.result
            guard let self, prefetcher.finish(next.id, task) else { return }
            switch result {
            case .success(let stream):
                prefetcher.store(next.id, .init(stream: stream, resolvedAt: .now))
                warm(next, stream)
            case .failure(let error): Logger.playback.debug("prefetch failed: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    /// Where `id`'s stream comes from as it starts or is queued: one
    /// resolved ahead, keeping when it was resolved; a resolve ahead still
    /// running, waited on rather than asked again, as a quick skip does; or
    /// a fresh resolve.
    func streamSource(for id: String) -> @Sendable () async throws -> StreamPrefetcher.Prefetched {
        if let prefetched = prefetcher.take(id) { return { prefetched } }
        if let pending = prefetcher.takePending(id) {
            return {
                let stream = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
                return .init(stream: stream, resolvedAt: .now)
            }
        }
        let resolve = resolver(for: id)
        return { .init(stream: try await resolve(), resolvedAt: .now) }
    }

    /// Has the engine fetch the start of a stream resolved ahead, as
    /// ytm-native's `warm_stream`, so a skip to it starts sooner. Only while
    /// `track` is still next: the engine warms one song, and a stream landing
    /// late for another would replace the real next song's.
    func warm(_ track: Track, _ stream: ResolvedStream) {
        guard queue.peekNext(repeat: repeatMode)?.id == track.id,
              let item = try? audioItem(for: track, stream: stream) else { return }
        audio.warm(item)
    }
}
