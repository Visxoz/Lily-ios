import Foundation
import os
import YTMCore

/// Loading songs and the transport controls, as ytm-native's `playback.rs`:
/// play, pause, seek, skip, and what happens when a song fails or the queue
/// runs out.
extension PlayerController {
    /// Pressing previous later than this into a song restarts it instead.
    static let restartAfterSeconds = 3.0

    public func togglePlayPause() {
        setPaused(isPlaying)
    }

    /// Skips to the next song; at the queue's end, with autoplay on, to the
    /// first of a radio of the last.
    public func next() {
        next(user: true)
    }

    /// Restarts the song when more than 3 s in, which counts as a new play;
    /// otherwise goes back to the song before.
    public func previous() {
        if enginePosition > Self.restartAfterSeconds {
            seek(to: 0)
            if playback.started { recordPlay() }
            return
        }
        if queue.back(repeat: repeatMode) != nil { startCurrent() }
    }

    /// Plays the queue entry at `index`, as tapping it in the queue does.
    public func jump(to index: Int) {
        if queue.jump(to: index) != nil { startCurrent() }
    }

    /// Moves to `seconds` into the song, kept short of its very end. With
    /// nothing loaded yet, the song starts there when played.
    public func seek(to seconds: Double) {
        guard let current else { return }
        let length = playback.duration
        let target = length > 0 ? max(min(seconds, length - 0.5), 0) : max(seconds, 0)
        if playback.itemID == nil {
            playback.resume = (current.id, target)
            playback.heldPosition = target
        } else {
            audio.seek(to: target)
        }
        lastSeek = Seek(count: lastSeek.count + 1, to: target)
        publishPlayback(at: target)
    }

    /// Pauses or plays on. Playing with nothing loaded, as after a launch or
    /// once the queue has played out, starts the song shown.
    func setPaused(_ paused: Bool) {
        guard current != nil else { return }
        if !paused, isStopped {
            startCurrent()
            return
        }
        if paused {
            audio.pause()
        } else {
            activateAudioSession()
            audio.resume()
        }
        isPlaying = !paused
        updateBuffering()
        publishPlayback()
    }

    /// Moves on after the song, or a skip when `user`: the next entry, a
    /// radio once the queue has played out with autoplay on, or a stop.
    func next(user: Bool) {
        if queue.advance(user: user, repeat: repeatMode) != nil {
            startCurrent()
            return
        }
        guard settings.value.autoplay, !queue.isEmpty, let seed = queue.current?.id else {
            if !user { stop() }
            return
        }
        let generation = playback.generation
        let music = music
        let pending = playback.extending ? extending : nil
        autoplay?.cancel()
        autoplay = Task { [weak self] in
            // The radio queued as this queue's last song started may still be
            // loading; it is waited for rather than asked for a second time.
            if let pending {
                await pending.value
                guard let self, !Task.isCancelled, playback.generation == generation else { return }
                if queue.advance(user: true, repeat: repeatMode) != nil {
                    startCurrent()
                    return
                }
            }
            let result = await Result { try await music.radio(videoId: seed) }
            // Something else started playing meanwhile, such as another
            // queue, and plays on as it is. Not the queue's revision: the
            // radio queued as the last song started may have just extended it.
            guard let self, !Task.isCancelled, playback.generation == generation else { return }
            switch result {
            case .success(let tracks): appendUnique(tracks)
            // Failed, it may still move on to what that radio added.
            case .failure(let error): Logger.playback.warning("autoplay radio failed: \(sentence(for: error), privacy: .public)")
            }
            if queue.advance(user: true, repeat: repeatMode) != nil {
                startCurrent()
            } else {
                stop()
            }
        }
    }

    /// Loads and plays the queue's current song.
    func startCurrent() {
        guard let track = queue.current else {
            stop()
            return
        }
        playback.generation += 1
        playback.started = false
        playback.loading = true
        playback.stalled = false
        playback.duration = track.seconds
        playback.requestedAt = .now
        playback.currentPremium = false
        // A skip to the song queued in the engine plays its stream, unless
        // that is a Premium one being retried on the free path.
        if gapless.queued?.trackID == track.id, playback.forceFree != track.id {
            gapless.unqueue(into: &prefetcher)
        } else {
            gapless.forget()
        }
        for task in [resolving, queueing, autoplay] { task?.cancel() }
        // The output runs on while the stream resolves, so iOS keeps the app
        // running, and the system's Now Playing, through a slow fetch.
        audio.stop(keepingOutput: true)
        playback.itemID = nil
        let resume = playback.resume.flatMap { $0.id == track.id ? $0.position : nil } ?? 0
        present(track, at: resume)
        updateBuffering()
        publishPlayback()
        // A stream resolved ahead needs no await, so the song loads on this
        // turn and the quality badge never shows empty in between.
        if let prefetched = prefetcher.take(track.id) {
            load(track, prefetched)
            return
        }
        stream = nil

        let source = streamSource(for: track.id)
        let generation = playback.generation
        resolving = Task { [weak self] in
            let result = await Result { try await source() }
            guard let self, !Task.isCancelled, playback.generation == generation else { return }
            switch result {
            case .success(let prefetched): load(track, prefetched)
            case .failure(let error): playbackFailed(track.title, sentence(for: error))
            }
        }
    }

    /// Hands the engine the song's stream, from a seek made or a position
    /// restored before it loaded.
    private func load(_ track: Track, _ prefetched: StreamPrefetcher.Prefetched) {
        show(prefetched.stream)
        let start = takeResumePosition()
        do {
            let item = try audioItem(for: track, stream: prefetched.stream)
            playback.itemID = item.id
            activateAudioSession()
            audio.play(item, from: start, paused: !isPlaying)
            // Kept with when it was resolved, so previous, a jump back or
            // repeat one plays it again without asking.
            prefetcher.store(track.id, prefetched)
        } catch {
            playbackFailed(track.title, error.message)
        }
    }

    /// The position to start at, if it is the current song's.
    private func takeResumePosition() -> Double {
        defer { playback.resume = nil }
        guard let resume = playback.resume, resume.id == queue.current?.id else { return 0 }
        return resume.position
    }

    /// A song that couldn't load or play. A Premium stream gets one retry on
    /// the free one, carrying on from where the sound got to without
    /// counting a second play; otherwise the next song plays, until a few
    /// in a row have failed.
    func playbackFailed(_ title: String, _ message: String) {
        Logger.playback.warning("playback failed: \(message, privacy: .public)")
        // A stream that would not play is not handed out again.
        if let id = queue.current?.id { prefetcher.remove(id) }
        if let id = queue.current?.id, playback.currentPremium, playback.forceFree != id {
            playback.currentPremium = false
            playback.forceFree = id
            prefetcher.clear()
            Logger.premium.info("\(id, privacy: .public): Premium stream failed to play (\(message, privacy: .public)); retrying the free stream")
            restartCurrent()
            return
        }
        playback.failures += 1
        say("Couldn't play “\(title)”: \(message)")
        if playback.failures < Self.maxConsecutiveFailures, queue.peekNext(repeat: repeatMode) != nil {
            next(user: true)
        } else {
            // Stopped like any other end, so nothing runs on.
            stop()
        }
    }

    /// The system's media services restarted, taking the engine's audio
    /// graph with them: the graph is made afresh, and a song that was loaded
    /// starts again from where its sound got to. That is read first, as the
    /// rebuild stops the sound, and the song loads once the new graph is
    /// made: a stream kept for it loads at once.
    func mediaServicesReset() {
        let position = enginePosition
        audio.rebuild()
        if !isStopped { restartCurrent(from: position) }
    }

    /// Loads the current song again, carrying on from where the sound got
    /// to, or `position`, without counting a second play. At the very end,
    /// as when the next song fails to open, there is nothing left to carry
    /// on, so it starts over.
    private func restartCurrent(from position: Double? = nil) {
        guard let id = queue.current?.id else { return }
        let position = position ?? enginePosition
        let carryOn = playback.started && (playback.duration <= 0 || position < playback.duration - 1)
        if carryOn { playback.resume = (id, position) }
        startCurrent()
        if carryOn { playback.playRecorded = playback.generation }
    }

    /// Stops the sound, keeping the song shown where it got to.
    func stop() {
        playback.heldPosition = enginePosition
        playback.started = false
        playback.loading = false
        playback.itemID = nil
        resolving?.cancel()
        gapless.unqueue(into: &prefetcher)
        audio.stop(keepingOutput: false)
        isPlaying = false
        updateBuffering()
        publishPlayback()
    }
}
