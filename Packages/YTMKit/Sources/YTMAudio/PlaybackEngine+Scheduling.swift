import AVFoundation

/// Making and scheduling buffers: gapless joins, crossfades, and noticing
/// when the sound crosses into the next item or runs out.
extension PlaybackEngine {
    /// Schedules buffers until a few seconds are ahead of the player, or
    /// nothing more can be made yet.
    func fill() {
        while aheadFrames < frames(Self.aheadSeconds), let (buffer, entry) = nextBuffer() {
            schedule(buffer, entry)
        }
        if scheduled.isEmpty {
            drained()
        }
        updateBuffering()
    }

    private func frames(_ seconds: Double) -> Int {
        Int(seconds * (producing?.sampleRate ?? 48_000))
    }

    /// The next buffer to schedule, moving on to the next item when the one
    /// being made has ended and the next can follow it.
    private func nextBuffer() -> (AVAudioPCMBuffer, Scheduled)? {
        while let track = producing, track.decoder != nil {
            if let fade {
                return mixedBuffer(track, under: fade)
            }
            planFade()
            var limit = frames(Self.bufferSeconds)
            if let plan, plan.from === track {
                let left = plan.start - track.position
                guard left > 0 else {
                    beginFade(plan)
                    continue
                }
                limit = min(limit, Int(left))
            }
            if let made = decodedBuffer(track, frames: limit) {
                return made
            }
            guard track.finished, followOn() else { return nil }
        }
        return nil
    }

    /// Up to `frames` of the item's sound, at its normalisation gain.
    private func decodedBuffer(_ track: Track, frames limit: Int) -> (AVAudioPCMBuffer, Scheduled)? {
        guard case .frames = track.supply(), let (buffer, out) = Self.buffer(track, frames: limit) else { return nil }
        let first = track.position
        let gain = gainRamp(track, frames: limit)
        var filled = 0
        while filled < limit, case .frames(let count) = track.supply(), let channels = track.channels {
            let taken = min(count, limit - filled)
            Crossfade.copy(channels, gain: gain, count: taken, into: out, at: filled)
            track.decoder?.consume(taken)
            filled += taken
        }
        track.gain = gain.at(filled)
        guard filled > 0 else { return nil }
        buffer.frameLength = AVAudioFrameCount(filled)
        return (buffer, Scheduled(track: track, first: first, frames: filled))
    }

    /// The incoming item mixed over the end of the one fading out, which
    /// counts as the incoming item's: the switch is heard as the fade starts.
    private func mixedBuffer(_ track: Track, under fade: Fade) -> (AVAudioPCMBuffer, Scheduled)? {
        let count = min(frames(Self.bufferSeconds), Int(fade.remaining))
        guard track.supply() != .waiting, let (buffer, out) = Self.buffer(track, frames: count) else { return nil }
        let first = track.position
        let gains = (incoming: gainRamp(track, frames: count), outgoing: gainRamp(fade.from, frames: count))
        var filled = 0
        while filled < count {
            let incoming = track.supply()
            if incoming == .waiting {
                break
            }
            let outgoing = fade.from.supply()
            // Either side may have ended, and is silence from there: the
            // incoming item if shorter than the fade.
            let taken = min(Self.frames(in: incoming), Self.frames(in: outgoing), count - filled)
            Crossfade.mix(
                incoming: incoming == .ended ? nil : track.channels.map { ($0, gains.incoming) },
                outgoing: outgoing == .ended ? nil : fade.from.channels.map { ($0, gains.outgoing) },
                count: taken,
                at: fade.mixed + Int64(filled),
                of: fade.length,
                into: out,
                offset: filled
            )
            if incoming != .ended {
                track.decoder?.consume(taken)
            }
            if outgoing != .ended {
                fade.from.decoder?.consume(taken)
            }
            filled += taken
        }
        track.gain = gains.incoming.at(filled)
        fade.from.gain = gains.outgoing.at(filled)
        self.fade?.mixed += Int64(filled)
        if let fade = self.fade, fade.remaining <= 0 {
            self.fade = nil
        }
        guard filled > 0 else { return nil }
        buffer.frameLength = AVAudioFrameCount(filled)
        return (buffer, Scheduled(track: track, first: first, frames: filled))
    }

    /// The normalisation gain over the item's next buffer of `frames`: from
    /// where its last buffer ended to what the setting asks for now, so
    /// turning normalisation on or off reaches the item playing, past the
    /// few seconds already scheduled, without a click.
    private func gainRamp(_ track: Track, frames: Int) -> Crossfade.Ramp {
        let gain = normalise ? track.loudnessGain : 1
        return Crossfade.Ramp(from: track.gain ?? gain, to: gain, length: frames)
    }

    private static func frames(in supply: PacketDecoder.Supply) -> Int {
        if case .frames(let count) = supply { count } else { .max }
    }

    /// An empty buffer of the item's format, made only once there is sound to fill it.
    private static func buffer(_ track: Track, frames: Int) -> (AVAudioPCMBuffer, UnsafePointer<UnsafeMutablePointer<Float>>)? {
        guard frames > 0, let format = track.bufferFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return nil }
        return (buffer, UnsafePointer(out))
    }

    /// Works out the crossfade into the next item once both are ready and the
    /// item being made is complete: its trailing silence is cut, at most
    /// `silenceTrimSeconds` of it, and the fade ends where its music does.
    /// Of another rate, the next follows with a gap instead, as ytm-native does.
    private func planFade() {
        guard plan == nil, nextFade > 0, let next, next.leadTrimmed, let track = producing,
              let rate = track.sampleRate, next.sampleRate == rate,
              let end = track.soundEnd(limit: Int64(AudioPlayer.silenceTrimSeconds * rate)) else { return }
        // What is scheduled already plays as it is, so a late plan shortens the fade.
        let start = max(end - Int64(nextFade * rate), track.position)
        plan = FadePlan(from: track, start: start, length: max(end - start, 0))
    }

    private func beginFade(_ plan: FadePlan) {
        self.plan = nil
        producing = next
        next = nil
        fade = plan.length > 0 ? Fade(from: plan.from, length: plan.length) : nil
    }

    /// Moves on to the next item, once the one being made has ended, if it
    /// can follow on the same player: open, of the same rate, and for a
    /// crossfade with its leading silence cut.
    private func followOn() -> Bool {
        guard let next, let track = producing, track.failure == nil, next.sampleRate == track.sampleRate,
              nextFade <= 0 || next.leadTrimmed else { return false }
        producing = next
        self.next = nil
        plan = nil
        return true
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, _ entry: Scheduled) {
        var entry = entry
        if scheduled.isEmpty, graph.playerFormat != buffer.format {
            resetPlayer()
            guard graph.connectPlayer(buffer.format) else {
                outputFailed()
                return
            }
        }
        if fadeInNext, let out = buffer.floatChannelData {
            Crossfade.fadeIn(out, count: entry.frames, over: Int(Self.fadeInSeconds * buffer.format.sampleRate))
            fadeInNext = false
        }
        // The player ran dry before this buffer, so it starts the next item at once.
        if scheduled.isEmpty, let heard, entry.track !== heard {
            crossed(into: entry.track)
        }
        entry.start = playerFrames
        playerFrames += Int64(entry.frames)
        aheadFrames += entry.frames
        scheduled.append(entry)
        let generation = generation
        graph.player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            self?.send { $0.rendered(generation) }
        }
        if !entry.track.hasSounded {
            entry.track.hasSounded = true
            if entry.track.announcesStart {
                emit(.started(id: entry.track.item.id))
            }
        }
        if !playerRunning, !paused {
            startPlayer()
        }
    }

    /// A buffer has been rendered: the next takes over, perhaps of the next item.
    func rendered(_ generation: Int) {
        guard generation == self.generation, !scheduled.isEmpty else { return }
        let done = scheduled.removeFirst()
        aheadFrames -= done.frames
        if let following = scheduled.first, following.track !== done.track {
            crossed(into: following.track)
        }
        pinClock()
        fill()
    }

    /// The next item is now the one heard.
    private func crossed(into track: Track) {
        heard = track
        describeHeard()
        emit(.advanced(id: track.item.id))
    }

    /// Nothing is scheduled: the item heard has ended, or the download has
    /// fallen behind, and the player restarts once there is sound again.
    private func drained() {
        guard let track = producing else { return }
        if track.finished, fade == nil {
            ended()
        } else if playerRunning {
            resetPlayer()
            clock.hold()
        }
    }

    /// The item heard has played out. The next starts afresh if it could not
    /// follow on, of another rate or still opening; otherwise playback ends.
    private func ended() {
        guard let track = producing else { return }
        if let failure = track.failure {
            next?.cancel()
            next = nil
            emit(.failed(id: track.item.id, message: failure.message))
            // A next that failed before a sound of it was heard leaves the item heard to end as usual.
            if let heard, heard !== track {
                producing = heard
                finish()
                return
            }
            heard = nil
            producing = nil
            resetPlayer()
            stopOutputWhenIdle()
        } else if let next {
            if isReady(next) {
                startAfresh(next)
            } else {
                awaitingNext = true
            }
        } else {
            finish()
        }
    }

    /// Reports the end of the item heard, which must have made a sound.
    func finish() {
        guard let track = producing ?? heard else { return }
        heard = nil
        producing = nil
        resetPlayer()
        emit(track.hasSounded ? .finished : .failed(id: track.item.id, message: AudioFailure.silent.message))
        stopOutputWhenIdle()
    }

    /// Starts the next item on a fresh player timeline, as one of another
    /// rate must, after a short gap.
    func startAfresh(_ track: Track) {
        heard?.cancel()
        heard = track
        producing = track
        next = nil
        plan = nil
        awaitingNext = false
        if let rate = track.sampleRate {
            clock.pin(Double(track.position) / rate, since: nil)
        }
        describeHeard()
        emit(.advanced(id: track.item.id))
        restartPlayer()
    }

    // MARK: The player

    /// Starts the player's schedule over from the decoders' positions.
    func restartPlayer() {
        resetPlayer()
        fill()
    }

    /// Stops the player, dropping its schedule; what follows fades in.
    func resetPlayer() {
        generation += 1
        graph.player.stop()
        scheduled.removeAll()
        aheadFrames = 0
        playerFrames = 0
        playerRunning = false
        fadeInNext = true
    }

    func startPlayer() {
        guard graph.start(), (try? graph.player.playAudio()) != nil else {
            outputFailed()
            return
        }
        playerRunning = true
        clock.run()
    }

    /// The output would not take the sound, so the item heard cannot play.
    private func outputFailed() {
        let failed = heard ?? producing
        clear()
        if let failed {
            emit(.failed(id: failed.item.id, message: AudioFailure.output.message))
        }
    }

    /// Pins the clock to the frame of the item heard that the player renders now.
    private func pinClock() {
        guard let heard, let rate = heard.sampleRate,
              let last = scheduled.last(where: { $0.track === heard }) else { return }
        let end = Double(last.first + Int64(last.frames)) / rate
        guard playerRunning, let (sample, hostTime) = graph.renderedSample(),
              let entry = scheduled.first(where: { $0.track === heard && sample < $0.start + Int64($0.frames) })
        else {
            clock.pin(min(clock.position(), end), since: nil)
            return
        }
        let frame = entry.first + max(sample - entry.start, 0)
        clock.pin(Double(frame) / rate, since: hostTime, limit: end)
    }

    func updateBuffering() {
        let waiting = !paused && (producing != nil || awaitingNext) && scheduled.isEmpty
        if waiting != buffering {
            buffering = waiting
            emit(.buffering(waiting))
        }
    }
}
