import Foundation
import YTMCore

/// Only time played through counts towards a scrobble, so seeks and stalls
/// add nothing.
struct Scrobbler {
    private struct Listening {
        let track: Track
        let startedAt: Date
        var heard = 0.0
        var lastTick: (position: Double, at: ContinuousClock.Instant)?
    }

    private var playing: Listening?

    /// Forward by no more than `elapsed` allows, so a seek adds nothing while
    /// a delayed tick loses nothing, as the sound plays on its own thread.
    static func playedThrough(moved: Double, elapsed: Duration) -> Double {
        moved > 0 && moved <= (elapsed + PlayerController.tick).seconds ? moved : 0
    }

    /// Last.fm's rule: the song is over 30 seconds, and half of it or four
    /// minutes has played.
    static func counts(heard: Double, length: Double) -> Bool {
        length > 30 && heard >= min(length / 2, 240)
    }

    mutating func start(_ track: Track, at date: Date = .now) {
        playing = Listening(track: track, startedAt: date)
    }

    /// Returns the play once it counts, and only that once.
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
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
