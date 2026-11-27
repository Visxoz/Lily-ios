import Foundation
import Testing
@testable import YTMAudio

private let rate = 48_000.0
/// Rounded to nearest as Windows' is, where `Float.pi` rounds toward zero, so the signals match its sample for sample.
private let tau = Float(2 * Double.pi)

/// Interleaved stereo `length` seconds long, as the Windows tests write their signals, each sample `at(frame)`.
private func stereo(_ length: Double, _ at: (Int) -> Float) -> [Float] {
    (0..<Int(length * rate) * 2).map { at($0 / 2) }
}

/// Interleaved stereo a channel each.
private func split(_ samples: [Float]) -> (left: [Float], right: [Float]) {
    let frames = samples.count / 2
    return ((0..<frames).map { samples[2 * $0] }, (0..<frames).map { samples[2 * $0 + 1] })
}

/// Interleaved stereo measured `piece` frames at a time, as the engine feeds it, and analysed up to `frames`.
private func analysed(_ samples: [Float], piece: Int = .max, frames: Int? = nil) -> Automix.Analysis {
    let (left, right) = split(samples)
    var meter = Automix.Meter(rate: rate, frames: left.count)
    for at in stride(from: 0, to: left.count, by: piece) {
        let range = at..<(at + min(piece, left.count - at))
        let held = StereoBuffer(Array(left[range]), Array(right[range]))
        withExtendedLifetime(held) { meter.add(held.channels, count: held.count) }
    }
    return meter.analysis(frames: frames ?? meter.frames)
}

private func seconds(_ frames: Double) -> Double {
    frames / rate
}

private func tempo(_ beats: Automix.Beats) -> Double {
    60 / seconds(beats.period)
}

private func plan(_ tail: Automix.Analysis, _ intro: Automix.Analysis, voices: Automix.Voices = Automix.Voices()) -> Automix.Mix {
    Automix.plan(tail: tail, intro: intro, rate: rate, room: .max, voices: voices)
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
    let draw = Fixtures.white(1)
    return stereo(length) { draw() * gain(Double($0) / rate) }
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
    stereo(length) { frame in
        let phase: Float = tau * hz * Float(frame) / Float(rate)
        return gain * sin(phase)
    }
}

/// A sawtooth at `hz` and `gain`, in stereo.
private func saw(_ hz: Float, _ length: Double, _ gain: Float) -> [Float] {
    stereo(length) { frame in
        let cycles: Float = hz * Float(frame) / Float(rate)
        return gain * (2 * (cycles - cycles.rounded(.towardZero)) - 1)
    }
}

/// A kick at `bpm` from 0.13 s, the `k`th at `gain(k)`: a falling 60 Hz thump over 150 ms.
private func kicks(_ bpm: Double, _ length: Double, _ gain: (Int) -> Float) -> [Float] {
    let period = 60 / bpm
    return stereo(length) { frame in
        let t = Double(frame) / rate - 0.13
        guard t >= 0 else { return 0 }
        let since = Float(euclid(t, period))
        let decay: Float = exp(-since / 0.05)
        let phase: Float = tau * 60 * since
        return gain(Int(t / period)) * decay * sin(phase)
    }
}

/// Hats or snares: noise bursts fading over 30 ms, `perBeat` to a beat at `bpm` from 0.13 s, the `k`th at `gain(k)`.
private func taps(_ bpm: Double, _ perBeat: Double, _ length: Double, _ gain: (Int) -> Float) -> [Float] {
    let step = 60 / bpm / perBeat
    let draw = Fixtures.white(7)
    return stereo(length) { frame in
        let x = draw()
        let t = Double(frame) / rate - 0.13
        guard t >= 0 else { return 0 }
        let decay: Float = exp(-Float(euclid(t, step)) / 0.03)
        return gain(Int(t / step)) * decay * x
    }
}

/// Kicks as `kicks` plays them over a little noise, each bar's `phase`th beat of four accented.
private func accented(_ bpm: Double, _ length: Double, _ phase: Int) -> [Float] {
    mixed([kicks(bpm, length) { $0 % 4 == phase ? 0.6 : 0.25 }, noise(length) { _ in 0.05 }])
}

/// The blend, in seconds, from `tail` into a steady loud intro.
private func blendSeconds(_ tail: [Float]) -> Double {
    let intro = analysed(noise(12) { _ in 1 })
    return seconds(Double(plan(analysed(tail), intro).frames))
}

/// How far `at` lies from the nearest of `every` from `from`, in seconds.
private func offGrid(_ at: Double, _ from: Double, _ every: Double) -> Double {
    let phase = euclid(at - from, every)
    return min(phase, every - phase)
}

/// Whether `beats` holds `bpm`, folded by octaves, with a beat on one from 0.13 s.
private func onTheBeat(_ beats: Automix.Beats?, _ bpm: Double) -> Bool {
    beats.map { abs(Automix.fold(tempo($0), to: bpm) - bpm) / bpm < 0.003 && offGrid(seconds($0.first), 0.13, 60 / bpm) < 0.012 } ?? false
}

/// 40 dB down over the last 10 s of 20.
private func fadeOut(_ t: Double) -> Float {
    let exponent = -2 * Float(max(t - 10, 0) / 10)
    return pow(10, exponent)
}

/// 40 dB down over the last 16 s of 20, so the blend runs long.
private func longFade(_ t: Double) -> Float {
    let exponent = -2 * Float(max(t - 4, 0) / 16)
    return pow(10, exponent)
}

private func fadedClicks(_ bpm: Double) -> [Float] {
    shaped(clicks(bpm, from: 0.21, for: 20), longFade)
}

/// Bars of 2.5 s, every other 12 dB down.
private func bars(_ t: Double) -> Float {
    Int(t / 2.5).isMultiple(of: 2) ? 1 : 0.25
}

/// The outgoing item's last word `last` seconds before its end, and the incoming's first `first` seconds in.
private func voices(_ last: Double, _ first: Double) -> Automix.Voices {
    Automix.Voices(last: last * rate, first: first * rate)
}

private let styles: [Automix.Style] = [.crossfade, .blend(trade: (2_000, 500)), .sweep(skew: false), .sweep(skew: true), .echo(beat: 1_100)]

struct AutomixTests {
    @Test func findsTheTempoAndPhaseOfClicks() throws {
        for bpm in [92.0, 120, 128, 174] {
            let beats = try #require(analysed(clicks(bpm, from: 0.13, for: 20)).beats)
            let found = tempo(beats)
            // Clicks at 174 are as much 87 in half time.
            let heard = found < bpm * 0.75 ? bpm / 2 : bpm
            #expect(abs(found - heard) / heard < 0.002, "\(bpm): found \(found)")
            // On a click, which in half time may be either of a pair.
            #expect(offGrid(seconds(beats.first), 0.13, 60 / bpm) < 0.003, "\(bpm): \(beats)")
        }
    }

    @Test func hearsNoBeatInNoiseOrSilence() {
        #expect(analysed(noise(20) { _ in 1 }).beats == nil, "noise")
        let silence = analysed(stereo(20) { _ in 0 })
        #expect(silence.beats == nil, "silence")
        #expect(!silence.bass, "silence carries no bass")
        // Six beats, so only the length check rejects it.
        #expect(analysed(clicks(120, from: 0, for: 3)).beats == nil, "too short")
    }

    @Test func hearsNoBeatInAHeldBassNote() {
        for hz: Float in [35, 55, 110] {
            #expect(analysed(bass(hz, 20, 0.5)).beats == nil, "\(hz) Hz")
        }
        // A sawtooth's energy, and a fifth's over its root, ripple once a waveform, regular as a beat.
        for hz: Float in [30, 41.2, 55] {
            let fifth = mixed([saw(hz, 20, 0.4), saw(hz * 1.5, 20, 0.3)])
            for samples in [saw(hz, 20, 0.5), fifth] {
                #expect(analysed(samples).beats == nil, "\(hz) Hz")
            }
        }
    }

    @Test func hearsClicksOverAHeldBassNote() throws {
        let samples = mixed([clicks(124, from: 0.13, for: 20), bass(55, 20, 0.3)])
        let beats = try #require(analysed(samples).beats)
        let found = tempo(beats)
        #expect(abs(found - 124) < 0.25, "found \(found)")
        #expect(offGrid(seconds(beats.first), 0.13, 60 / 124.0) < 0.006, "\(beats)")
    }

    @Test func measuresInPiecesAndShortOfAllMeasuredAsInOne() throws {
        let samples = mixed([clicks(124, from: 0.13, for: 20), bass(55, 20, 0.3)])
        let whole = analysed(samples)
        let beats = try #require(whole.beats)
        // Hops split across pieces, and 2 s past the end measured but left out, as a track's tail is.
        let more = samples + noise(2) { _ in 0.5 }
        for other in [analysed(samples, piece: 1_001), analysed(more, piece: 1_001, frames: whole.frames)] {
            #expect(other.frames == whole.frames && other.bass == whole.bass)
            #expect(other.beats.map { [$0.period, $0.first, $0.downbeat ?? -1] } == [beats.period, beats.first, beats.downbeat ?? -1])
        }
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
            let mix = plan(tail, intro)
            #expect(abs(seconds(Double(mix.frames)) - quiet) < 0.4, "\(mix)")
        }
    }

    @Test func blendsHardEndsBrieflyAndNeverPastTheTail() {
        #expect(blendSeconds(noise(20) { _ in 1 }) == Automix.minSeconds)
        let loud = analysed(noise(20) { _ in 1 })
        let short = analysed(noise(2) { _ in 1 })
        #expect(plan(short, loud).frames == 96_000)
    }

    @Test func landsTheIncomingBeatOnTheOutgoing() throws {
        // A hard end plans the shortest blend and a 16 s fade the longest, so alignment must stay within both
        // bounds whatever the phases.
        let tails = [clicks(124, from: 0.21, for: 20), fadedClicks(124)].map { analysed($0) }
        for step in 0..<40 {
            let offset = 0.01 + 0.012 * Double(step)
            let intro = analysed(clicks(124, from: offset, for: 12))
            let next = try #require(intro.beats)
            for (which, tail) in tails.enumerated() {
                let mix = plan(tail, intro)
                // Against where the clicks really are, not where they were heard.
                let start = seconds(Double(tail.frames) - Double(mix.frames))
                let off = offGrid(start + offset, 0.21, 60 / 124.0)
                #expect(off < 0.003, "\(which)/\(step): \(off) s off the beat")
                let length = seconds(Double(mix.frames))
                #expect((Automix.minSeconds...Automix.maxSeconds).contains(length), "\(which)/\(step): \(length) s")
                // Traded over half a beat, ending on an incoming beat.
                guard case .blend(let trade?) = mix.style else {
                    Issue.record("\(which)/\(step): \(mix)")
                    continue
                }
                #expect(trade.length == Int(next.period / 2), "\(which)/\(step): \(mix)")
                let end = Double(trade.at + trade.length) - next.first
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
            let beats = try #require(analysed(mixed([kicks(bpm, 20) { _ in 0.6 }, low, hiss])).beats)
            let found = Automix.fold(tempo(beats), to: bpm)
            #expect(abs(found - bpm) / bpm < 0.002, "\(bpm): \(beats)")
        }
    }

    @Test func leavesATempoThatWanders() {
        let step = clicks(120, from: 0.13, for: 10) + clicks(123, from: 0, for: 10)
        #expect(analysed(step).beats == nil, "a step")
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
        #expect(analysed(ramp).beats == nil, "a ramp")
    }

    @Test func hearsABeatThatComesInLateOrStops() throws {
        // Kicks in for the intro's last 5 s, and out for the tail's last 10.
        let cases: [(Double, Range<Double>)] = [(12, 7..<12), (20, 0..<10)]
        for (length, kicking) in cases {
            let samples = mixed([gated(kicks(124, length) { _ in 0.6 }, kicking), saw(41.2, length, 0.25), noise(length) { _ in 0.2 }])
            let beats = try #require(analysed(samples).beats)
            #expect(abs(tempo(beats) - 124) < 0.25, "\(beats)")
            // On the kicks, where they play.
            let middle = (kicking.lowerBound + kicking.upperBound) / 2
            let k = ((middle - seconds(beats.first)) / seconds(beats.period)).rounded()
            let at = seconds(beats.first + k * beats.period)
            #expect(offGrid(at, 0.13, 60 / 124.0) < 0.012, "\(beats)")
        }
    }

    @Test func blendsOverASlowFadeOfMusic() {
        // 40 dB over 30 s, which the music's own swell slows to under 1 dB in some seconds.
        let music = mixed([kicks(124, 24) { _ in 0.6 }, saw(41.2, 24, 0.25), noise(24) { _ in 0.2 }])
        let faded = shaped(music) { pow(10, Float(-2 * $0 / 30)) }
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
        let samples = shaped(mixed([kicks(124, 20) { _ in 0.6 }, bass(41, 20, 0.15)])) { (8.0..<9.0).contains($0) ? 0.01 : 1 }
        let beats = try #require(analysed(samples).beats)
        #expect(abs(tempo(beats) - 124) < 0.25, "\(beats)")
        #expect(offGrid(seconds(beats.first), 0.13, 60 / 124.0) < 0.012, "\(beats)")
    }

    @Test func hearsSnaresOverALoudBass() {
        // No kick, a loud bass, snares on two and four and faint hats on the eighths; only the highs show the snares.
        let samples = mixed([saw(41.2, 20, 0.5), taps(150, 2, 20) { $0 % 8 == 2 || $0 % 8 == 6 ? 0.6 : 0.15 }])
        let beats = analysed(samples).beats
        #expect(onTheBeat(beats, 150), "\(String(describing: beats))")
    }

    @Test func findsTheBeatUnderAThreeThreeTwoRhythm() {
        // Kicks on eighths 0, 3 and 6 of each bar repeat a beat and a half apart more than a beat, with faint hats on
        // every beat.
        let samples = mixed([
            kicks(330, 20) { [0, 3, 6].contains($0 % 8) ? 0.6 : 0 }, taps(165, 1, 20) { _ in 0.05 }, noise(20) { _ in 0.02 },
        ])
        let beats = analysed(samples).beats
        #expect(onTheBeat(beats, 165), "\(String(describing: beats))")
    }

    @Test func hearsASwungBeat() {
        // Kicks on the beat, hats on it and two thirds of the way to the next.
        let samples = mixed([kicks(100, 20) { _ in 0.6 }, taps(100, 3, 20) { $0 % 3 == 1 ? 0 : 0.2 }])
        let beats = analysed(samples).beats
        #expect(onTheBeat(beats, 100), "\(String(describing: beats))")
    }

    @Test func neverTakesTwoThirdsOfABeatUnderTripletHats() {
        // Kicks on one and three, snares on two and four, hats on every third, as a beat and a half's grid has them
        // too.
        for bpm in [100.0, 110, 120] {
            let samples = mixed([
                kicks(bpm, 20) { $0 % 2 == 0 ? 0.6 : 0 }, taps(bpm, 1, 20) { $0 % 2 == 1 ? 0.4 : 0 }, taps(bpm, 3, 20) { _ in 0.3 },
            ])
            let beats = analysed(samples).beats
            #expect(beats == nil || onTheBeat(beats, bpm), "\(bpm): \(String(describing: beats))")
        }
    }

    @Test func hearsAHouseBeatUnderLoudOpenHats() {
        // Kicks on the beat, out for 4 s, and open hats off it, carrying nearly as much onset, but none of the bass.
        for bpm in [120.0, 124, 128] {
            let kick = kicks(bpm, 20) { _ in 0.6 }
            let samples = mixed([gated(kick, 0..<8), gated(kick, 12..<20), taps(bpm, 2, 20) { $0 % 2 == 1 ? 0.3 : 0 }])
            let beats = analysed(samples).beats
            #expect(onTheBeat(beats, bpm), "\(bpm): \(String(describing: beats))")
        }
    }

    @Test func leavesABeatWhoseOffBeatsMatchIt() {
        // Either could be the beat.
        #expect(analysed(clicks(220, from: 0.13, for: 20)).beats == nil)
    }

    @Test func leavesABeatThatMovesAtAnEnd() {
        // Onto the off-beats for the last 4 s, as where one item is cut into another; in the middle, it is a
        // breakdown.
        let on = clicks(124, from: 0.13, for: 20)
        let off = clicks(124, from: 0.13 + 30 / 124, for: 20)
        for (start, end) in [(0.0, 4.0), (16.0, 20.0)] {
            let samples = mixed([gated(on, 0..<start), gated(off, start..<end), gated(on, end..<20)])
            #expect(analysed(samples).beats == nil, "\(start) s")
        }
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
        #expect(analysed(samples).beats == nil)
    }

    @Test func keepsTheBeatThroughABreakdownOffIt() throws {
        // 4 s of offbeat clicks alone in place of the beat.
        let on = clicks(124, from: 0.13, for: 20)
        let off = clicks(124, from: 0.13 + 30 / 124, for: 20)
        let samples = mixed([gated(on, 0..<8), gated(off, 8..<12), gated(on, 12..<20)])
        let beats = try #require(analysed(samples).beats)
        #expect(offGrid(seconds(beats.first), 0.13, 60 / 124.0) < 0.003, "\(beats)")
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
        let mix = plan(analysed(noise(20, fadeOut)), analysed(noise(5) { _ in 1 }))
        #expect(seconds(Double(mix.frames)) == 2.5)
    }

    @Test func leavesBeatsThatWouldDriftApart() {
        // 6.7% apart, past what varispeed takes: an item that stops is echoed out over its last four beats, one that
        // fades swept across.
        let intro = analysed(clicks(128, from: 0.37, for: 12))
        let hard = clicks(120, from: 0.21, for: 20)
        let mix = plan(analysed(hard), intro)
        guard case .echo(let beat) = mix.style else {
            Issue.record("\(mix)")
            return
        }
        #expect(abs(beat - 24_000) < 50, "\(mix)")
        #expect(mix.warp == nil)
        #expect((3.0...4.0).contains(Double(mix.frames) / Double(beat)))
        let faded = plan(analysed(shaped(hard, fadeOut)), intro)
        let swept = if case .sweep(skew: false) = faded.style { true } else { false }
        #expect(swept, "\(faded)")
        #expect(faded.warp == nil)
    }

    @Test func foldsDoubleTimeOntoTheBeat() {
        #expect(Automix.fold(250, to: 500) == 500)
        #expect(Automix.fold(1_000, to: 500) == 500)
        #expect(Automix.fold(600, to: 500) == 600)
    }

    @Test func findsTheDownbeatOfAnAccentedBar() throws {
        let beat = 60 / 124.0
        for phase in 0..<4 {
            let beats = try #require(analysed(accented(124, 20, phase)).beats)
            let downbeat = try #require(beats.downbeat, "bars")
            #expect(offGrid(seconds(downbeat), 0.13 + Double(phase) * beat, 4 * beat) < 0.012, "\(phase): \(beats)")
        }
        // Even beats have no bars.
        let even = mixed([kicks(124, 20) { _ in 0.6 }, noise(20) { _ in 0.05 }])
        for samples in [even, clicks(124, from: 0.13, for: 20)] {
            let beats = try #require(analysed(samples).beats)
            #expect(beats.downbeat == nil, "\(beats)")
        }
    }

    @Test func landsTheFirstDownbeatOnADownbeat() throws {
        let (beat, bar) = (60 / 124.0, 4 * 60 / 124.0)
        let hard = accented(124, 20, 1)
        for (which, tail) in [hard, shaped(hard, longFade)].map({ analysed($0) }).enumerated() {
            for phase in 0..<4 {
                let intro = analysed(accented(124, 12, phase))
                let next = try #require(intro.beats)
                let mix = plan(tail, intro)
                let start = seconds(Double(tail.frames) - Double(mix.frames))
                // Against where the downbeats really are.
                let off = offGrid(start + 0.13 + Double(phase) * beat, 0.13 + beat, bar)
                #expect(off < 0.012, "\(which)/\(phase): \(off) s off, \(mix)")
                // Traded on an incoming bar line.
                guard case .blend(let trade?) = mix.style, let downbeat = next.downbeat else {
                    Issue.record("\(which)/\(phase): \(mix)")
                    continue
                }
                let end = seconds(Double(trade.at + trade.length) - downbeat)
                #expect(offGrid(end, 0, bar) < 0.001, "\(which)/\(phase): \(mix)")
            }
        }
    }

    @Test func prefersAPhraseOfFourOrEightBars() {
        let bar = 2 * rate
        // Blends a beat apart through 0, and a bar apart through 0.3 of one reaching the first downbeat at `first`.
        func sync(first: Double?) -> Automix.Sync {
            let beats = { (downbeat: Double?) in Automix.Beats(period: bar / 4, first: 0, downbeat: downbeat) }
            return Automix.Sync(out: beats(first.map { $0 - 0.3 * bar }), next: beats(first), end: 0, speed: 1, ramp: 0, longest: 12 * rate)
        }
        // The length picked, and 1 should it be on the bar.
        func pick(_ sync: Automix.Sync, _ want: Double) -> [Double]? {
            sync.pick(shortest: 3 * rate, sung: .infinity, want: want * bar).map { [$0.length, $0.onBar ? 1 : 0] }
        }
        let onBar = { (k: Double) in [0.3 * bar + k * bar, 1] }
        #expect(pick(sync(first: 0), 3) == onBar(3), "the nearest")
        #expect(pick(sync(first: 0), 3.6) == onBar(4), "4 bars over 3")
        #expect(pick(sync(first: 0), 5.2) == onBar(5), "but not by over half a bar")
        #expect(pick(sync(first: 0), 4.5) == onBar(4))
        #expect(pick(sync(first: 3.5 * bar), 3) == onBar(4), "reaching the first downbeat")
        #expect(pick(sync(first: nil), 3.6) == [3.5 * bar, 0], "on the beat")
    }

    @Test func meetsANearTempoByVarispeed() throws {
        for bpm in [117.0, 124] {
            let tail = fadedClicks(120)
            let intro = analysed(clicks(bpm, from: 0.05, for: 12))
            let next = try #require(intro.beats)
            let mix = plan(analysed(tail), intro)
            let (start, curve) = try #require(mix.warp, "varispeed")
            #expect(abs(curve.speed - bpm / 120) < 0.002, "\(mix)")
            #expect(curve.ramp >= Automix.rampSeconds * rate * 0.95, "\(mix)")
            let ramp = Int(curve.ramp)
            // From `reach` before `start`, which pass as they are, as the engine reads it.
            let skip = Varispeed.reach + ramp
            let warped = curve.read(split(tail), from: start - Varispeed.reach, frames: skip + mix.frames)
            // The blend at the incoming's tempo, its beats on the incoming's.
            let blend = try #require(analysed(zip(warped.left[skip...], warped.right[skip...]).flatMap { [$0, $1] }).beats)
            #expect(abs(blend.period / next.period - 1) < 0.002, "\(bpm): \(blend) for \(next)")
            let off = offGrid(seconds(blend.first), seconds(next.first), seconds(next.period))
            #expect(off < 0.004, "\(bpm): \(off) s off the beat")
            // Ending as the tail does.
            let last = Double(start) + curve.songFrames(Double(ramp + mix.frames))
            #expect(abs(last - Double(tail.count / 2)) < 2, "\(last)")
        }
    }

    @Test func keepsTheVarispeedAndBlendWithinTheRoomLeft() {
        let tail = analysed(fadedClicks(120))
        let intro = analysed(clicks(124, from: 0.05, for: 12))
        // All shorter than the tail, so each bounds it; 6 s leaves too little after the ramp to blend.
        let warps = [6.0, 10, 14].count { seconds in
            let room = Int(seconds * rate)
            let mix = Automix.plan(tail: tail, intro: intro, rate: rate, room: room, voices: Automix.Voices())
            #expect(mix.frames <= room, "\(seconds) s: \(mix)")
            guard let (start, _) = mix.warp else { return false }
            #expect(start - Varispeed.reach >= tail.frames - room, "\(seconds) s: its taps reach back no further")
            return true
        }
        #expect(warps == 2, "sped up within 10 and 14 s")
    }

    @Test func meetsByVarispeedWhereSingingRulesOutEveryBeatAsIs() {
        // 1.25% apart, together as is for 4 s: some shorter blends the singing allows land on no beat as is, but on
        // one sped up.
        let tail = analysed(fadedClicks(120))
        let intro = analysed(clicks(121.5, from: 0.05, for: 12))
        #expect(plan(tail, intro).warp == nil, "as is where it can")
        let warped = (0..<50).count { plan(tail, intro, voices: voices(0, 1.5 + 0.01 * Double($0))).warp != nil }
        #expect(warped > 0, "never sped up")
    }

    @Test func readsWhereEachSongIsSung() {
        let sung = Sung(current: [10..<12, 170..<176], next: [0.2..<0.5, 2..<3])
        let read = Automix.Voices(sung, tailEnd: 180, introStart: 0.8, rate: rate)
        #expect(read.last == 4 * rate)
        #expect(read.first == 1.2 * rate, "past the cut silence")
        #expect(Automix.Voices(Sung(), tailEnd: 180, introStart: 0, rate: rate).longest(speed: 1, rate: rate) == nil)
        let unsung = Automix.Voices(Sung(current: [], next: [0.2..<0.5]), tailEnd: 180, introStart: 0.8, rate: rate)
        #expect(unsung.last == nil && unsung.first == nil, "no words left")
    }

    @Test func shortensABlendSoTheIncomingSingsAfterTheOutgoing() {
        let tail = analysed(noise(20, fadeOut))
        let intro = analysed(noise(12) { _ in 1 })
        #expect(plan(tail, intro, voices: voices(9, 1)).frames == plan(tail, intro).frames)
        let mix = plan(tail, intro, voices: voices(4, 1))
        #expect(seconds(Double(mix.frames)) == 4 + 1 + Automix.sungSlackSeconds)
        let blended = if case .blend = mix.style { true } else { false }
        #expect(blended, "\(mix)")
        // Too close to part, so swept with the overlap kept short.
        let close = plan(tail, intro, voices: voices(0, 0.5))
        let swept = if case .sweep(skew: true) = close.style { true } else { false }
        #expect(swept, "\(close)")
        #expect(seconds(Double(close.frames)) == Automix.minSeconds)
    }

    @Test func shortensABlendOnTheBeat() {
        let tail = analysed(fadedClicks(124))
        let mix = plan(tail, analysed(clicks(124, from: 0.05, for: 12)), voices: voices(5, 1))
        let length = seconds(Double(mix.frames))
        #expect((7.0...7.5).contains(length), "\(mix)")
        let start = seconds(Double(tail.frames)) - length
        #expect(offGrid(start + 0.05, 0.21, 60 / 124.0) < 0.003, "\(mix)")
    }

    @Test func tradesTheBassRatherThanSummingIt() {
        let sine = { (phase: Float) in
            StereoBuffer((0..<48_000).map { i -> Float in
                let angle: Float = tau * 50 * Float(i) / 48_000 + phase
                return sin(angle)
            })
        }
        let mixer = Automix.Mixer(frames: 48_000, style: .blend(trade: (24_000, 4_800)), rate: rate)
        let peak = mixer.mixed(sine(0.3), sine(0)).left.map(abs).max() ?? 0
        // Equal-power curves alone would sum the two near 1.4.
        #expect(peak < 1.05, "peaked at \(peak)")
    }

    @Test func endsEveryStyleOnTheIncomingWhole() {
        let incoming = StereoBuffer(Array(repeating: 0.5, count: 4_800), Array(repeating: -0.25, count: 4_800))
        let outgoing = StereoBuffer(Array(repeating: 0.9, count: 4_800))
        for style in styles {
            let out = Automix.Mixer(frames: 4_800, style: style, rate: rate).mixed(incoming, outgoing)
            let last = (out.left[4_799], out.right[4_799])
            #expect(abs(last.0 - 0.5) < 1e-3 && abs(last.1 + 0.25) < 1e-3, "\(style): \(last)")
        }
    }

    @Test func mixesEveryStyleAcrossPacketsAsInOne() {
        // Interleaved as Windows writes them, so the channels differ.
        let tail = split((0..<9_600).map { sin(Float($0) * 0.01) })
        let new = split((0..<9_600).map { cos(Float($0) * 0.03) })
        for style in styles {
            let run = { (piece: Int) -> (left: [Float], right: [Float]) in
                let mixer = Automix.Mixer(frames: 4_800, style: style, rate: rate)
                var out: (left: [Float], right: [Float]) = ([], [])
                for at in stride(from: 0, to: 4_800, by: piece) {
                    let frames = at..<min(at + piece, 4_800)
                    let held = { (side: (left: [Float], right: [Float])) in StereoBuffer(Array(side.left[frames]), Array(side.right[frames])) }
                    let part = mixer.mixed(held(new), held(tail), at: at, gains: (1, 0.5))
                    out.left += part.left
                    out.right += part.right
                }
                return out
            }
            #expect(run(61) == run(4_800), "\(style)")
        }
    }

    @Test func sweepsTheOutgoingDownAsTheIncomingOpens() {
        // 4 kHz, which the outgoing's low-pass ends far under and the incoming's high-pass lets through from the start.
        let tone = (0..<48_000).map { i -> Float in
            let phase: Float = tau * 4_000 * Float(i) / Float(rate)
            return sin(phase)
        }
        let silence = [Float](repeating: 0, count: 48_000)
        let sweep = { (new: [Float], old: [Float]) in
            Automix.Mixer(frames: 48_000, style: .sweep(skew: false), rate: rate).mixed(StereoBuffer(new), StereoBuffer(old)).left
        }
        let (old, new) = (sweep(silence, tone), sweep(tone, silence))
        var (oldLate, newLate): (Float, Float) = (0, 0)
        for i in 0..<48_000 {
            // As the mixer places the frame.
            let t = Float(i) * (1 / Float(48_000))
            let (rise, fall) = Automix.equalPower(t)
            if t > 0.8 {
                oldLate = max(oldLate, abs(old[i]) / fall)
            }
            if t >= Automix.openBy {
                newLate = max(newLate, abs(new[i] - tone[i] * rise))
            }
        }
        #expect(oldLate < 0.01, "the outgoing at \(oldLate)")
        #expect(newLate == 0, "the incoming whole once open")
    }

    @Test func echoesTheFirstBeatAndRingsOutByTheEnd() {
        let beat = 4_800
        // A tone throughout, which only the first beat should carry on.
        let tone = (0..<4 * beat).map { i -> Float in
            let phase: Float = tau * 440 * Float(i) / Float(rate)
            return sin(phase) * 0.5
        }
        let mixer = Automix.Mixer(frames: 4 * beat, style: .echo(beat: beat), rate: rate)
        let heard = mixer.mixed(StereoBuffer(Array(repeating: 0, count: 4 * beat)), StereoBuffer(tone)).left
        let peak = { (beats: Range<Int>) in heard[(beats.lowerBound * beat)..<(beats.upperBound * beat)].map(abs).max() ?? 0 }
        let (second, third) = (peak(1..<2), peak(2..<3))
        #expect(second > 0.3, "the first echo at \(second)")
        #expect(third < second * 0.6 && third > 0.05, "fed back at \(third)")
        let end = heard[(4 * beat - 48)...].map(abs).max() ?? 1
        #expect(end < 0.01, "rung out to \(end)")
    }

    @Test func ringsTheEchoOnOnceTheOutgoingEnds() {
        let beat = 4_800
        let tone = (0..<beat).map { sin(tau * 440 * Float($0) / Float(rate)) * 0.5 }
        let mixer = Automix.Mixer(frames: 4 * beat, style: .echo(beat: beat), rate: rate)
        let silence = { StereoBuffer(Array(repeating: 0, count: beat)) }
        _ = mixer.mixed(silence(), StereoBuffer(tone))
        let after = mixer.mixed(silence(), nil, at: beat).left.map(abs).max() ?? 0
        #expect(after > 0.3, "the first echo at \(after)")
    }

    @Test func mixesAtTheBuffersOffsetOnEachSidesRamp() {
        let (frames, offset) = (480, 100)
        let ones = StereoBuffer(Array(repeating: 1, count: frames))
        let out = StereoBuffer(Array(repeating: 0, count: offset + frames))
        // Ramps of the whole buffer, so a frame read from the blend's position rather than the offset shows.
        let gains = (Crossfade.Ramp(from: 0, to: 1, length: offset + frames), Crossfade.Ramp(from: 1, to: 0.5, length: offset + frames))
        withExtendedLifetime(ones) {
            Automix.Mixer(frames: frames, style: .crossfade, rate: rate).mix(
                incoming: ones.channels, outgoing: ones.channels, gains: gains, count: frames, at: 0, into: out.output, offset: offset
            )
        }
        let left = out.samples.left
        #expect(left.prefix(offset).allSatisfy { $0 == 0 })
        let error = (0..<frames).map { frame in
            let fade = Automix.equalPower(Float(frame) / Float(frames))
            return abs(left[offset + frame] - fade.rise * gains.0.at(offset + frame) - fade.fall * gains.1.at(offset + frame))
        }
        #expect((error.max() ?? 1) < 1e-6)
    }
}
