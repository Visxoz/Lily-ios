import Foundation
import os
import YTMAudio
import YTMCore

/// Queues the next song in the engine shortly before the current one ends,
/// so it follows without a gap or fades in, as ytm-native's `gapless.rs`.
struct GaplessScheduler {
    /// How long before a song ends the next is queued: time for its stream
    /// to start downloading and its decoder to open. A crossfade adds its
    /// own length and the silence it may cut, as the engine holds that much
    /// of the current song back.
    static let leadSeconds = 15.0

    /// The next song, queued in the engine to follow the current one.
    struct Queued {
        let trackID: String
        /// The engine's ID for it, so its events can be told from the current one's.
        let itemID: String
        let prefetched: StreamPrefetcher.Prefetched
    }

    private(set) var queued: Queued?
    /// The engine could not open the queued stream, so `unqueue` drops it.
    /// Only a flag, as the event may be late for a song queued since, which
    /// then just resolves again.
    var queuedFailed = false
    /// The song last tried for queueing, so a failure is not retried every
    /// tick; it then loads as usual when the current one ends.
    private(set) var tried: String?

    /// Whether `next` follows `current` on its album, which is often written
    /// to run straight on, so it is never faded into.
    static func inAlbumOrder(_ current: Track?, _ next: Track) -> Bool {
        guard let current, let album = current.album?.id, album == next.album?.id else { return false }
        guard let a = current.trackNumber, let b = next.trackNumber else { return true }
        return a < .max && a + 1 == b
    }

    /// Seconds before the end at which the next song is queued.
    static func lead(crossfade: Double) -> Double {
        crossfade > 0 ? leadSeconds + crossfade + AudioPlayer.silenceTrimSeconds : leadSeconds
    }

    /// What a tick at `position` calls for: dropping a queued song the queue
    /// no longer has next, and the next song to queue now, with its fade.
    func plan(
        position: Double, duration: Double, started: Bool, current: Track?, next: Track?, crossfadeSeconds: Double?
    ) -> (stale: Bool, due: (id: String, crossfade: Double)?) {
        let fade = if let crossfadeSeconds, let next, !Self.inAlbumOrder(current, next) { crossfadeSeconds } else { 0.0 }
        let stale = queued.map { $0.trackID != next?.id } ?? false
        let nearEnd = started && duration > 0 && duration - position <= Self.lead(crossfade: fade) && (queued == nil || stale)
        guard nearEnd, let next, tried != next.id else { return (stale, nil) }
        return (stale, (next.id, fade))
    }

    mutating func markTried(_ id: String) {
        tried = id
    }

    mutating func setQueued(_ queued: Queued) {
        self.queued = queued
        queuedFailed = false
    }

    /// Forgets the queued song, so the next one is queued afresh. The
    /// engine's own copy is dropped with `setNext(nil)`.
    mutating func forget() {
        queued = nil
        queuedFailed = false
        tried = nil
    }

    /// Forgets the queued song as `forget` does, but hands its stream back
    /// to `prefetcher`, so queueing or playing it again asks for nothing.
    /// Not for a quality change or a Premium retry, which must drop it.
    mutating func unqueue(into prefetcher: inout StreamPrefetcher) {
        if let queued, !queuedFailed {
            prefetcher.store(queued.trackID, queued.prefetched)
        }
        forget()
    }
}

extension PlayerController {
    /// Run every tick while playing: queues the next song in the engine
    /// shortly before the current one ends, and drops a queued song the
    /// queue no longer has next. Copies nothing until a song is due.
    func updateGapless(at position: Double) {
        let next = queue.peekNext(repeat: repeatMode)
        let plan = gapless.plan(
            position: position, duration: playback.duration, started: playback.started,
            current: queue.current, next: next, crossfadeSeconds: settings.value.crossfade ? audio.crossfadeSeconds : nil
        )
        if plan.stale { dropQueuedNext() }
        guard let (nextID, fade) = plan.due, let next else { return }
        gapless.markTried(nextID)
        // Kept with the time it was resolved, so one handed back stays only
        // as fresh as it was. A resolve ahead is only waited on, so a skip
        // that cancels this still starts the song from it.
        let source = streamSource(for: nextID, owning: false)
        let generation = playback.generation
        queueing = Task { [weak self] in
            let result = await Result(source)
            guard let self, !Task.isCancelled, playback.generation == generation,
                  queue.peekNext(repeat: repeatMode)?.id == nextID else { return }
            do {
                let prefetched = try result.get()
                let item = try audioItem(for: next, stream: prefetched.stream)
                audio.setNext(item, crossfade: fade > 0)
                gapless.setQueued(.init(trackID: nextID, itemID: item.id, prefetched: prefetched))
            } catch {
                Logger.playback.debug("could not queue the next track: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    /// Drops the song queued in the engine, or being queued, keeping a
    /// queued stream for later. Forgetting what was tried has the song
    /// queued again at the next tick, with the settings as they are then.
    func dropQueuedNext() {
        queueing?.cancel()
        guard gapless.queued != nil else { return gapless.forget() }
        gapless.unqueue(into: &prefetcher)
        audio.setNext(nil, crossfade: false)
    }

    /// The queued song became audible: move the queue on and show it,
    /// without loading anything.
    func advanceGapless(to queued: GaplessScheduler.Queued) {
        guard let track = queue.advance(user: false, repeat: repeatMode), track.id == queued.trackID else {
            // The queue changed under the engine; play what it says now.
            startCurrent()
            return
        }
        playback.generation += 1
        playback.started = true
        playback.failures = 0
        playback.duration = track.seconds
        playback.requestedAt = nil
        playback.resume = nil
        playback.itemID = queued.itemID
        present(track, at: 0)
        recordPlay()
        show(queued.prefetched.stream)
        // Kept, as a song started by `play` is, for previous, a jump back or
        // repeat one.
        prefetcher.store(track.id, queued.prefetched)
        updateBuffering()
        publishPlayback()
        extendWithRadioIfEnding()
        prefetchNext()
    }
}
