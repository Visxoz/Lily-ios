import os
import YTMCore

/// Block AI music's list: loaded at start and as the switch goes on, then again as the app comes back once it is due.
/// Not on a timer, which would wake the phone and network for nothing.
extension PlayerController {
    /// App active: loads the list again once a day has passed, or sooner after a failure.
    public func refreshAIArtistsIfDue() {
        guard let due = aiArtistsDue, due <= .now else { return }
        loadAIArtists(asked: false)
    }

    /// Off forgets the list, and nothing is read or fetched until it is back on.
    func blockAIChanged(to on: Bool) {
        aiArtistsPurgeOwed = on
        guard !on else {
            loadAIArtists(asked: true)
            return
        }
        aiArtistsLoad?.cancel()
        settings.listed = nil
        aiArtistsFailures = 0
        aiArtistsDue = nil
    }

    /// `asked`, from the switch, tells the user should it fail, as they are waiting. A stale copy is used at once,
    /// then fetched afresh once `ready` returns.
    func loadAIArtists(asked: Bool, after ready: @escaping @Sendable () async -> Void = {}) {
        guard settings.value.blockAI else { return }
        aiArtistsLoad?.cancel()
        aiArtistsDue = nil
        aiArtistsLoad = Task { [weak self, held = settings.listed != nil, store] in
            var (held, asked) = (held, asked)
            while true {
                let result = await Result { [held] in try await AIArtists.load(held: held, store: store, after: ready) }
                // A load already done when cancelled still gets here.
                guard let self, !Task.isCancelled, settings.value.blockAI else { return }
                switch result {
                case .success(let loaded):
                    // First, so Smart Shuffle's top-up after the purge honours it.
                    settings.listed = loaded.listed
                    // Only once the switch has gone on: launch and daily loads leave the queue as it is.
                    if aiArtistsPurgeOwed {
                        aiArtistsPurgeOwed = false
                        leaveOut(listed: loaded.listed)
                    }
                    aiArtistsFailures = 0
                    // Never zero once held, so this ends; left nil meanwhile, so a refresh doesn't restart the fetch.
                    guard loaded.due == .zero else {
                        aiArtistsDue = .now + loaded.due
                        return
                    }
                    (held, asked) = (true, false)
                case .failure(let error):
                    Logger.playback.warning("could not load the AI artists list: \(sentence(for: error), privacy: .public)")
                    if asked { say("Couldn't get the AI music list. It will be tried again.") }
                    aiArtistsDue = .now + Self.aiArtistsRetry(after: aiArtistsFailures)
                    aiArtistsFailures += 1
                    return
                }
            }
        }
    }

    /// By the list alone, sparing the song playing, unlike blocking an artist, which skips it.
    func leaveOut(listed: ListedArtists) {
        let blocked = Blocked(listed: listed)
        removeEntries { blocked.has($0.item) }
        downloads.leaveOut(blocked)
    }

    /// 15 minutes after a failure, doubling for each in a row, up to a day.
    static func aiArtistsRetry(after failures: Int) -> Duration {
        min(.seconds(15 * 60) * (1 << min(failures, 7)), AIArtists.freshFor)
    }
}
