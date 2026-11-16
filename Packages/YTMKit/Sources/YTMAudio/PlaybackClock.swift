import AVFoundation
import Synchronization

/// Readable from the main actor at any time without waiting on the engine. Between pins it runs on with
/// the host clock, never past the sound scheduled, so a stall holds it still.
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

    /// From 0 to 1.
    var buffered: Double {
        state.withLock(\.buffered)
    }

    /// Runs on from host time `since` up to `limit`, or holds at `seconds` when `since` is nil.
    func pin(_ seconds: Double, since: UInt64?, limit: Double = .infinity) {
        state.withLock { state in
            state.seconds = seconds
            state.since = since
            state.limit = limit
        }
    }

    func hold() {
        let seconds = position()
        pin(seconds, since: nil)
    }

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
