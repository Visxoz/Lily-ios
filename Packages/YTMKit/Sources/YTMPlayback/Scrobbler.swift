import Foundation
import YTMCore

/// Decides when a song has been heard enough to scrobble, as ytm-native's
/// `scrobble.rs`: only time played through counts, so seeks and stalls add
/// nothing.
struct Scrobbler {
    /// The song playing, until enough of it has been heard to count.
    private struct Listening {
        let track: Track
        let startedAt: Date
        var heard = 0.0
        /// The position at the last tick, and when that was.
        var lastTick: (position: Double, at: ContinuousClock.Instant)?
    }

    private var playing: Listening?

    /// What a tick adds to the time heard, the position having `moved`
    /// seconds in the `elapsed` since the last: forward by no more than that
    /// time allows, so a seek adds nothing, while a tick held up (the main
    /// actor busy, say) loses nothing, as the sound plays on its own thread.
    static func playedThrough(moved: Double, elapsed: Duration) -> Double {
        moved > 0 && moved <= (elapsed + PlayerController.tick).seconds ? moved : 0
    }

    /// Whether a play heard for `heard` seconds of a song `length` long
    /// counts, as Last.fm's rules: the song is over 30 seconds, and half of
    /// it or four minutes has played.
    static func counts(heard: Double, length: Double) -> Bool {
        length > 30 && heard >= min(length / 2, 240)
    }

    /// Starts counting `track`, whose sound just started.
    mutating func start(_ track: Track, at date: Date = .now) {
        playing = Listening(track: track, startedAt: date)
    }

    /// Counts what was heard since the last tick, now at `position` of a
    /// song `length` long; returns the play once it counts, which is then
    /// counted no more.
    mutating func heard(position: Double, length: Double, at now: ContinuousClock.Instant = .now) -> (track: Track, startedAt: Date)? {
        guard var listening = playing else { return nil }
        if let last = listening.lastTick {
            listening.heard += Self.playedThrough(moved: position - last.position, elapsed: now - last.at)
        }
        listening.lastTick = (position, now)
        guard Self.counts(heard: listening.heard, length: length) else {
            playing = listening
            return nil
        }
        playing = nil
        return (listening.track, listening.startedAt)
    }
}

extension Duration {
    /// In seconds, as a `Double`.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
