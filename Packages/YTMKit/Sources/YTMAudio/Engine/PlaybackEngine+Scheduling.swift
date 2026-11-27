import AVFoundation

extension PlaybackEngine {
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

    private func nextBuffer() -> (AVAudioPCMBuffer, Scheduled)? {
        while let track = producing, track.decoder != nil {
            if let fade {
                return mixedBuffer(track, under: fade)
            }
            planFade()
            var limit = frames(Self.bufferSeconds)
            if let plan, plan.from === track {
                if let curve = plan.curve, track.warp == nil, track.position >= plan.start {
                    track.startWarp(curve)
                }
                // Frames before the fade: to the plan's start, then through any varispeed's ramp.
                let left = track.warp?.beforeSpeed ?? plan.start - track.position
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

    private func decodedBuffer(_ track: Track, frames limit: Int) -> (AVAudioPCMBuffer, Scheduled)? {
        guard case .frames = track.supply(), let (buffer, out) = Self.buffer(track, frames: limit) else { return nil }
        let first = track.position
        let gain = gainRamp(track, frames: limit)
        var filled = 0
        while filled < limit, case .frames(let count) = track.supply(), let channels = track.channels {
            let taken = min(count, limit - filled)
            Crossfade.copy(channels, gain: gain, count: taken, into: out, at: filled)
            track.consume(taken)
            filled += taken
        }
        track.gain = gain.at(filled)
        guard filled > 0 else { return nil }
        buffer.frameLength = AVAudioFrameCount(filled)
        return (buffer, Scheduled(track: track, first: first, frames: filled, song: track.position - first))
    }

    /// Counts as the incoming item's buffer: the switch is heard as the fade starts.
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
            // The outgoing item has fallen behind its download, so the fade waits for it too.
            if outgoing == .waiting {
                break
            }
            // Either side may have ended, and is silence from there.
            let taken = min(Self.frames(in: incoming), Self.frames(in: outgoing), count - filled)
            fade.mixer.mix(
                incoming: incoming == .ended ? nil : track.channels,
                outgoing: outgoing == .ended ? nil : fade.from.channels,
                gains: gains,
                count: taken,
                at: Int(fade.mixed) + filled,
                into: out,
                offset: filled
            )
            if incoming != .ended {
                track.consume(taken)
            }
            if outgoing != .ended {
                fade.from.consume(taken)
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
        return (buffer, Scheduled(track: track, first: first, frames: filled, song: track.position - first))
    }

    /// The most a quiet track is turned up, +3 dB, as its peaks are unknown and quiet tracks are often the
    /// dynamic ones; the sound unit's limiter catches the rest.
    static let maxBoost: Float = 1.412_537_5

    /// The gain played for a track whose loudness correction is `gain`. The cap comes after the level, so Quiet
    /// turns up as far as Normal does.
    static func normalised(_ gain: Float, by level: Float?) -> Float {
        level.map { min(gain * $0, maxBoost) } ?? 1
    }

    /// Ramps from where the last buffer ended, so a change of normalisation reaches the item playing without a click.
    private func gainRamp(_ track: Track, frames: Int) -> Crossfade.Ramp {
        let gain = Self.normalised(track.loudnessGain, by: normalise)
        return Crossfade.Ramp(from: track.gain ?? gain, to: gain, length: frames)
    }

    private static func frames(in supply: PacketDecoder.Supply) -> Int {
        if case .frames(let count) = supply { count } else { .max }
    }

    private static func buffer(_ track: Track, frames: Int) -> (AVAudioPCMBuffer, UnsafePointer<UnsafeMutablePointer<Float>>)? {
        guard frames > 0, let format = track.bufferFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return nil }
        return (buffer, UnsafePointer(out))
    }

    /// Cuts at most `silenceTrimSeconds` of trailing silence so the blend ends where the music does. A next item of
    /// another rate follows with a gap instead.
    private func planFade() {
        guard plan == nil, let next, next.leadTrimmed, let track = producing,
              let rate = track.sampleRate, next.sampleRate == rate, track.length != nil else { return }
        let limit = Int64(AudioPlayer.silenceTrimSeconds * rate)
        let (end, length, style, warp): (Int64, Int64, Automix.Style, (start: Int64, curve: Varispeed)?)
        switch nextTransition {
        case .gapless:
            return
        case .crossfade(let seconds):
            guard let found = track.soundEnd(limit: limit) else { return }
            (end, length, style, warp) = (found, Int64(seconds * rate), .crossfade, nil)
        case .automix:
            guard let intro = next.intro(frames: Int64(Automix.introSeconds * rate)),
                  let (found, tail) = track.tail(limit: limit, frames: Int64(Automix.tailSeconds * rate)) else { return }
            let voices = Automix.Voices(nextSung, tailEnd: Double(found) / rate, introStart: Double(next.position) / rate, rate: rate)
            // Within what is yet to be scheduled, so the beats still land together.
            let mix = Automix.plan(tail: tail, intro: intro, rate: rate, room: Int(max(found - track.position, 0)), voices: voices)
            // The tail's frames counted from the item's, and the varispeed from as far back as its taps reach.
            let tailStart = found - Int64(tail.frames)
            (end, length, style) = (found, Int64(mix.frames), mix.style)
            warp = mix.warp.map { (tailStart + Int64($0.start) - Int64(Varispeed.reach), $0.curve) }
        }
        // What is scheduled already plays as it is, so a late plan shortens a crossfade; Automix plans within it.
        let start = max(warp?.start ?? end - length, track.position)
        let frames = warp == nil ? max(end - start, 0) : length
        plan = FadePlan(
            from: track, start: start, length: frames, mixer: Automix.Mixer(frames: Int(frames), style: style, rate: rate),
            curve: warp?.curve
        )
    }

    private func beginFade(_ plan: FadePlan) {
        self.plan = nil
        producing = next
        next = nil
        fade = plan.length > 0 ? Fade(from: plan.from, length: plan.length, mixer: plan.mixer) : nil
    }

    private func followOn() -> Bool {
        guard let next, let track = producing, track.failure == nil, next.sampleRate == track.sampleRate,
              nextTransition == .gapless || next.leadTrimmed else { return false }
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

    private func crossed(into track: Track) {
        heard = track
        describeHeard()
        emit(.advanced(id: track.item.id))
    }

    /// Nothing is scheduled: the item heard has ended, or the download has fallen behind.
    private func drained() {
        guard let track = producing else { return }
        if track.finished, fade == nil {
            ended()
        } else if playerRunning {
            resetPlayer()
            clock.hold()
        }
    }

    /// The item has played out; a next that could not follow on (another rate, or still opening) starts afresh.
    private func ended() {
        guard let track = producing else { return }
        if let failure = track.failure {
            next?.cancel()
            next = nil
            emit(Self.event(track, failure))
            // A next that failed before a sound of it was heard leaves the item heard to end as usual.
            if let heard, heard !== track {
                producing = heard
                finish()
                return
            }
            heard = nil
            producing = nil
            resetPlayer()
            // Should the player not answer the failure, the output still sleeps.
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

    /// An item's failure, as a dropped connection when its download says so.
    static func event(_ track: Track, _ failure: AudioFailure) -> AudioEvent {
        failure == .dropped ? .dropped(id: track.item.id) : .failed(id: track.item.id, message: failure.message)
    }

    /// A silent item's failure may go unanswered by the player, so the output still sleeps after it.
    func finish() {
        guard let track = producing ?? heard else { return }
        heard = nil
        producing = nil
        resetPlayer()
        if track.hasSounded {
            emit(.finished)
        } else {
            emit(.failed(id: track.item.id, message: AudioFailure.silent.message))
            stopOutputWhenIdle()
        }
    }

    /// Starts the item on a fresh player timeline, as one of another rate must.
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

    func restartPlayer() {
        resetPlayer()
        fill()
    }

    /// Drops the schedule; what follows fades in.
    func resetPlayer() {
        generation += 1
        graph.player.stop()
        scheduled.removeAll()
        aheadFrames = 0
        playerFrames = 0
        playerRunning = false
        fadeInNext = true
        graph.resetSound()
    }

    func startPlayer() {
        guard graph.start(), graph.play() else {
            outputFailed()
            return
        }
        playerRunning = true
        clock.run()
    }

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
        let end = Double(last.first + last.song) / rate
        guard playerRunning, let (sample, hostTime) = graph.renderedSample(),
              let entry = scheduled.first(where: { $0.track === heard && sample < $0.start + Int64($0.frames) })
        else {
            clock.pin(min(clock.position(), end), since: nil)
            return
        }
        let pace = Double(entry.song) / Double(entry.frames)
        let frame = Double(entry.first) + Double(max(sample - entry.start, 0)) * pace
        clock.pin(frame / rate, since: hostTime, limit: end, pace: pace)
    }

    func updateBuffering() {
        let waiting = !paused && (producing != nil || awaitingNext) && scheduled.isEmpty
        if waiting != buffering {
            buffering = waiting
            emit(.buffering(waiting))
        }
    }
}
