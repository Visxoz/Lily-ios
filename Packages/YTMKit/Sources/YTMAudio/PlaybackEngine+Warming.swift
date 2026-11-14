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

    /// The warm-up of the file `item` names, handed over to its download.
    func takeWarmed(_ item: AudioItem) -> Warmed? {
        guard let warmed, warmed.item.url == item.url, warmed.item.cacheKey == item.cacheKey else { return nil }
        self.warmed = nil
        return warmed
    }
}
