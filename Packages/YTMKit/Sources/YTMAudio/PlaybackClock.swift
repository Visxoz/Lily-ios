import AVFoundation
import Synchronization

/// The play position, and the length and download of the item heard, kept
/// where the main actor can read them at any time without waiting on the
/// engine. The engine pins it to the player node's
/// render timeline as buffers play; between times it runs on with the host
/// clock, which the render timeline follows, and it never runs past the
/// sound scheduled, so a stall holds it still.
final class PlaybackClock: Sendable {
    private struct State {
        /// The position at `since`, or for good while it is not running.
        var seconds: Double = 0
        var since: UInt64?
        /// Where the scheduled sound of the item heard ends.
        var limit: Double = .infinity
        var duration: Double?
        var buffered: Double = 0
    }

    private let state = Mutex(State())

    func position(at hostTime: UInt64 = mach_absolute_time()) -> Double {
        state.withLock { state in
            guard let since = state.since, hostTime > since else { return state.seconds }
            let elapsed = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: since)
            return min(state.seconds + elapsed, max(state.limit, state.seconds))
        }
    }

    var duration: Double? {
        state.withLock(\.duration)
    }

    /// How much of the item heard has downloaded, from 0 to 1.
    var buffered: Double {
        state.withLock(\.buffered)
    }

    /// Pins the position: `seconds` at host time `since`, running on from
    /// there up to `limit`, or held at `seconds` when `since` is nil.
    func pin(_ seconds: Double, since: UInt64?, limit: Double = .infinity) {
        state.withLock { state in
            state.seconds = seconds
            state.since = since
            state.limit = limit
        }
    }

    /// Holds the position where it has got to.
    func hold() {
        let seconds = position()
        pin(seconds, since: nil)
    }

    /// Runs on from where it is held.
    func run() {
        let now = mach_absolute_time()
        state.withLock { state in
            if state.since == nil {
                state.since = now
            }
        }
    }

    func describe(duration: Double?, buffered: Double) {
        state.withLock { state in
            state.duration = duration
            state.buffered = buffered
        }
    }
}
