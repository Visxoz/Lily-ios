/// Fetching the start of the item likely to play next, as ytm-native's
/// `streams::warm` does once the next stream resolves: googlevideo's first
/// answer for a song seldom played can take over half a second, and later
/// ones under 100 ms, and the connection it opens is kept for the download.
/// Here the bytes go to the part file the item's download then carries on
/// from, so none is fetched twice.
extension PlaybackEngine {
    /// A warm-up: the item, and its download fetching the file's start.
    struct Warmed {
        let item: AudioItem
        let loader: StreamLoader
        let task: Task<Void, Never>
    }

    /// Warms `item` in place of the item warmed before. Nothing is fetched
    /// for one cached, opened already, or of unknown length.
    func warm(_ item: AudioItem) {
        guard item.contentLength > 0, warmed?.item.url != item.url,
              ![heard, producing, next].contains(where: { $0?.item.cacheKey == item.cacheKey }),
              cache.completeFile(for: item.cacheKey, length: item.contentLength) == nil,
              let loader = try? StreamLoader(item: item, cache: cache) else { return }
        warmed?.task.cancel()
        warmed = Warmed(item: item, loader: loader, task: Task { [self] in await loader.warm(source: source) })
    }

    /// Ends a next item the engine lets go, keeping its download as the
    /// warm-up, so reopening it, as a skip to it or a re-queue does, carries
    /// on from the bytes on disk. A warm-up already there, for the item now
    /// likely next, stays.
    func keepWarm(_ track: Track) {
        let task = track.download
        track.cancel()
        guard warmed == nil, let task, !track.loader.isComplete, track.failure == nil, track.item.contentLength > 0 else { return }
        warmed = Warmed(item: track.item, loader: track.loader, task: task)
    }

    /// The warm-up of the file `item` names, handed over to its download.
    func takeWarmed(_ item: AudioItem) -> Warmed? {
        guard let warmed, warmed.item.url == item.url, warmed.item.cacheKey == item.cacheKey else { return nil }
        self.warmed = nil
        return warmed
    }
}
