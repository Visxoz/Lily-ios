import Foundation

public enum SleepTimer: Equatable, Sendable {
    /// Pauses then.
    case at(Date)
    /// Stops as the song ends instead of moving on.
    case endOfSong
}

extension PlayerController {
    /// How late a timed sleep may wake and still pause.
    private static let sleepLateness = 5.0

    /// Nil turns it off.
    public func setSleepTimer(_ timer: SleepTimer?) {
        sleepWait?.cancel()
        sleepWait = nil
        sleepTimer = timer
        if case .at(let date) = timer {
            sleepWait = Task { [weak self] in
                try? await Task.sleep(for: .seconds(date.timeIntervalSinceNow), tolerance: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                sleepTimer = nil
                // Later means the app was suspended, so paused: a Play since is the user's.
                if isPlaying, date.timeIntervalSinceNow > -Self.sleepLateness { setPaused(true) }
                forgetInterruptionResume()
            }
        }
        // `updateGapless` then queues nothing, so the song ends with `.finished`.
        if timer == .endOfSong { dropQueuedNext() }
        // Stops or starts the lookups of where the songs are sung, as the next will or won't play.
        prefetchSung()
    }

    /// Moves on, or with the timer armed stops on the song, as at the queue's end.
    func songEnded() {
        guard sleepTimer == .endOfSong else { return next(user: false) }
        sleepTimer = nil
        stop()
    }
}
