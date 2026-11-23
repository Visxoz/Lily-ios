import Foundation

/// Crossfeed, widening, mono and balance, in the sound unit after the equaliser, so a change is heard at
/// once. Each change ramps in, and while all are out the samples pass untouched.
struct Stereo {
    /// Bauer's bs2b default level: the other side's sound under about 700 Hz, fed in 4.5 dB under the direct
    /// side's.
    static let cutHz: Float = 700
    /// G / (1 - G) = 10^(-4.5 / 20), the feed's share of a side's lows.
    static let feed: Float = 0.373_3
    /// The share of the highs' difference widening moves each way: their side raised by half, 3.5 dB.
    static let widen: Float = 0.25
    /// How long a change takes, so turning one on or off never clicks.
    static let rampSeconds: Float = 0.05

    var crossfeed = false
    var widen = false
    var mono = false
    /// -1 is the left side alone, 1 the right.
    var balance: Float = 0
    /// How far each is in, moving towards the settings a step a frame; all 0 is idle.
    private var now: (feed: Float, widen: Float, mono: Float, balance: Float) = (0, 0, 0, 0)
    /// Each side low-passed, for crossfeed and widening.
    private var lows: (left: Float, right: Float) = (0, 0)
    /// The low-pass's coefficient, for `rate`.
    private var pole: Float = 0
    private var rate = 0.0

    mutating func reset() {
        lows = (0, 0)
    }

    mutating func process(_ left: UnsafeMutableBufferPointer<Float>, _ right: UnsafeMutableBufferPointer<Float>, rate: Double) {
        let target = (feed: Float(crossfeed ? 1 : 0), widen: Float(widen ? 1 : 0), mono: Float(mono ? 1 : 0), balance: balance)
        let ramping = now != target
        if rate == 0 || (!ramping && target == (0, 0, 0, 0)) {
            lows = (0, 0)
            return
        }
        if rate != self.rate {
            pole = 1 - exp(-2 * .pi * Self.cutHz / Float(rate))
            self.rate = rate
        }
        let step = 1 / (Self.rampSeconds * Float(rate))
        for frame in 0..<min(left.count, right.count) {
            // Settled, the usual case, skips the ramp.
            if ramping {
                now = (
                    Self.toward(now.feed, target.feed, by: step), Self.toward(now.widen, target.widen, by: step),
                    Self.toward(now.mono, target.mono, by: step), Self.toward(now.balance, target.balance, by: step)
                )
            }
            let (l, r) = (left[frame], right[frame])
            lows = (lows.left + pole * (l - lows.left), lows.right + pole * (r - lows.right))
            // Both sides move by the same amount, so a centred sound is kept: the lows across, the highs apart.
            var shift = now.feed * Self.feed * (lows.right - lows.left)
            shift += now.widen * Self.widen * ((l - lows.left) - (r - lows.right))
            let (fedL, fedR) = (l + shift, r - shift)
            shift = now.mono * 0.5 * (fedR - fedL)
            left[frame] = (fedL + shift) * (1 - max(now.balance, 0))
            right[frame] = (fedR - shift) * (1 + min(now.balance, 0))
        }
        lows = (lows.left.flushed, lows.right.flushed)
    }

    private static func toward(_ now: Float, _ target: Float, by step: Float) -> Float {
        now < target ? min(now + step, target) : max(now - step, target)
    }
}
