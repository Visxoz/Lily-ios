import Accelerate
import Foundation
import os

/// Plans a blend over where the outgoing item winds down or the incoming one builds, on the beat where their
/// tempos agree (tempo is never stretched), and trades their bass partway so only one plays.
enum Automix {
    /// The outgoing item's end analysed: room for the longest blend and the music before it, which sets its loud level.
    static let tailSeconds = 20.0
    /// The incoming item's start analysed, for its build and its beats.
    static let introSeconds = maxSeconds
    static let minSeconds = 3.0
    static let maxSeconds = 12.0
    /// 2.5 ms steps, so two items' beats, each placed to a step, line up within 5 ms, short of a flam.
    private static let hopsPerSecond = 400
    /// Loudness is judged over half a second, so a lone hit or gap isn't.
    private static let smoothHops = hopsPerSecond / 2
    /// An onset is the last 10 ms rising over the loudest 10 ms of the 80 ms before, so a kick stands out of the
    /// bass held under it, while a held note's ripple never tops its last peak.
    private static let recentHops = hopsPerSecond / 100
    private static let beforeHops = hopsPerSecond * 8 / 100
    /// The least rise that counts, in bels (3 dB), below which noise wavers.
    private static let minRise: Float = 0.3
    /// The most a rise counts for, in bels, so music entering out of a quiet stretch doesn't outweigh every beat.
    private static let maxRise: Float = 1
    /// How far under its loudest an intro is still building, in dB: half the amplitude.
    private static let quietDB: Float = 6
    /// The least a fade-out falls a second, in dB; a level that holds is the music, however soft.
    private static let fadeDBPerSecond: Float = 1
    /// How long a level must hold to count as held, so a slow fade's wavering doesn't.
    private static let heldSeconds = 5
    /// How much quieter than a later second a second may be within a fade, in dB; any more is the music's own bars.
    private static let swellDB: Float = 3
    /// How far under the loud level a held level is a noise floor a fade ends in, as tape hiss, in dB.
    private static let hissDB: Float = 30
    /// How far under the loud level a fade-out ends, at least, in dB; an item ending above it stops.
    private static let fadedDB: Float = 20
    /// The tempos searched, and the likeliest, which settles half or double time.
    private static let minBPM = 70.0
    private static let maxBPM = 180.0
    private static let likelyBPM = 120.0
    /// The onsets' correlation one beat apart needed to count as a beat, from 0 for noise to 1 for a metronome.
    private static let minPulse = 0.3
    /// Onsets are spread this many hops either side for the tempo, so hits drawn out or a little off still line up.
    private static let spreadHops = 4
    /// How far either side of the autocorrelation's peak the period is sought, as spread hits put it off the lag.
    private static let searchHops = 3
    /// How far either side of the whole-hop lag's anchor each finer period's anchor is sought.
    private static let anchorHops = 8
    /// The stretches, in seconds, each of which must keep to the grid found.
    private static let stretchSeconds = 4.0
    /// How far either side of a beat its onsets are its own, in hops.
    private static let centreHops = 6.0
    /// How far a stretch's beats may fall from the grid on average, in hops, before the period or tempo is off.
    private static let steadyHops = 4.0
    /// How many times more of a stretch's onset must lie near its beats than an even spread would leave there.
    private static let minClarity = 5.5
    /// The share of the onset the stretches keeping to the grid must carry.
    private static let keptShare = 2.0 / 3.0
    /// The fewest beats that must sound for a grid to count.
    private static let minBeats = 6
    /// The furthest the two items' beats may drift apart over a blend, in beats.
    private static let maxDrift = 0.1
    /// Where the bass splits from the rest.
    private static let bassHz = 160.0
    /// The bass trade's length with no beat to time it.
    private static let tradeSeconds = 0.5
    /// -100 dB, which keeps the log of silence finite.
    private static let floor: Float = 1e-10

    /// A steady beat, in frames: between beats, and to the first.
    struct Beats {
        let period: Double
        let first: Double
    }

    /// What a blend is planned on, from one item's frames.
    struct Analysis {
        let frames: Int
        let hop: Int
        /// Smoothed loudness at each hop, in dB.
        let level: [Float]
        let beats: Beats?

        /// The 90th percentile of the level: the item at its loud, not a peak.
        var loud: Float {
            level.isEmpty ? 0 : level.sorted()[level.count * 9 / 10]
        }

        /// Frames the item fades out over: from an end `fadedDB` under its loud level back to where its level last
        /// held, or last swelled; 0 for an ending that stops or holds a softer level to the end.
        var outro: Double {
            let second = hopsPerSecond
            // Each second's peak, the last first.
            let peaks = stride(from: level.count, through: second, by: -second).map { end in
                level[(end - second)..<end].reduce(-Float.greatestFiniteMagnitude, max)
            }
            guard peaks.count >= heldSeconds, let end = level.last else { return 0 }
            let loud = loud
            guard end <= loud - fadedDB else { return 0 }
            let floor = loud - hissDB
            func held(_ from: Int) -> Bool {
                let window = peaks[from..<(from + heldSeconds)]
                let (low, high) = window.reduce((Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)) {
                    (min($0.0, $1), max($0.1, $1))
                }
                return high >= floor && high - low <= Float(heldSeconds - 1) * fadeDBPerSecond
            }
            var seconds = (0...(peaks.count - heldSeconds)).first(where: held) ?? peaks.count - 1
            // A fade falls on to its end, so it starts after any second quieter than a later one by `swellDB`.
            var loudest = -Float.greatestFiniteMagnitude
            for (j, peak) in peaks.prefix(seconds).enumerated() {
                if peak < loudest - swellDB {
                    seconds = j
                    break
                }
                loudest = max(loudest, peak)
            }
            while seconds > 0, peaks[seconds] - peaks[0] < Float(seconds) * fadeDBPerSecond {
                seconds -= 1
            }
            return Double(seconds * second * hop)
        }

        /// Frames before the item first sounds near its loudest.
        var build: Double {
            let quiet = level.reduce(-Float.greatestFiniteMagnitude, max) - quietDB
            return level.firstIndex { $0 >= quiet }.map { Double($0 * hop) } ?? Double(frames)
        }
    }

    /// Measures each hop's energy as frames are decoded, so no samples are kept.
    struct Meter {
        let rate: Double
        let hop: Int
        private(set) var frames = 0
        private var lows: Lows
        /// Running sums of each hop's energy, whole and bass, so a stretch's mean is two lookups; in Double so a
        /// quiet stretch after a loud one keeps its precision.
        private var all: [Double] = [0]
        private var low: [Double] = [0]
        private var sums: (all: Float, low: Float) = (0, 0)
        private var inHop = 0

        init(rate: Double, frames capacity: Int) {
            self.rate = rate
            hop = max(Int(rate) / hopsPerSecond, 1)
            lows = Lows(rate: rate)
            all.reserveCapacity(capacity / hop + 1)
            low.reserveCapacity(capacity / hop + 1)
        }

        mutating func add(_ channels: Crossfade.Channels, count: Int) {
            var (lows, sums, inHop) = (self.lows, self.sums, self.inHop)
            for frame in 0..<count {
                let x = (channels.left[frame] + channels.right[frame]) / 2
                let bass = lows.run(x)
                sums.all += x * x
                sums.low += bass * bass
                inHop += 1
                if inHop == hop {
                    all.append(all[all.count - 1] + Double(sums.all / Float(hop)))
                    low.append(low[low.count - 1] + Double(sums.low / Float(hop)))
                    (sums, inHop) = ((0, 0), 0)
                }
            }
            (self.lows, self.sums, self.inHop) = (lows, sums, inHop)
            frames += count
        }

        /// The first `frames` measured.
        func analysis(frames: Int) -> Analysis {
            let frames = min(frames, self.frames)
            let hops = min(frames / hop, all.count - 1)
            let all = Array(all.prefix(hops + 1))
            let low = Array(low.prefix(hops + 1))
            // The bass's rises for kicks, the whole's for the rest, taken where they step up, as a capped rise
            // stays flat while its hit is recent.
            var last: Float = 0
            let onsets = (0..<hops).map { hop in
                let rise = Automix.rise(all, hop) + Automix.rise(low, hop)
                defer { last = rise }
                return max(rise - last, 0)
            }
            return Analysis(
                frames: frames, hop: hop, level: smooth(all),
                beats: beats(onsets, hopsPerSecond: rate / Double(hop)).map {
                    Beats(period: $0.period * Double(hop), first: $0.first * Double(hop))
                }
            )
        }
    }

    /// Two one-pole low-passes in series: the bass's loudness, for kicks.
    private struct Lows {
        let coefficient: Float
        var a: Float = 0
        var b: Float = 0

        init(rate: Double) {
            // `Float.pi` rounds down, so the turn is taken from Double, as Rust rounds its f32 TAU to nearest.
            coefficient = 1 - exp(-Float(2 * Double.pi) * Float(bassHz) / Float(rate))
        }

        mutating func run(_ x: Float) -> Float {
            a += coefficient * (x - a)
            b += coefficient * (a - b)
            if abs(b) < 1e-20 { (a, b) = (0, 0) }
            return b
        }
    }

    private static func mean(_ sums: [Double], _ from: Int, _ to: Int) -> Double {
        (sums[to] - sums[from]) / Double(to - from)
    }

    private static func bels(_ energy: Double) -> Float {
        log10(max(Float(energy), floor))
    }

    /// How far hop `i` and those just before rise over the loudest stretch as long before them, past `minRise` and
    /// up to `maxRise`; none this early in.
    private static func rise(_ sums: [Double], _ i: Int) -> Float {
        let before = i + 1 - recentHops - beforeHops
        guard before >= 0 else { return 0 }
        let recent = before + beforeHops
        var loudest = 0.0
        for from in before...(recent - recentHops) {
            loudest = max(loudest, mean(sums, from, from + recentHops))
        }
        let rise = bels(mean(sums, recent, i + 1)) - bels(loudest)
        return max(min(rise, maxRise) - minRise, 0)
    }

    /// Each hop's energy averaged over `smoothHops` around it, in dB.
    private static func smooth(_ sums: [Double]) -> [Float] {
        let hops = sums.count - 1
        return (0..<hops).map { i in
            10 * bels(mean(sums, max(i - smoothHops / 2, 0), min(i + smoothHops / 2, hops)))
        }
    }

    /// The beat in `onsets`, in hops: the likeliest tempo's lag, the comb grid near it gathering the most onset,
    /// then fitted through its beats' onsets. Nil unless the pulse is regular and every stretch keeps to the grid.
    private static func beats(_ onsets: [Float], hopsPerSecond: Double) -> Beats? {
        let n = onsets.count
        let minLag = Int((60 * hopsPerSecond / maxBPM).rounded(.down))
        let maxLag = Int((60 * hopsPerSecond / minBPM).rounded(.up))
        // Four of the slowest beats at least; and every period searched positive, so `comb` ends.
        guard minLag > searchHops, n >= 4 * maxLag else { return nil }
        let blurred = spread(onsets)
        let average = blurred.reduce(0.0) { $0 + Double($1) } / Double(n)
        let d = blurred.map { Double($0) - average }
        let power = vDSP.sumOfSquares(d)
        guard power > 0 else { return nil }
        var found: (lag: Int, pulse: Double, score: Double)?
        for lag in minLag...maxLag {
            // Scaled for the shrinking overlap, so long lags aren't penalised.
            let pulse = vDSP.dot(d[..<(n - lag)], d[lag...]) / power * Double(n) / Double(n - lag)
            let octaves = log2(60 * hopsPerSecond / Double(lag) / likelyBPM)
            let score = pulse * exp(-0.5 * octaves * octaves)
            // The last of equals, as Windows takes.
            if found.map({ score >= $0.score }) ?? true { found = (lag, pulse, score) }
        }
        guard let (lag, pulse, _) = found, pulse >= minPulse else { return nil }
        // A whole-hop lag drifts off the beat over the window, so the period is sought to a fiftieth of a hop.
        // Anchored mid-window, the best anchor barely moves with the period, so it is sought only near the lag's.
        let (mid, half) = (n / 2, lag / 2)
        guard let (_, rough) = best(blurred, periods: [Double(lag)], anchors: (mid - half)...(mid + half)) else { return nil }
        let periods = (-50 * searchHops...50 * searchHops).map { Double(lag) + Double($0) / 50 }
        guard let (period, anchor) = best(blurred, periods: periods, anchors: (rough - anchorHops)...(rough + anchorHops))
        else { return nil }
        // The blur that lets the comb find the beat also flattens it over small errors, so the grid is then fitted
        // through where each beat's onsets centre.
        var grid = (period: period, anchor: Double(anchor))
        for _ in 0..<2 {
            guard let fitted = fit(centres(onsets, grid)) else { return nil }
            grid = fitted
        }
        // A few hits alone space out a tempo of their own.
        let teeth = centres(onsets, grid)
        let typical = teeth.reduce(0) { $0 + $1.mass } / Double(teeth.count)
        guard teeth.count(where: { $0.mass >= typical / 2 }) >= minBeats else { return nil }
        // A period a little off, or a tempo that wanders, fits the whole window but leaves some stretch off the grid.
        // A stretch with little onset is skipped; one on the off-beats, as in a breakdown, passes while such
        // stretches carry at most `1 - keptShare` of the onset.
        let offBeats = centres(onsets, (grid.period, grid.anchor + grid.period / 2))
        let stretches = max(Int((Double(n) / (stretchSeconds * hopsPerSecond)).rounded()), 1)
        let share = onsets.reduce(0.0) { $0 + Double($1) } / Double(2 * stretches)
        var (kept, lost) = (0.0, 0.0)
        for stretch in 0..<stretches {
            let hops = stretch * n / stretches..<(stretch + 1) * n / stretches
            let mass = onsets[hops].reduce(0.0) { $0 + Double($1) }
            func keeps(_ teeth: [Tooth], _ anchor: Double) -> Bool {
                var (near, off) = (0.0, 0.0)
                for tooth in teeth where hops.contains(Int(tooth.at)) {
                    near += tooth.mass
                    off += tooth.mass * (tooth.at - (anchor + tooth.k * grid.period))
                }
                return near / mass * grid.period / (2 * centreHops + 1) >= minClarity && abs(off / near) <= steadyHops
            }
            if mass < share {
                continue
            } else if keeps(teeth, grid.anchor) {
                kept += mass
            } else if keeps(offBeats, grid.anchor + grid.period / 2) {
                lost += mass
            } else {
                return nil
            }
        }
        guard kept >= keptShare * (kept + lost) else { return nil }
        let first = grid.anchor.truncatingRemainder(dividingBy: grid.period)
        return Beats(period: grid.period, first: first < 0 ? first + grid.period : first)
    }

    /// The period and anchor whose grid gathers the most onset, the last of equals.
    private static func best(_ onsets: [Float], periods: [Double], anchors: ClosedRange<Int>) -> (Double, Int)? {
        var found: (score: Float, period: Double, anchor: Int)?
        for period in periods {
            for anchor in anchors {
                let score = comb(onsets, period, anchor)
                if found.map({ score >= $0.score }) ?? true { found = (score, period, anchor) }
            }
        }
        return found.map { ($0.period, $0.anchor) }
    }

    /// The onset gathered by a grid of beats `period` apart through `anchor`.
    private static func comb(_ onsets: [Float], _ period: Double, _ anchor: Int) -> Float {
        let anchor = Double(anchor)
        var k = (-anchor / period).rounded(.up)
        var sum: Float = 0
        while true {
            let at = (anchor + k * period).rounded()
            guard at < Double(onsets.count) else { return sum }
            if at >= 0 { sum += onsets[Int(at)] }
            k += 1
        }
    }

    /// A grid's beat: its number from the anchor, where its onset within `centreHops` centres, and how much.
    private struct Tooth {
        let k: Double
        let at: Double
        let mass: Double
    }

    /// The beats of a grid that have onset near them.
    private static func centres(_ onsets: [Float], _ grid: (period: Double, anchor: Double)) -> [Tooth] {
        let last = Double(onsets.count - 1)
        let (from, to) = ((-grid.anchor / grid.period).rounded(.up), ((last - grid.anchor) / grid.period).rounded(.down))
        // At most a beat a hop, which also keeps `Int(_:)` from trapping on a degenerate grid.
        guard from <= to, to - from <= last else { return [] }
        return (Int(from)...Int(to)).compactMap { k in
            let beat = grid.anchor + Double(k) * grid.period
            let first = max(Int((beat - centreHops).rounded(.up)), 0)
            let final = min(Int((beat + centreHops).rounded(.down)), onsets.count - 1)
            guard first <= final else { return nil }
            var (mass, moment) = (0.0, 0.0)
            for hop in first...final {
                mass += Double(onsets[hop])
                moment += Double(onsets[hop]) * Double(hop)
            }
            return mass > 0 ? Tooth(k: Double(k), at: moment / mass, mass: mass) : nil
        }
    }

    /// The grid through `teeth` by least squares, each weighted by its onset, should two beats or more have onset.
    private static func fit(_ teeth: [Tooth]) -> (period: Double, anchor: Double)? {
        var (w, x, y) = (0.0, 0.0, 0.0)
        for tooth in teeth {
            w += tooth.mass
            x += tooth.mass * tooth.k
            y += tooth.mass * tooth.at
        }
        (x, y) = (x / w, y / w)
        var (cov, variance) = (0.0, 0.0)
        for tooth in teeth {
            cov += tooth.mass * (tooth.k - x) * (tooth.at - y)
            variance += tooth.mass * (tooth.k - x) * (tooth.k - x)
        }
        let period = cov / variance
        return variance > 0 && period > 0 ? (period, y - period * x) : nil
    }

    /// Each onset spread over `spreadHops` either side, tapering.
    private static func spread(_ onsets: [Float]) -> [Float] {
        let n = onsets.count
        return (0..<n).map { i in
            var sum: Float = 0
            for j in max(i - spreadHops, 0)..<min(i + spreadHops + 1, n) {
                sum += onsets[j] * Float(spreadHops + 1 - abs(i - j))
            }
            return sum
        }
    }

    /// A planned blend over the tail's last `frames`, the bass traded over `tradeLength` frames from `tradeAt`.
    struct Mix {
        let frames: Int
        let tradeAt: Int
        let tradeLength: Int
    }

    /// Blends over the outgoing item's fade-out or the incoming one's build, whichever is longer, ending as the
    /// outgoing ends, within `room` frames and over at most half an incoming item shorter than its intro. Where
    /// both have a beat that won't drift apart, it starts so the incoming's first beat lands on one of the outgoing's.
    static func plan(tail: Analysis, intro: Analysis, rate: Double, room: Int) -> Mix {
        let end = Double(tail.frames)
        var longest = min(maxSeconds * rate, end, Double(room))
        if Double(intro.frames) < introSeconds * rate {
            longest = min(longest, Double(intro.frames) / 2)
        }
        let shortest = min(minSeconds * rate, longest)
        var length = min(max(tail.outro, intro.build, shortest), longest)
        var aligned = false
        if let out = tail.beats, let next = intro.beats {
            // The beats either side of the planned start, so one stays in range.
            let k = (end - length + next.first - out.first) / out.period
            let drift = abs(1 / out.period - 1 / fold(next.period, to: out.period))
            let onBeat = [k.rounded(.down), k.rounded(.up)]
                .map { end - (out.first + $0 * out.period - next.first) }
                .filter { (shortest...longest).contains($0) && $0 * drift <= maxDrift }
                .min { abs($0 - length) < abs($1 - length) }
            if let onBeat { (length, aligned) = (onBeat, true) }
        }
        let bpm = { (beats: Beats?) in beats.map { (60 * rate / $0.period).formatted(.number.precision(.fractionLength(1))) } ?? "no" }
        Logger.audio.debug(
            "Automix: \(length / rate, format: .fixed(precision: 1)) s blend, \(bpm(tail.beats), privacy: .public) BPM into \(bpm(intro.beats), privacy: .public) BPM, \(aligned ? "on the beat" : "not aligned", privacy: .public)"
        )
        // Over half a beat, ending on the incoming's beat nearest midway.
        var (tradeLength, tradeEnd) = (tradeSeconds * rate, (length + tradeSeconds * rate) / 2)
        if let beats = intro.beats {
            let k = max(((length / 2 - beats.first) / beats.period).rounded(), 0)
            (tradeLength, tradeEnd) = (beats.period / 2, beats.first + k * beats.period)
        }
        tradeLength = min(tradeLength, length)
        return Mix(
            frames: Int(length), tradeAt: Int(min(max(tradeEnd - tradeLength, 0), length - tradeLength)),
            tradeLength: max(Int(tradeLength), 1)
        )
    }

    /// `period` halved or doubled to within `to`'s range, as an item in double time still lands on every other beat.
    static func fold(_ period: Double, to: Double) -> Double {
        var period = period
        while period > to * 1.5 { period /= 2 }
        while period < to * 0.75 { period *= 2 }
        return period
    }

    /// Cuts the bass: two Butterworth high-passes (RBJ's cookbook) in series, 24 dB an octave, so a kick an octave
    /// down is 24 dB under. In Double, as so low a corner is unsteady in Float.
    private struct Cut {
        private let b0: Double
        private let a1: Double
        private let a2: Double
        /// Each stage's transposed direct form II memory.
        private var first = (0.0, 0.0)
        private var second = (0.0, 0.0)

        init(rate: Double) {
            let angle = 2 * .pi * bassHz / rate
            let alpha = sin(angle) * 0.5.squareRoot()
            let a0 = 1 + alpha
            b0 = (1 + cos(angle)) / 2 / a0
            a1 = -2 * cos(angle) / a0
            a2 = (1 - alpha) / a0
        }

        mutating func run(_ input: Float) -> Float {
            // A high-pass's b1 is -2 b0 and its b2 is b0.
            let (b0, a1, a2) = (b0, a1, a2)
            func stage(_ x: Double, _ z: inout (Double, Double)) -> Double {
                let y = b0 * x + z.0
                z = (-2 * b0 * x - a1 * y + z.1, b0 * x - a2 * y)
                return y
            }
            let output = stage(stage(Double(input), &first), &second)
            // On the memory, as a high-pass's output nears 0 under a steady input while its memory doesn't.
            if max(abs(first.0), abs(first.1), abs(second.0), abs(second.1)) < 1e-20 {
                (first, second) = ((0, 0), (0, 0))
            }
            return Float(output)
        }
    }

    /// A blend's bass trade: the incoming item comes in with its bass cut, which it takes back as the outgoing one
    /// gives up its own. A class, so its filters carry on from one buffer to the next.
    final class Trade {
        private let at: Int64
        private let length: Int64
        private var cuts: (incoming: (Cut, Cut), outgoing: (Cut, Cut))

        init(_ mix: Mix, rate: Double) {
            at = Int64(mix.tradeAt)
            length = Int64(mix.tradeLength)
            let cut = Cut(rate: rate)
            cuts = ((cut, cut), (cut, cut))
        }

        /// The bass's share passed to the incoming item, eased so it neither clicks nor lingers.
        private func progress(at frame: Int64) -> Float {
            let s = min(Float(max(frame - at, 0)) / Float(length), 1)
            return s * s * (3 - 2 * s)
        }

        func incoming(_ sample: (Float, Float), at frame: Int64) -> (Float, Float) {
            // Once traded, the cut is never heard again.
            guard frame < at + length else { return sample }
            let share = progress(at: frame)
            let cut = (cuts.incoming.0.run(sample.0), cuts.incoming.1.run(sample.1))
            return (cut.0 + (sample.0 - cut.0) * share, cut.1 + (sample.1 - cut.1) * share)
        }

        func outgoing(_ sample: (Float, Float), at frame: Int64) -> (Float, Float) {
            let share = progress(at: frame)
            let cut = (cuts.outgoing.0.run(sample.0), cuts.outgoing.1.run(sample.1))
            return (sample.0 + (cut.0 - sample.0) * share, sample.1 + (cut.1 - sample.1) * share)
        }
    }
}
