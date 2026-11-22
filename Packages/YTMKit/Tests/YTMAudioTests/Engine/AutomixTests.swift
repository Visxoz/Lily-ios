import Foundation
import Testing
@testable import YTMAudio

private let rate = 48_000.0
/// Rounded to nearest as Windows' is, where `Float.pi` rounds toward zero, so the signals match its sample for sample.
private let tau = Float(2 * Double.pi)

/// Interleaved stereo, as the Windows tests write their signals, measured in one go.
private func analysed(_ samples: [Float]) -> Automix.Analysis {
    let frames = samples.count / 2
    let left = (0..<frames).map { samples[2 * $0] }
    let right = (0..<frames).map { samples[2 * $0 + 1] }
    var meter = Automix.Meter(rate: rate, frames: frames)
    left.withUnsafeBufferPointer { left in
        right.withUnsafeBufferPointer { right in
            if let left = left.baseAddress, let right = right.baseAddress {
                meter.add((left, right), count: frames)
            }
        }
    }
    return meter.analysis(frames: meter.frames)
}

private func seconds(_ frames: Double) -> Double {
    frames / rate
}

/// Rust's `rem_euclid`: never negative, as a phase before the first beat still lands within a period.
private func euclid(_ x: Double, _ period: Double) -> Double {
    let remainder = x.truncatingRemainder(dividingBy: period)
    return remainder < 0 ? remainder + period : remainder
}

/// Stereo clicks at `bpm` from `offset` seconds.
private func clicks(_ bpm: Double, from offset: Double, for length: Double) -> [Float] {
    let frames = Int(length * rate)
    let period = 60 / bpm * rate
    var samples = [Float](repeating: 0, count: frames * 2)
    var at = offset * rate
    while Int(at) < frames {
        let start = Int(at)
        for frame in start..<min(start + 240, frames) {
            samples[frame * 2] = 0.8
            samples[frame * 2 + 1] = 0.8
        }
        at += period
    }
    return samples
}

/// Steady stereo noise at `gain(t)`, `t` in seconds, each channel drawn on its own.
private func noise(_ length: Double, _ gain: (Double) -> Float) -> [Float] {
    var seed: UInt32 = 1
    return (0..<Int(length * rate) * 2).map { i in
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let x = Float(seed >> 8) / Float(1 << 24) - 0.5
        return x * gain(Double(i / 2) / rate)
    }
}

/// `samples` scaled by `gain(t)`, `t` in seconds.
private func shaped(_ samples: [Float], _ gain: (Double) -> Float) -> [Float] {
    samples.enumerated().map { i, sample in sample * gain(Double(i / 2) / rate) }
}

/// `samples` silenced outside `range`, in seconds.
private func gated(_ samples: [Float], _ range: Range<Double>) -> [Float] {
    shaped(samples) { range.contains($0) ? 1 : 0 }
}

private func mixed(_ parts: [[Float]]) -> [Float] {
    parts[0].indices.map { i in parts.reduce(Float(0)) { $0 + $1[i] } }
}

/// A sine at `hz` and `gain`, in stereo.
private func bass(_ hz: Float, _ length: Double, _ gain: Float) -> [Float] {
    (0..<Int(length * rate) * 2).map { i in
        let phase: Float = tau * hz * Float(i / 2) / Float(rate)
        return gain * sin(phase)
    }
}

/// A sawtooth at `hz` and `gain`, in stereo.
private func saw(_ hz: Float, _ length: Double, _ gain: Float) -> [Float] {
    (0..<Int(length * rate) * 2).map { i in
        let cycles: Float = hz * Float(i / 2) / Float(rate)
        return gain * (2 * (cycles - cycles.rounded(.towardZero)) - 1)
    }
}

/// A kick at `bpm` from 0.13 s: a falling 60 Hz thump over 150 ms.
private func kicks(_ bpm: Double, _ length: Double, _ gain: Float) -> [Float] {
    let period = 60 / bpm
    return (0..<Int(length * rate) * 2).map { i in
        let t = Double(i / 2) / rate - 0.13
        guard t >= 0 else { return 0 }
        let since = Float(euclid(t, period))
        let decay: Float = exp(-since / 0.05)
        let phase: Float = tau * 60 * since
        return gain * decay * sin(phase)
    }
}

/// The blend, in seconds, from `tail` into a steady loud intro.
private func blendSeconds(_ tail: [Float]) -> Double {
    let intro = analysed(noise(12) { _ in 1 })
    return seconds(Double(Automix.plan(tail: analysed(tail), intro: intro, rate: rate, room: .max).frames))
}

/// How far `at` lies from the nearest beat at `bpm` from `offset`, in seconds.
private func offBeat(_ at: Double, _ offset: Double, _ bpm: Double) -> Double {
    let period = 60 / bpm
    let phase = euclid(at - offset, period)
    return min(phase, period - phase)
}

/// 40 dB down over the last 10 s of 20.
private func fadeOut(_ t: Double) -> Float {
    let exponent = -2 * Float(max(t - 10, 0) / 10)
    return pow(10, exponent)
}

/// Bars of 2.5 s, every other 12 dB down.
private func bars(_ t: Double) -> Float {
    Int(t / 2.5).isMultiple(of: 2) ? 1 : 0.25
}

struct AutomixTests {
    @Test func findsTheTempoAndPhaseOfClicks() throws {
        for bpm in [92.0, 120, 128, 174] {
            let beats = try #require(analysed(clicks(bpm, from: 0.13, for: 20)).beats)
            let found = 60 / seconds(beats.period)
            // Clicks at 174 are as much 87 in half time.
            let heard = found < bpm * 0.75 ? bpm / 2 : bpm
            #expect(abs(found - heard) / heard < 0.002, "\(bpm): found \(found)")
            // On a click, which in half time may be either of a pair.
            #expect(offBeat(seconds(beats.first), 0.13, bpm) < 0.003, "\(bpm): \(beats)")
        }
    }

    @Test func hearsNoBeatInNoiseOrSilence() {
        #expect(analysed(noise(20) { _ in 1 }).beats?.period == nil, "noise")
        #expect(analysed([Float](repeating: 0, count: 48_000 * 20)).beats?.period == nil, "silence")
        #expect(analysed(clicks(120, from: 0, for: 1)).beats?.period == nil, "too short")
    }

    @Test func hearsNoBeatInAHeldBassNote() {
        for hz: Float in [35, 55, 110] {
            #expect(analysed(bass(hz, 20, 0.5)).beats?.period == nil, "\(hz) Hz")
        }
        // A sawtooth's energy, and a fifth's over its root, ripple once a waveform, regular as a beat.
        for hz: Float in [30, 41.2, 55] {
            let fifth = mixed([saw(hz, 20, 0.4), saw(hz * 1.5, 20, 0.3)])
            for samples in [saw(hz, 20, 0.5), fifth] {
                #expect(analysed(samples).beats?.period == nil, "\(hz) Hz")
            }
        }
    }

    @Test func hearsClicksOverAHeldBassNote() throws {
        let samples = mixed([clicks(124, from: 0.13, for: 20), bass(55, 20, 0.3)])
        let beats = try #require(analysed(samples).beats)
        let found = 60 / seconds(beats.period)
        #expect(abs(found - 124) < 0.25, "found \(found)")
        #expect(offBeat(seconds(beats.first), 0.13, 124) < 0.006, "\(beats)")
    }

    @Test func blendsOverAFadeOut() {
        // Found to the second.
        let length = blendSeconds(noise(20, fadeOut))
        #expect((9.0...10.0).contains(length), "\(length) s")
    }

    @Test func blendsOverAQuietIntro() {
        let tail = analysed(noise(20) { _ in 1 })
        // Up to loud only in the intro's last half second, too.
        for quiet in [7.0, 11.5] {
            let intro = analysed(noise(12) { $0 < quiet ? 0.1 : 1 })
            let mix = Automix.plan(tail: tail, intro: intro, rate: rate, room: .max)
            #expect(abs(seconds(Double(mix.frames)) - quiet) < 0.4, "\(mix)")
        }
    }

    @Test func blendsHardEndsBrieflyAndNeverPastTheTail() {
        #expect(blendSeconds(noise(20) { _ in 1 }) == Automix.minSeconds)
        let loud = analysed(noise(20) { _ in 1 })
        let short = analysed(noise(2) { _ in 1 })
        #expect(Automix.plan(tail: short, intro: loud, rate: rate, room: .max).frames == 96_000)
    }

    @Test func landsTheIncomingBeatOnTheOutgoing() throws {
        // A hard end plans the shortest blend and a 16 s fade the longest, so alignment must stay within both
        // bounds whatever the phases.
        let hard = clicks(124, from: 0.21, for: 20)
        let faded = shaped(hard) { t in
            let exponent = -2 * Float(max(t - 4, 0) / 16)
            return pow(10, exponent)
        }
        let tails = [hard, faded].map(analysed)
        for step in 0..<40 {
            let offset = 0.01 + 0.012 * Double(step)
            let intro = analysed(clicks(124, from: offset, for: 12))
            let next = try #require(intro.beats)
            for (which, tail) in tails.enumerated() {
                let mix = Automix.plan(tail: tail, intro: intro, rate: rate, room: .max)
                // Against where the clicks really are, not where they were heard.
                let start = seconds(Double(tail.frames) - Double(mix.frames))
                let off = offBeat(start + offset, 0.21, 124)
                #expect(off < 0.003, "\(which)/\(step): \(off) s off the beat")
                let length = seconds(Double(mix.frames))
                #expect((Automix.minSeconds...Automix.maxSeconds).contains(length), "\(which)/\(step): \(length) s")
                // Traded over half a beat, ending on an incoming beat.
                #expect(mix.tradeLength == Int(next.period / 2), "\(which)/\(step): \(mix)")
                let end = Double(mix.tradeAt + mix.tradeLength) - next.first
                let beats = end / next.period
                #expect(abs(beats - beats.rounded()) < 0.01, "\(which)/\(step): the trade ends \(end) frames from the first beat")
            }
        }
    }

    @Test func hearsAKickOverABassLine() throws {
        // A sine bass at some tempos cancels every other kick's thump, leaving a pulse at half the tempo, under the
        // range sought, so it is tried at 124 alone.
        let line = saw(41.2, 20, 0.25)
        var basses: [(Double, [Float])] = [90.0, 120, 126, 135, 174].map { ($0, line) }
        basses.append((124, bass(41, 20, 0.3)))
        let hiss = noise(20) { _ in 0.2 }
        for (bpm, low) in basses {
            let beats = try #require(analysed(mixed([kicks(bpm, 20, 0.6), low, hiss])).beats)
            let found = Automix.fold(60 / seconds(beats.period), to: bpm)
            #expect(abs(found - bpm) / bpm < 0.002, "\(bpm): \(beats)")
        }
    }

    @Test func leavesATempoThatWanders() {
        let step = clicks(120, from: 0.13, for: 10) + clicks(123, from: 0, for: 10)
        #expect(analysed(step).beats?.period == nil, "a step")
        // Or speeds up throughout, landing the grid's end off the beat.
        let frames = 20 * Int(rate)
        var ramp = [Float](repeating: 0, count: frames * 2)
        var t = 0.13
        while t < 20 {
            let at = Int(t * rate)
            for sample in (at * 2)..<(min(at + 240, frames) * 2) {
                ramp[sample] = 0.8
            }
            t += 60 / (120 + 2 * t / 20)
        }
        #expect(analysed(ramp).beats?.period == nil, "a ramp")
    }

    @Test func hearsABeatThatComesInLateOrStops() throws {
        // Kicks in for the intro's last 5 s, and out for the tail's last 10.
        let cases: [(Double, Range<Double>)] = [(12, 7..<12), (20, 0..<10)]
        for (length, kicking) in cases {
            let samples = mixed([gated(kicks(124, length, 0.6), kicking), saw(41.2, length, 0.25), noise(length) { _ in 0.2 }])
            let beats = try #require(analysed(samples).beats)
            #expect(abs(60 / seconds(beats.period) - 124) < 0.25, "\(beats)")
            // On the kicks, where they play.
            let middle = (kicking.lowerBound + kicking.upperBound) / 2
            let k = ((middle - seconds(beats.first)) / seconds(beats.period)).rounded()
            let at = seconds(beats.first + k * beats.period)
            #expect(offBeat(at, 0.13, 124) < 0.012, "\(beats)")
        }
    }

    @Test func blendsOverASlowFadeOfMusic() {
        // 40 dB over 30 s, which the music's own swell slows to under 1 dB in some seconds.
        let music = mixed([kicks(124, 24, 0.6), saw(41.2, 24, 0.25), noise(24) { _ in 0.2 }])
        // Worked in Float throughout, as Windows does.
        let faded = music.enumerated().map { i, sample -> Float in
            let exponent: Float = -2 * Float(i / 2) / Float(rate) / 30
            return sample * pow(10, exponent)
        }
        #expect(blendSeconds(faded) == Automix.maxSeconds)
    }

    @Test func blendsOverAFadeIntoHiss() {
        // 60 dB over 10 s, then tape hiss 44 dB down.
        let length = blendSeconds(
            noise(22) { t in
                let exponent = -3 * Float(max(t - 10, 0) / 10)
                return pow(10, exponent) + 0.006
            }
        )
        #expect((11.0...12.0).contains(length), "\(length) s")
    }

    @Test func hearsTheBeatPastAQuietStretch() throws {
        // The whole mix 40 dB down for a second, as at a stop before a chorus.
        let samples = shaped(mixed([kicks(124, 20, 0.6), bass(41, 20, 0.15)])) { (8.0..<9.0).contains($0) ? 0.01 : 1 }
        let beats = try #require(analysed(samples).beats)
        #expect(abs(60 / seconds(beats.period) - 124) < 0.25, "\(beats)")
        #expect(offBeat(seconds(beats.first), 0.13, 124) < 0.012, "\(beats)")
    }

    @Test func leavesASofterSectionHeldToTheEndAlone() {
        // Applause 12 dB under the music, to the end.
        #expect(blendSeconds(noise(24) { $0 < 10 ? 1 : 0.25 }) == Automix.minSeconds)
    }

    @Test func hearsNoBeatInAFewHits() {
        // Two tom hits over a pad, their gap as regular as any tempo.
        var samples = mixed([bass(220, 12, 0.2), noise(12) { _ in 0.002 }])
        for at in [5.0, 5.6] {
            let from = Int(at * rate) * 2
            for i in 0..<24_000 {
                let since = Float(i / 2)
                let decay: Float = exp(-since / 4_800)
                let phase: Float = tau * 110 * since / Float(rate)
                samples[from + i] += 0.8 * decay * sin(phase)
            }
        }
        #expect(analysed(samples).beats?.period == nil)
    }

    @Test func keepsTheBeatThroughABreakdownOffIt() throws {
        // 4 s of offbeat clicks alone in place of the beat.
        let on = clicks(124, from: 0.13, for: 20)
        let off = clicks(124, from: 0.13 + 30 / 124, for: 20)
        let samples = mixed([gated(on, 0..<8), gated(off, 8..<12), gated(on, 12..<20)])
        let beats = try #require(analysed(samples).beats)
        #expect(offBeat(seconds(beats.first), 0.13, 124) < 0.003, "\(beats)")
    }

    @Test func blendsOnlyOverTheFadeOfMusicThatSwells() {
        // Faded 40 dB over the last 3 s.
        let length = blendSeconds(
            noise(20) { t in
                let exponent = -2 * Float(max(t - 17, 0) / 3)
                return bars(t) * pow(10, exponent)
            }
        )
        #expect(length <= 6, "\(length) s")
    }

    @Test func leavesMusicThatSwellsAndStopsAlone() {
        // No 5 s hold.
        #expect(blendSeconds(noise(20, bars)) == Automix.minSeconds)
    }

    @Test func blendsOverAFadeOutOfAQuieterSection() {
        let length = blendSeconds(
            noise(24) { t in
                if t < 4 { return 1 }
                if t < 14 { return 0.4 }
                let exponent = -0.25 * Float(t - 14)
                return 0.4 * pow(10, exponent)
            }
        )
        #expect((9.0...10.0).contains(length), "\(length) s")
    }

    @Test func leavesASoftEndingThatStopsAlone() {
        // A last verse 8 dB down whose final chord rings out, 80 dB over `ring`.
        for ring in [0.0, 1.0, 3.0] {
            let length = blendSeconds(
                noise(18 + ring) { t in
                    if t < 6 { return 1 }
                    if t < 18 { return 0.4 }
                    let exponent = Float(-4 * (t - 18) / ring)
                    return 0.4 * pow(10, exponent)
                }
            )
            #expect(length == Automix.minSeconds, "rung out over \(ring) s")
        }
    }

    @Test func blendsOverAFadeLinearInAmplitude() {
        // Over 10 s, its first 4 s losing only 3 dB, which holds as the music.
        let length = blendSeconds(noise(20) { 1 - max(Float($0) - 10, 0) / 10 })
        #expect((6.0...7.0).contains(length), "\(length) s")
    }

    @Test func blendsOverAtMostHalfAShortItem() {
        let tail = analysed(noise(20, fadeOut))
        let mix = Automix.plan(tail: tail, intro: analysed(noise(5) { _ in 1 }), rate: rate, room: .max)
        #expect(seconds(Double(mix.frames)) == 2.5)
    }

    @Test func leavesBeatsThatWouldDriftApart() {
        let tail = analysed(clicks(120, from: 0.21, for: 20))
        let intro = analysed(clicks(128, from: 0.37, for: 12))
        #expect(Automix.plan(tail: tail, intro: intro, rate: rate, room: .max).frames == Int(Automix.minSeconds * rate))
    }

    @Test func foldsDoubleTimeOntoTheBeat() {
        #expect(Automix.fold(250, to: 500) == 500)
        #expect(Automix.fold(1_000, to: 500) == 500)
        #expect(Automix.fold(600, to: 500) == 600)
    }

    @Test func tradesTheBassRatherThanSummingIt() {
        let sine = { (phase: Float) in
            (0..<48_000).map { i -> Float in
                let angle: Float = tau * 50 * Float(i) / 48_000 + phase
                return sin(angle)
            }
        }
        let length = 48_000
        let trade = Automix.Trade(Automix.Mix(frames: length, tradeAt: length / 2, tradeLength: 4_800), rate: rate)
        var peak: Float = 0
        for (i, (new, old)) in zip(sine(0.3), sine(0)).enumerated() {
            let angle: Float = Float(i) / Float(length) * (tau / 4)
            let incoming = trade.incoming((new, new), at: Int64(i)).0 * sin(angle)
            let outgoing = trade.outgoing((old, old), at: Int64(i)).0 * cos(angle)
            peak = max(peak, abs(incoming + outgoing))
        }
        // Equal-power curves alone would sum the two near 1.4.
        #expect(peak < 1.05, "peaked at \(peak)")
    }

    @Test func endsOnTheIncomingWhole() {
        let trade = Automix.Trade(Automix.Mix(frames: 100, tradeAt: 0, tradeLength: 1), rate: rate)
        let incoming = trade.incoming((0.5, -0.25), at: 10)
        let outgoing = trade.outgoing((0.9, 0.9), at: 10)
        let left = incoming.0 * 1 + outgoing.0 * 0
        let right = incoming.1 * 1 + outgoing.1 * 0
        #expect(abs(left - 0.5) < 1e-6 && abs(right + 0.25) < 1e-6)
    }
}
