import Accelerate
import Foundation
import os

/// Plans a blend on the bar or beat, varispeeding the outgoing item to a near tempo and keeping two voices apart, and
/// mixes it by trading bass, sweeping filters or echoing out.
enum Automix {
    /// The outgoing item's end analysed: room for the longest blend and its varispeed, and the music before it, which
    /// sets its loud level.
    static let tailSeconds = 20.0
    /// The incoming item's start analysed, for its build and its beats.
    static let introSeconds = maxSeconds
    static let minSeconds = 3.0
    static let maxSeconds = 12.0
    /// 2.5 ms steps, so two items' beats, each fitted within a step, line up within 5 ms, short of a flam.
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
    /// The least correlation of onsets a beat apart, from 0 for noise to 1 for a metronome; the grid's own checks
    /// reject what passes wrongly, so this only spares them noise.
    private static let minPulse = 0.25
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
    /// The share of the beats' onset both thirds between them must carry for the grid to be a beat and a half; a
    /// swung beat fills only one.
    private static let thirds = 0.2
    /// The share of the beats' onset, and of their bass, the off-beats may carry before the grid may be two beats.
    private static let offBeatShare = 0.8
    /// The fewest beats that must sound for a grid to count.
    private static let minBeats = 6
    /// The furthest the two items' beats may drift apart over a blend, in beats.
    private static let maxDrift = 0.1
    /// How much more bass onset the downbeats must carry than the next likeliest beat of the bar, for a bar to count.
    private static let barClarity = 1.5
    /// Blends of this many bars are the likeliest a DJ plays.
    private static let phraseBars: [Double] = [4, 8]
    /// The least a tempo change takes, in seconds, in whole bars of at least two where there are bars.
    static let rampSeconds = 4.0
    /// The share of an item's energy that must be bass for it to carry bass.
    private static let bassShare = 0.15
    /// How close to its loud level an item ending without a fade ends, in dB, for it to stop hard.
    private static let hardDB: Float = 6
    /// The most beats an echo out replaces.
    private static let echoBeats = 4.0
    /// How much of each echo feeds the next.
    private static let feedback: Float = 0.45
    /// How long the beat sent to the echo takes to fade in and out, in seconds.
    private static let edgeSeconds = 0.003
    /// The echo's damping, each repeat darker and thinner, in Hz.
    private static let echoLowHz = 4_000.0
    private static let echoHighHz = 150.0
    /// How far a sweep's low-pass falls on the outgoing item, from open, in Hz.
    private static let sweepToHz = 300.0
    private static let openHz = 20_000.0
    /// Where the incoming item's high-pass starts, and where it is open by, in Hz.
    private static let sweepFromHz = 1_200.0
    private static let openedHz = 30.0
    /// How far into the blend the incoming item is open, and how long each side's filter takes to come in or go out,
    /// as shares of it.
    static let openBy: Float = 0.6
    private static let filteredBy: Float = 0.25
    /// How often a sweep's filters are retuned, in frames.
    private static let retuneFrames = 32
    /// Where skewed curves have the outgoing item out and the incoming in from, as a share of the blend, so two voices
    /// barely overlap; equal power between 0.4 and 0.6.
    private static let skew: Float = 0.6
    /// How far the incoming item's first word may come before the outgoing's timed last line ends, in seconds, as
    /// line-timed lyrics hold each line until the next, past its singing.
    static let sungSlackSeconds = 1.5
    /// Where the bass splits from the rest.
    private static let bassHz = 160.0
    /// The low-pass whose remainder is the highs, snares and hats; gentle, as a steep split found fewer beats and
    /// more wrong ones.
    private static let highHz = 2_000.0
    /// The bass trade's length with no beat to time it.
    private static let tradeSeconds = 0.5
    /// How long before the trade the outgoing item's cut starts, so it has settled.
    private static let warmSeconds = 0.02
    /// -100 dB, which keeps the log of silence finite.
    private static let silentEnergy: Float = 1e-10
    /// Filter memory below this is flushed, as denormal floats are slow.
    private static let denormal: Float = 1e-20

    /// A beat's period and its first beat, or anchor, in hops.
    private typealias Grid = (period: Double, anchor: Double)

    /// A steady beat, in frames: between beats, to the first, and to the first downbeat of a bar of four should one
    /// stand out.
    struct Beats {
        let period: Double
        let first: Double
        let downbeat: Double?
    }

    /// What a blend is planned on, from one item's frames.
    struct Analysis {
        let frames: Int
        fileprivate let hop: Int
        /// Smoothed loudness at each hop, in dB.
        fileprivate let level: [Float]
        /// The level's 90th percentile: the item at its loud, not a peak.
        fileprivate let loud: Float
        let beats: Beats?
        /// Bass is a good share of it, for trading.
        let bass: Bool

        /// Frames the item fades out over: from an end `fadedDB` under its loud level back to where its level last
        /// held, or last swelled; 0 for an ending that stops or holds a softer level to the end.
        fileprivate var outro: Double {
            guard let end = level.last, end <= loud - fadedDB else { return 0 }
            let second = hopsPerSecond
            // Each second's peak, the last first.
            let peaks = stride(from: level.count, through: second, by: -second).map { upTo in
                level[(upTo - second)..<upTo].reduce(-Float.greatestFiniteMagnitude, max)
            }
            guard peaks.count >= heldSeconds else { return 0 }
            let hiss = loud - hissDB
            func held(_ from: Int) -> Bool {
                let window = peaks[from..<(from + heldSeconds)]
                let (low, high) = window.reduce((Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)) {
                    (min($0.0, $1), max($0.1, $1))
                }
                return high >= hiss && high - low <= Float(heldSeconds - 1) * fadeDBPerSecond
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
        fileprivate var build: Double {
            let quiet = level.reduce(-Float.greatestFiniteMagnitude, max) - quietDB
            return level.firstIndex { $0 >= quiet }.map { Double($0 * hop) } ?? Double(frames)
        }

        /// An echo out over the last whole beats, up to `echoBeats`, and the beat, in frames; only for an item that
        /// ends hard, with no fade-out and its last second near loud.
        fileprivate func echo(longest: Double, outro: Double) -> (length: Double, beat: Double)? {
            let last = max(level.count - hopsPerSecond, 0)
            guard outro == 0, level[last...].contains(where: { $0 >= loud - hardDB }), let beats else { return nil }
            let end = Double(frames)
            let k = max(((end - echoBeats * beats.period - beats.first) / beats.period).rounded(.up), 0)
            let length = end - beats.first - k * beats.period
            return length >= beats.period && length <= longest ? (length, beats.period) : nil
        }
    }

    /// Measures each hop's energy as frames are decoded, so no samples are kept.
    struct Meter {
        private let rate: Double
        private let hop: Int
        private(set) var frames = 0
        private var lows: Lows
        private var underHighs: Lows
        /// Running sums of each hop's energy, whole, bass and highs, so a stretch's mean is two lookups; in Double so
        /// a quiet stretch after a loud one keeps its precision.
        private var all: [Double] = [0]
        private var low: [Double] = [0]
        private var high: [Double] = [0]
        private var sums: (all: Float, low: Float, high: Float) = (0, 0, 0)
        private var inHop = 0

        init(rate: Double, frames capacity: Int) {
            self.rate = rate
            hop = max(Int(rate) / hopsPerSecond, 1)
            lows = Lows(hz: bassHz, rate: rate)
            underHighs = Lows(hz: highHz, rate: rate)
            all.reserveCapacity(capacity / hop + 1)
            low.reserveCapacity(capacity / hop + 1)
            high.reserveCapacity(capacity / hop + 1)
        }

        mutating func add(_ channels: Crossfade.Channels, count: Int) {
            var (lows, underHighs, sums, inHop) = (self.lows, self.underHighs, self.sums, self.inHop)
            for frame in 0..<count {
                let x = (channels.left[frame] + channels.right[frame]) / 2
                let bass = lows.run(x)
                let highs = x - underHighs.run(x)
                sums.all += x * x
                sums.low += bass * bass
                sums.high += highs * highs
                inHop += 1
                if inHop == hop {
                    all.append(all[all.count - 1] + Double(sums.all / Float(hop)))
                    low.append(low[low.count - 1] + Double(sums.low / Float(hop)))
                    high.append(high[high.count - 1] + Double(sums.high / Float(hop)))
                    (sums, inHop) = ((0, 0, 0), 0)
                }
            }
            (self.lows, self.underHighs, self.sums, self.inHop) = (lows, underHighs, sums, inHop)
            frames += count
        }

        func analysis(frames: Int) -> Analysis {
            let frames = min(frames, self.frames)
            let hops = frames / hop
            // Where the bass's, highs' and whole's capped rises step up, as each stays flat while its hit is recent;
            // the bass's uncapped mark the downbeats.
            var last: Float = 0
            var (onsets, hits) = ([Float](), [Float]())
            onsets.reserveCapacity(hops)
            hits.reserveCapacity(hops)
            for i in 0..<hops {
                let bass = Automix.rise(low, i)
                let rise = Automix.rise(all, i).bels + bass.bels + Automix.rise(high, i).bels
                onsets.append(max(rise - last, 0))
                hits.append(bass.energy)
                last = rise
            }
            let level = smooth(all, hops)
            let beats = Automix.beats(onsets, hits, hopRate: rate / Double(hop)).map { grid in
                Beats(
                    period: grid.period * Double(hop), first: grid.anchor * Double(hop),
                    downbeat: downbeat(hits, grid).map { $0 * Double(hop) }
                )
            }
            return Analysis(
                frames: frames, hop: hop, level: level, loud: level.isEmpty ? 0 : level.sorted()[level.count * 9 / 10],
                // Strictly, so silence carries none.
                beats: beats, bass: low[hops] > bassShare * all[hops]
            )
        }
    }

    /// Two one-pole low-passes in series: the bass's loudness, for kicks, what the highs are split from, and an
    /// echo's damping.
    private struct Lows {
        let coefficient: Float
        var a: Float = 0
        var b: Float = 0

        init(hz: Double, rate: Double) {
            coefficient = 1 - exp(-4 * quarterTurn * Float(hz) / Float(rate))
        }

        mutating func run(_ x: Float) -> Float {
            a += coefficient * (x - a)
            b += coefficient * (a - b)
            if abs(a) < denormal, abs(b) < denormal { (a, b) = (0, 0) }
            return b
        }
    }

    private static func mean(_ sums: [Double], _ from: Int, _ to: Int) -> Double {
        (sums[to] - sums[from]) / Double(to - from)
    }

    private static func bels(_ energy: Double) -> Float {
        log10(max(Float(energy), silentEnergy))
    }

    private static func total(_ x: some Sequence<Float>) -> Double {
        x.reduce(0) { $0 + Double($1) }
    }

    /// How far hop `i` and those just before rise over the loudest stretch as long before them, from running `sums`:
    /// in bels past `minRise` and up to `maxRise`, and in energy; none this early in.
    private static func rise(_ sums: [Double], _ i: Int) -> (bels: Float, energy: Float) {
        let before = i + 1 - recentHops - beforeHops
        guard before >= 0 else { return (0, 0) }
        let from = before + beforeHops
        func energy(_ j: Int) -> Double { sums[j + recentHops] - sums[j] }
        var loudest = 0.0
        for j in before...(from - recentHops) {
            loudest = max(loudest, energy(j))
        }
        let now = energy(from)
        // Per hop, so silence floors where the level's does.
        let width = Double(recentHops)
        let rise = bels(now / width) - bels(loudest / width)
        return (max(min(rise, maxRise) - minRise, 0), Float(max(now - loudest, 0)))
    }

    /// Each of the first `hops` hops' energy averaged over `smoothHops` around it, in dB.
    private static func smooth(_ sums: [Double], _ hops: Int) -> [Float] {
        (0..<hops).map { i in
            10 * bels(mean(sums, max(i - smoothHops / 2, 0), min(i + smoothHops / 2, hops)))
        }
    }

    /// The first downbeat of `beats`, in hops: of the bar's four beats, the one whose bass `hits` are clearly the
    /// strongest.
    private static func downbeat(_ hits: [Float], _ beats: Grid) -> Double? {
        let bar = (period: 4 * beats.period, anchor: beats.anchor)
        let weights = (0..<4).map { near(hits, bar, Double($0) / 4) }
        let sorted = weights.sorted(by: >)
        guard let beat = weights.firstIndex(of: sorted[0]), sorted[0] > barClarity * sorted[1] else { return nil }
        return beats.anchor + Double(beat) * beats.period
    }

    /// The beat in `onsets`, in hops: the comb grid near the likeliest lag, fitted through its onsets, and narrowed
    /// (else none) should it hold one and a half beats or two. Nil unless the pulse is regular and the stretches
    /// keep to it.
    private static func beats(_ onsets: [Float], _ hits: [Float], hopRate: Double) -> Grid? {
        let n = onsets.count
        let minLag = Int((60 * hopRate / maxBPM).rounded(.down))
        let maxLag = Int((60 * hopRate / minBPM).rounded(.up))
        // Four of the slowest beats at least; and every period searched positive, so `comb` ends.
        guard minLag > searchHops, n >= 4 * maxLag else { return nil }
        let blurred = spread(onsets)
        let average = total(blurred) / Double(n)
        let d = blurred.map { Double($0) - average }
        let power = vDSP.sumOfSquares(d)
        guard power > 0 else { return nil }
        var found: (lag: Int, pulse: Double, score: Double)?
        for lag in minLag...maxLag {
            // Scaled for the shrinking overlap, so long lags aren't penalised.
            let pulse = vDSP.dot(d[..<(n - lag)], d[lag...]) / power * Double(n) / Double(n - lag)
            let octaves = log2(60 * hopRate / Double(lag) / likelyBPM)
            let score = pulse * exp(-0.5 * octaves * octaves)
            // The last of equals, as Windows takes.
            if found.map({ score >= $0.score }) ?? true { found = (lag, pulse, score) }
        }
        guard let (lag, pulse, _) = found, pulse >= minPulse, var beat = grid(onsets, blurred, Double(lag)) else { return nil }
        var on = near(onsets, beat, 0)
        // Onset a third and two thirds between beats makes a beat and a half (3-3-2) or a beat under triplets; only
        // the former finds more bass a beat within.
        if min(near(onsets, beat, 1.0 / 3), near(onsets, beat, 2.0 / 3)) >= thirds * on {
            let perBeat = { (grid: Grid) in near(hits, grid, 0) * grid.period }
            guard let fine = finer(onsets, blurred, beat.period * 2 / 3, minLag), perBeat(fine) > perBeat(beat) else { return nil }
            beat = fine
            on = near(onsets, beat, 0)
        }
        // Off-beats nearly as strong, the bass's too, make it two beats, its phase a toss-up.
        if near(onsets, beat, 0.5) >= offBeatShare * on, near(hits, beat, 0.5) >= offBeatShare * near(hits, beat, 0) {
            guard let fine = finer(onsets, blurred, beat.period / 2, minLag) else { return nil }
            beat = fine
        }
        return steady(onsets, beat, hopRate: hopRate)
    }

    /// The grid near `lag`, should it be no shorter than `minLag`.
    private static func finer(_ onsets: [Float], _ blurred: [Float], _ lag: Double, _ minLag: Int) -> Grid? {
        lag < Double(minLag) ? nil : grid(onsets, blurred, lag)
    }

    /// The onset of `of` near the beats of `grid`, moved on by `shift` beats.
    private static func near(_ of: [Float], _ grid: Grid, _ shift: Double) -> Double {
        centres(of, (grid.period, grid.anchor + shift * grid.period)).reduce(0) { $0 + $1.mass }
    }

    /// The grid near `lag` gathering the most of `blurred`, fitted through `onsets`.
    private static func grid(_ onsets: [Float], _ blurred: [Float], _ lag: Double) -> Grid? {
        // To a fiftieth of a hop, as a whole-hop lag drifts off the beat over the window. Anchored mid-window, the
        // best anchor barely moves with the period, so it is sought only near the lag's.
        let (mid, reach) = (onsets.count / 2, Int(lag) / 2)
        let (_, rough) = best(blurred, periods: [lag], anchors: (mid - reach)...(mid + reach))
        let periods = (-50 * searchHops...50 * searchHops).map { lag + Double($0) / 50 }
        let (period, anchor) = best(blurred, periods: periods, anchors: (rough - anchorHops)...(rough + anchorHops))
        // The blur that lets the comb find the beat also flattens it over small errors, so the grid is then fitted
        // through where each beat's onsets centre.
        var grid = (period: period, anchor: Double(anchor))
        for _ in 0..<2 {
            guard let fitted = fit(centres(onsets, grid)) else { return nil }
            grid = fitted
        }
        return grid
    }

    /// `grid` with its first beat for its anchor, should enough beats sound and the stretches keep to it.
    private static func steady(_ onsets: [Float], _ grid: Grid, hopRate: Double) -> Grid? {
        let n = onsets.count
        // A few hits alone space out a tempo of their own.
        let teeth = centres(onsets, grid)
        let typical = teeth.reduce(0) { $0 + $1.mass } / Double(teeth.count)
        guard teeth.count(where: { $0.mass >= typical / 2 }) >= minBeats else { return nil }
        // A period a little off, or a tempo that wanders, leaves a stretch off the grid; off-beat stretches, as in a
        // breakdown, pass only between ones on the beat.
        let offBeats = centres(onsets, (grid.period, grid.anchor + grid.period / 2))
        let stretches = max(Int((Double(n) / (stretchSeconds * hopRate)).rounded()), 1)
        let share = total(onsets) / Double(2 * stretches)
        var (kept, lost, endsOff) = (0.0, 0.0, false)
        for stretch in 0..<stretches {
            let hops = stretch * n / stretches..<(stretch + 1) * n / stretches
            let mass = total(onsets[hops])
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
                endsOff = false
            } else if kept > 0, keeps(offBeats, grid.anchor + grid.period / 2) {
                lost += mass
                endsOff = true
            } else {
                return nil
            }
        }
        guard !endsOff, kept >= keptShare * (kept + lost) else { return nil }
        let first = grid.anchor.truncatingRemainder(dividingBy: grid.period)
        return (grid.period, first < 0 ? first + grid.period : first)
    }

    /// The period and anchor whose grid gathers the most onset, the last of equals. `periods` is never empty.
    private static func best(_ onsets: [Float], periods: [Double], anchors: ClosedRange<Int>) -> (Double, Int) {
        // Seeded with the first, so it holds even should every score be NaN.
        var found = (score: -Float.infinity, period: periods[0], anchor: anchors.lowerBound)
        for period in periods {
            for anchor in anchors {
                let score = comb(onsets, period, anchor)
                if score >= found.score { found = (score, period, anchor) }
            }
        }
        return (found.period, found.anchor)
    }

    /// The onset gathered by a grid of beats `period` apart through `anchor`.
    private static func comb(_ onsets: [Float], _ period: Double, _ anchor: Int) -> Float {
        let anchor = Double(anchor)
        var k = (-anchor / period).rounded(.up)
        var sum: Float = 0
        while true {
            let at = (anchor + k * period).rounded()
            guard at < Double(onsets.count) else { return sum }
            // From the first beat at or past 0, which rounds no lower than -0.
            sum += onsets[Int(at)]
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
    private static func centres(_ onsets: [Float], _ grid: Grid) -> [Tooth] {
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
    private static func fit(_ teeth: [Tooth]) -> Grid? {
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

    /// How a blend is mixed.
    enum Style {
        /// Equal-power curves, the bass traded over `length` frames from `at` where both items carry it.
        case blend(trade: (at: Int, length: Int)?)
        /// The outgoing item low-passed away as the incoming opens from a high-pass, `skew`ed curves keeping two
        /// voices' overlap short.
        case sweep(skew: Bool)
        /// The outgoing item's last beats replaced by echoes of the first, `beat` frames apart, under the incoming.
        case echo(beat: Int)

        /// A crossfade's: equal-power curves alone.
        static let crossfade = Style.blend(trade: nil)
    }

    /// The tail from `start` on played by the curve, so the blend is at the incoming item's tempo.
    typealias Warp = (start: Int, curve: Varispeed)

    /// A planned blend over the tail's last `frames`, counted at the incoming item's speed, mixed in `style`.
    struct Mix {
        let frames: Int
        let warp: Warp?
        let style: Style
    }

    /// Where the two songs are sung about the blend, in frames: from the outgoing's last word to its tail's end, and
    /// from the incoming's start to its first word.
    struct Voices {
        var last: Double?
        var first: Double?

        /// The longest blend, the outgoing played at `speed`, after which the incoming's first word follows the
        /// outgoing's last; nil where either is unknown.
        func longest(speed: Double, rate: Double) -> Double? {
            guard let first, let last else { return nil }
            return first + last / speed + sungSlackSeconds * rate
        }
    }

    /// Blend lengths `step` apart through `at`.
    fileprivate struct Lengths {
        let at: Double
        let step: Double

        func within(_ shortest: Double, _ longest: Double) -> [Double] {
            let k = { ($0 - at) / step }
            return stride(from: k(shortest).rounded(.up), through: k(longest).rounded(.down), by: 1).map { at + $0 * step }
        }
    }

    /// How the outgoing item's beat is met: its tail at `speed` after a `ramp` of song frames, and the blends up to
    /// `longest` on the beat, or on the bar.
    struct Sync {
        fileprivate let speed: Double
        fileprivate let ramp: Double
        fileprivate let longest: Double
        fileprivate let beats: Lengths
        /// The bar lengths, and the incoming item's first downbeat, which they reach.
        fileprivate let bars: (lengths: Lengths, first: Double)?

        /// Meets the beat as is while the drift stays under `maxDrift`, else with the outgoing varispeeded to the
        /// incoming's period, folded to its own, should the speed be within `Varispeed.most` and its taps reach no
        /// further back than `reach`.
        fileprivate static func ways(out: Beats, next: Beats, end: Double, reach: Double, longest: Double, rate: Double) -> [Sync] {
            let period = fold(next.period, to: out.period)
            let (drift, speed) = (abs(1 / out.period - 1 / period), out.period / period)
            let asIs = Sync(out: out, next: next, end: end, speed: 1, ramp: 0, longest: min(longest, maxDrift / drift))
            guard abs(speed - 1) <= Varispeed.most else { return [asIs] }
            let bar = 4 * out.period
            let ramp = out.downbeat == nil ? rampSeconds * rate : max((rampSeconds * rate / bar).rounded(.up), 2) * bar
            return [asIs, Sync(out: out, next: next, end: end, speed: speed, ramp: ramp, longest: min(longest, (reach - ramp) / speed))]
        }

        init(out: Beats, next: Beats, end: Double, speed: Double, ramp: Double, longest: Double) {
            // An outgoing beat at `o` lies `(end - o) / speed` before the end once played at speed, so a blend that
            // long, plus `n`, lands one on it.
            func lengths(_ o: Double, _ n: Double, _ step: Double) -> Lengths {
                Lengths(at: (end - o) / speed + n, step: step / speed)
            }
            self.speed = speed
            self.ramp = ramp
            self.longest = longest
            beats = lengths(out.first, next.first, out.period)
            bars = out.downbeat.flatMap { o in next.downbeat.map { n in (lengths(o, n, 4 * out.period), n) } }
        }

        /// The blend no longer than the singing allows (`sung`) nearest `want`: on the bar where there are bars, a
        /// phrase of 4 or 8 by up to half a bar further, else on the beat; and whether on the bar.
        func pick(shortest: Double, sung: Double, want: Double) -> (length: Double, onBar: Bool)? {
            let longest = min(sung, self.longest)
            func nearest(_ lengths: Lengths, _ shortest: Double, phrase: Bool) -> Double? {
                func cost(_ length: Double) -> Double {
                    let phrased = phrase && phraseBars.contains((length / lengths.step).rounded())
                    return abs(length - want) - (phrased ? lengths.step / 2 : 0)
                }
                return lengths.within(shortest, longest).min { cost($0) < cost($1) }
            }
            // Reaching the incoming item's first downbeat, so a bar really meets.
            if let (bars, first) = bars, let length = nearest(bars, max(shortest, first), phrase: true) {
                return (length, true)
            }
            return nearest(beats, shortest, phrase: false).map { ($0, false) }
        }

        /// Where the tail's varispeed starts for a blend of `length`, and its curve.
        fileprivate func warp(end: Double, length: Double) -> Warp? {
            guard ramp > 0 else { return nil }
            let curve = Varispeed(ramp: (ramp * 2 / (1 + speed)).rounded(), speed: speed)
            let start = end - speed * length - curve.songFrames(curve.ramp)
            return (Int(max(start.rounded(), 0)), curve)
        }
    }

    /// Blends over the outgoing's fade-out or the incoming's build within `room` frames, on the bar or beat where both
    /// have one, else echoed out, swept or blended, short of where their singing meets.
    static func plan(tail: Analysis, intro: Analysis, rate: Double, room: Int, voices: Voices) -> Mix {
        let end = Double(tail.frames)
        var longest = min(maxSeconds * rate, end, Double(room))
        if Double(intro.frames) < introSeconds * rate {
            longest = min(longest, Double(intro.frames) / 2)
        }
        let shortest = min(minSeconds * rate, longest)
        let outro = tail.outro
        let want = min(max(outro, intro.build, shortest), longest)
        let sung = { (speed: Double) in voices.longest(speed: speed, rate: rate) ?? .infinity }
        let blend = { (length: Double) in Style.blend(trade: tail.bass && intro.bass ? trade(intro, length, rate) : nil) }
        let both = tail.beats.flatMap { out in intro.beats.map { (out, $0) } }
        let synced = both.flatMap { out, next in
            // The varispeed's taps reach back from its start, which must be yet to play.
            Sync.ways(
                out: out, next: next, end: end,
                reach: min(end, Double(room) - Double(Varispeed.reach)), longest: longest, rate: rate
            ).lazy.compactMap { way in way.pick(shortest: shortest, sung: sung(way.speed), want: want).map { (way, $0) } }.first
        }
        let (length, style, warp, how): (Double, Style, Warp?, String)
        if let (way, (found, onBar)) = synced {
            (length, style, warp, how) = (found, blend(found), way.warp(end: end, length: found), onBar ? "on the bar" : "on the beat")
        } else if let (found, beat) = tail.echo(longest: longest, outro: outro), found <= sung(1) {
            (length, style, warp, how) = (found, .echo(beat: Int(beat.rounded())), nil, "echoed out")
        } else if shortest <= sung(1) {
            let found = min(want, sung(1))
            (length, style, warp, how) = (found, both == nil ? blend(found) : .sweep(skew: false), nil, "not aligned")
        } else {
            (length, style, warp, how) = (shortest, .sweep(skew: true), nil, "sung over")
        }
        let bpm = { (beats: Beats?) in
            beats.map { (60 * rate / $0.period).formatted(.number.precision(.fractionLength(1))) + ($0.downbeat == nil ? "" : " in bars") } ?? "no"
        }
        Logger.audio.debug(
            "Automix: \(length / rate, format: .fixed(precision: 1)) s blend, \(bpm(tail.beats), privacy: .public) BPM into \(bpm(intro.beats), privacy: .public) BPM, \(how, privacy: .public), speed \(warp?.curve.speed ?? 1, format: .fixed(precision: 3))"
        )
        return Mix(frames: Int(length), warp: warp, style: style)
    }

    /// The bass trade over half a beat, ending on the incoming item's bar line nearest midway, or its beat.
    private static func trade(_ intro: Analysis, _ length: Double, _ rate: Double) -> (at: Int, length: Int) {
        var tradeLength = tradeSeconds * rate
        var tradeEnd = (length + tradeLength) / 2
        if let beats = intro.beats {
            let (first, step) = beats.downbeat.map { ($0, 4 * beats.period) } ?? (beats.first, beats.period)
            let k = max(((length / 2 - first) / step).rounded(), 0)
            (tradeLength, tradeEnd) = (beats.period / 2, first + k * step)
        }
        tradeLength = min(tradeLength, length)
        return (Int(min(max(tradeEnd - tradeLength, 0), length - tradeLength)), max(Int(tradeLength), 1))
    }

    /// `period` halved or doubled to within `to`'s range, as an item in double time still lands on every other beat.
    static func fold(_ period: Double, to: Double) -> Double {
        var period = period
        while period > to * 1.5 { period /= 2 }
        while period < to * 0.75 { period *= 2 }
        return period
    }

    /// From Double, as `Float.pi` rounds down where Rust's rounds to nearest.
    private static let quarterTurn = Float(Double.pi / 2)

    /// Equal-power curves in and out at `t` through a blend, keeping the loudness steady where linear ones dip
    /// midway.
    static func equalPower(_ t: Float) -> (rise: Float, fall: Float) {
        let angle = t * quarterTurn
        return (sin(angle), cos(angle))
    }

    /// Eased from 0 to 1, so a change neither clicks nor lingers.
    private static func ease(_ s: Float) -> Float {
        let s = min(max(s, 0), 1)
        return s * s * (3 - 2 * s)
    }

    /// A biquad's coefficients (RBJ's cookbook), Butterworth; b2 is b0 either way.
    private struct Coefficients {
        enum Pass {
            case low
            case high
        }

        let b0: Double
        let b1: Double
        let a1: Double
        let a2: Double

        init(_ pass: Pass, hz: Double, rate: Double) {
            let angle = 2 * .pi * hz / rate
            let (sine, cosine) = (sin(angle), cos(angle))
            let alpha = sine * 0.5.squareRoot()
            let a0 = 1 + alpha
            // b1 is twice b0, negated for a high-pass.
            let gain = pass == .low ? 1 - cosine : 1 + cosine
            b0 = gain / 2 / a0
            b1 = (pass == .low ? gain : -gain) / a0
            a1 = -2 * cosine / a0
            a2 = (1 - alpha) / a0
        }
    }

    /// Two biquads in series, 24 dB an octave, so as a high-pass at `bassHz` a kick an octave down is 24 dB under. In
    /// Double, as so low a corner is unsteady in Float. Retuning keeps the memory, so a sweep runs smoothly.
    private struct Cut {
        var coefficients: Coefficients
        /// Each stage's transposed direct form II memory.
        private var first = (0.0, 0.0)
        private var second = (0.0, 0.0)

        init(_ pass: Coefficients.Pass, hz: Double, rate: Double) {
            coefficients = Coefficients(pass, hz: hz, rate: rate)
        }

        mutating func run(_ input: Float) -> Float {
            let c = coefficients
            func stage(_ x: Double, _ z: inout (Double, Double)) -> Double {
                let y = c.b0 * x + z.0
                z = (c.b1 * x - c.a1 * y + z.1, c.b0 * x - c.a2 * y)
                return y
            }
            let output = stage(stage(Double(input), &first), &second)
            // On the memory, as a high-pass's output nears 0 under a steady input while its memory doesn't.
            if max(abs(first.0), abs(first.1), abs(second.0), abs(second.1)) < Double(denormal) {
                (first, second) = ((0, 0), (0, 0))
            }
            return Float(output)
        }
    }

    /// Mixes a blend in its style. A class, so its filters and echoes carry on from one buffer to the next.
    final class Mixer {
        private var state: State

        init(frames: Int, style: Style, rate: Double) {
            let beat = if case .echo(let beat) = style { max(beat, 1) } else { 0 }
            let line = UnsafeMutableBufferPointer<Float>.allocate(capacity: 2 * beat)
            line.initialize(repeating: 0)
            state = State(frames: frames, style: style, rate: rate, beat: beat, line: line)
        }

        deinit {
            state.line.deallocate()
        }

        /// Mixes `count` frames from the blend's frame `position` into `out` from `offset`, which is also each side's
        /// frame of its gain ramp. A nil side has ended and is silence, though an echo rings on.
        func mix(
            incoming: Crossfade.Channels?,
            outgoing: Crossfade.Channels?,
            gains: (incoming: Crossfade.Ramp, outgoing: Crossfade.Ramp),
            count: Int,
            at position: Int,
            into out: UnsafePointer<UnsafeMutablePointer<Float>>,
            offset: Int
        ) {
            // A local copy, so the loop's filter state needs no exclusivity checks.
            var state = state
            defer { self.state = state }
            for frame in 0..<count {
                let new = incoming.map { Pair($0.left[frame], $0.right[frame]) } ?? .zero
                let old = outgoing.map { Pair($0.left[frame], $0.right[frame]) } ?? .zero
                let (heard, fading) = state.mix(new, old, at: position + frame)
                let sum = heard * gains.incoming.at(offset + frame) + fading * gains.outgoing.at(offset + frame)
                out[0][offset + frame] = sum.x
                out[1][offset + frame] = sum.y
            }
        }

        /// A frame's two channels, so each sum and gain is one expression for both.
        private typealias Pair = SIMD2<Float>

        /// Each style's filters, a channel each: the incoming item's bass cut or high-pass, the outgoing's bass cut or
        /// low-pass, and the echo's damping.
        private struct State {
            let frames: Int
            let style: Style
            let rate: Double
            /// `1 / frames`, so a frame's place in the blend is a multiply.
            let step: Float
            /// Where the outgoing item's bass cut starts, so it has settled by the trade.
            let warm: Int
            /// Frames the beat sent to the echo fades in and out over, so its repeats don't click.
            let edge: Float
            /// The echo's beat, which `line` holds interleaved.
            let beat: Int
            /// The echo's delay line, a beat long; empty for other styles. The mixer frees it.
            let line: UnsafeMutableBufferPointer<Float>
            var incoming: (Cut, Cut)
            var outgoing: (Cut, Cut)
            var damp: ((Lows, Lows), (Lows, Lows))

            init(frames: Int, style: Style, rate: Double, beat: Int, line: UnsafeMutableBufferPointer<Float>) {
                self.frames = frames
                self.style = style
                self.rate = rate
                self.beat = beat
                self.line = line
                step = 1 / Float(max(frames, 1))
                let (newPass, newHz, oldPass, oldHz): (Coefficients.Pass, Double, Coefficients.Pass, Double)
                switch style {
                case .sweep: (newPass, newHz, oldPass, oldHz) = (.high, sweepFromHz, .low, Automix.open(rate))
                case .blend, .echo: (newPass, newHz, oldPass, oldHz) = (.high, bassHz, .high, bassHz)
                }
                let (new, old) = (Cut(newPass, hz: newHz, rate: rate), Cut(oldPass, hz: oldHz, rate: rate))
                (incoming, outgoing) = ((new, new), (old, old))
                warm = if case .blend(let trade?) = style { max(trade.at - Int(warmSeconds * rate), 0) } else { 0 }
                edge = max(Float(edgeSeconds * rate), 1)
                let echo = (Lows(hz: echoLowHz, rate: rate), Lows(hz: echoHighHz, rate: rate))
                damp = (echo, echo)
            }

            /// The incoming item's sample faded in and the outgoing's faded out, at the blend's frame `frame`.
            mutating func mix(_ new: Pair, _ old: Pair, at frame: Int) -> (Pair, Pair) {
                let t = Float(frame) * step
                switch style {
                case .blend(let trade):
                    let fade = equalPower(t)
                    var (new, old) = (new, old)
                    if let trade {
                        let s = ease(Float(max(frame - trade.at, 0)) / Float(trade.length))
                        // Once traded, the incoming's cut is never heard again, nor the outgoing's before the trade.
                        if frame < trade.at + trade.length {
                            let cut = Self.run(&incoming, new)
                            new = cut + (new - cut) * s
                        }
                        if frame >= warm {
                            let cut = Self.run(&outgoing, old)
                            old = old + (cut - old) * s
                        }
                    }
                    return (new * fade.rise, old * fade.fall)
                case .sweep(let skewed):
                    return sweep(new, old, at: frame, t, skewed: skewed)
                case .echo:
                    return echo(new, old, at: frame)
                }
            }

            /// The outgoing item's low-pass falls from open as the incoming's high-pass opens. Each starts or ends
            /// dry, where its filter is open, so nothing steps, and the incoming ends whole.
            private mutating func sweep(_ new: Pair, _ old: Pair, at frame: Int, _ t: Float, skewed: Bool) -> (Pair, Pair) {
                // Once open, the incoming's high-pass is never run again, nor the outgoing's low-pass once a skewed
                // fade has it out.
                let opening = t < openBy
                let fading = !skewed || t < skew
                // By the blend's frame, so a split buffer tunes as a whole one.
                if frame.isMultiple(of: retuneFrames) {
                    let glide = { (from: Double, to: Double, t: Float) in from * pow(to / from, Double(t)) }
                    if fading {
                        let low = Coefficients(.low, hz: glide(Automix.open(rate), sweepToHz, t), rate: rate)
                        (outgoing.0.coefficients, outgoing.1.coefficients) = (low, low)
                    }
                    if opening {
                        let high = Coefficients(.high, hz: glide(sweepFromHz, openedHz, t / openBy), rate: rate)
                        (incoming.0.coefficients, incoming.1.coefficients) = (high, high)
                    }
                }
                // Skewed, both curves run over the overlap alone, so the power holds.
                let fade = equalPower(skewed ? min(max((t - (1 - skew)) / (2 * skew - 1), 0), 1) : t)
                var new = new
                if opening {
                    let dry = ease((t - (openBy - filteredBy)) / filteredBy)
                    let high = Self.run(&incoming, new)
                    new = high + (new - high) * dry
                }
                let heard = new * fade.rise
                guard fading else { return (heard, .zero) }
                let filtered = ease(t / filteredBy)
                let low = Self.run(&outgoing, old)
                return (heard, (old + (low - old) * filtered) * fade.fall)
            }

            /// The outgoing item's first beat fades as the incoming comes in, and repeats a beat apart, each echo
            /// darker and thinner, rung out by the end. Only the first beat fades and is sent, and only the last
            /// rings out; a blend of a beat does both.
            private mutating func echo(_ new: Pair, _ old: Pair, at frame: Int) -> (Pair, Pair) {
                var (fadeIn, dry, send): (Float, Float, Float) = (1, 0, 0)
                if frame < beat {
                    (fadeIn, dry) = equalPower(Float(frame) / Float(beat))
                    send = ease(Float(frame + 1) / edge) * ease(Float(beat - frame) / edge)
                }
                let left = max(frames - frame, 0)
                let ring = left < beat ? sin(Float(left) / Float(beat) * quarterTurn) : 1
                let at = frame % beat * 2
                let echoed = Pair(line[at], line[at + 1])
                func repeated(_ old: Float, _ echo: Float, _ damp: inout (Lows, Lows)) -> Float {
                    let fed = damp.0.run(old * send + feedback * echo)
                    return fed - damp.1.run(fed)
                }
                (line[at], line[at + 1]) = (repeated(old.x, echoed.x, &damp.0), repeated(old.y, echoed.y, &damp.1))
                return (new * fadeIn, old * dry + echoed * ring)
            }

            /// Each channel through its own filter.
            private static func run(_ cuts: inout (Cut, Cut), _ x: Pair) -> Pair {
                Pair(cuts.0.run(x.x), cuts.1.run(x.y))
            }
        }
    }

    /// The corner a low-pass is open at, short of Nyquist.
    private static func open(_ rate: Double) -> Double {
        min(openHz, 0.45 * rate)
    }
}

/// Apart, so the memberwise init stays.
extension Automix.Voices {
    /// From `sung`, for a tail ending at `tailEnd` and an intro starting at `introStart`, in song seconds. No spans, or
    /// none past the intro's start, is as good as unknown.
    init(_ sung: Sung, tailEnd: Double, introStart: Double, rate: Double) {
        last = sung.current?.map(\.upperBound).max().map { max((tailEnd - $0) * rate, 0) }
        first = sung.next?.filter { $0.upperBound > introStart }.map(\.lowerBound).min().map { max(($0 - introStart) * rate, 0) }
    }
}
