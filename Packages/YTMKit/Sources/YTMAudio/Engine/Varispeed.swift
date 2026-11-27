import Foundation

/// Automix's varispeed: a speed ramping linearly from 1 to `speed` over `ramp` frames played, then held, so pitch
/// follows tempo as on a record.
struct Varispeed {
    let ramp: Double
    let speed: Double

    /// The most the outgoing item's tempo is changed to meet the incoming's.
    static let most = 0.06
    /// The interpolator's taps, 8 either side of the point read.
    private static let taps = 16
    /// How many frames before the point read its taps reach.
    static let reach = taps / 2 - 1
    /// Kernels tabulated between two frames and interpolated between, so no tap needs a sine.
    private static let phases = 64
    /// `phases + 1` Lanczos-windowed sincs, flattened, cut at Nyquist / (1 + most) so the fastest speed can't alias;
    /// each sums to 1, so no phase changes the level.
    private static let kernels: [Float] = {
        let cutoff = 1 / (1 + most)
        let half = Double(taps / 2)
        func sinc(_ x: Double) -> Double { x == 0 ? 1 : sin(.pi * x) / (.pi * x) }
        return (0...phases).flatMap { phase in
            let fraction = Double(phase) / Double(phases)
            let row = (0..<taps).map { j in
                let d = Double(j) - (half - 1) - fraction
                return sinc(cutoff * d) * sinc(d / half)
            }
            let sum = row.reduce(0, +)
            return row.map { Float($0 / sum) }
        }
    }()

    /// The song frames heard over the first `t` frames played.
    func songFrames(_ t: Double) -> Double {
        let r = min(t, ramp)
        // A ramp of 0 is at speed from the start, never 0 / 0.
        return r + (speed - 1) * r * r / (2 * max(ramp, 1)) + speed * (t - r)
    }

    /// Plays a decoder's frames from `origin` at the curve's speeds: the first `reach` as they are, so the taps
    /// after them reach frames decoded, then through the interpolator.
    final class Reader {
        private let curve: Varispeed
        /// Frames handed on so far, at the speeds played.
        private(set) var played = 0
        /// The decoder has ended; past its end reads silence.
        private(set) var inputEnded = false
        private let origin: Int64
        /// Decoded frames from `kept` on, held while taps still reach them.
        private var history: (left: [Float], right: [Float]) = ([], [])
        private var kept: Int64
        private let output: (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>)
        private var outputStart = 0
        private(set) var available = 0
        private static let capacity = 4_096

        init(curve: Varispeed, from origin: Int64) {
            self.curve = curve
            self.origin = origin
            kept = origin
            output = (.allocate(capacity: Self.capacity), .allocate(capacity: Self.capacity))
        }

        deinit {
            output.left.deallocate()
            output.right.deallocate()
        }

        /// The song frame output frame `frame` reads.
        private func point(_ frame: Int) -> Double {
            frame < reach ? Double(origin) + Double(frame) : Double(origin + Int64(reach)) + curve.songFrames(Double(frame - reach))
        }

        /// Frames still to hand on before the ramp reaches speed, the first `reach` included.
        var beforeSpeed: Int64 { Int64(reach) + Int64(curve.ramp) - Int64(played) }

        /// The song frame next to be handed on, which a varispeed left early carries on from.
        var position: Int64 { Int64(point(played).rounded()) }

        var channels: Crossfade.Channels {
            (UnsafePointer(output.left + outputStart), UnsafePointer(output.right + outputStart))
        }

        func consume(_ count: Int) {
            let count = min(count, available)
            outputStart += count
            available -= count
            played += count
        }

        func append(_ channels: Crossfade.Channels, count: Int) {
            history.left.append(contentsOf: UnsafeBufferPointer(start: channels.left, count: count))
            history.right.append(contentsOf: UnsafeBufferPointer(start: channels.right, count: count))
        }

        func endInput() {
            inputEnded = true
        }

        /// The frames ready, rendering more once they are all consumed; 0 when it needs more input.
        func render() -> Int {
            guard available == 0 else { return available }
            // Frees what no tap reaches any more.
            let needed = Int64(point(played).rounded(.down)) - Int64(reach)
            let drop = min(max(Int(needed - kept), 0), history.left.count)
            if drop > 0 {
                history.left.removeFirst(drop)
                history.right.removeFirst(drop)
                kept += Int64(drop)
            }
            let taps = Varispeed.taps
            let phases = Varispeed.phases
            var count = 0
            Varispeed.kernels.withUnsafeBufferPointer { table in
                history.left.withUnsafeBufferPointer { left in
                    history.right.withUnsafeBufferPointer { right in
                        let held = left.count
                        while count < Self.capacity {
                            let frame = played + count
                            let at = point(frame) - Double(kept)
                            let whole = Int(at.rounded(.down))
                            var sample: (Float, Float) = (0, 0)
                            if frame < reach {
                                guard whole < held else { return }
                                sample = (left[whole], right[whole])
                            } else {
                                let first = whole + 1 - taps / 2
                                guard first + taps <= held || inputEnded, first < held else { return }
                                let phase = (at - Double(whole)) * Double(phases)
                                let index = min(Int(phase), phases - 1)
                                let (row, weight) = (index * taps, Float(phase - Double(index)))
                                for j in 0..<min(held - first, taps) {
                                    let k = table[row + j] + weight * (table[row + taps + j] - table[row + j])
                                    sample.0 += k * left[first + j]
                                    sample.1 += k * right[first + j]
                                }
                            }
                            output.left[count] = sample.0
                            output.right[count] = sample.1
                            count += 1
                        }
                    }
                }
            }
            outputStart = 0
            available = count
            return count
        }
    }
}
