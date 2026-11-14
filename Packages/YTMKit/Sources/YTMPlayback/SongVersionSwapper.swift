import Foundation
import os
import YTMCore

/// Plays music videos as their song versions, which are audio only and have
/// Premium formats, as ytm-native's `song_version.rs`. The next song is
/// looked up in the background while its stream is prefetched, and the song
/// is swapped in only once its own stream is ready, so nothing ever waits.
struct SongVersionSwapper {
    /// Most videos remembered; past it the cache starts over.
    static let limit = 256

    private enum Lookup {
        case pending
        case known(Track?)
    }

    /// Music videos looked up for a song version, by video ID.
    private var lookups: [String: Lookup] = [:]

    /// The song version found for `videoId`, if one was.
    func knownSong(for videoId: String) -> Track? {
        if case .known(let song?) = lookups[videoId] { song } else { nil }
    }

    /// Claims a lookup of `videoId` when it was never asked for; false when
    /// it is under way or done.
    mutating func beginLookup(_ videoId: String) -> Bool {
        guard lookups[videoId] == nil else { return false }
        if lookups.count >= Self.limit {
            lookups = lookups.filter { if case .pending = $0.value { true } else { false } }
        }
        lookups[videoId] = .pending
        return true
    }

    /// A failed lookup counts as none, so it is not retried per song.
    mutating func found(_ song: Track?, for videoId: String) {
        lookups[videoId] = .known(song)
    }
}

extension PlayerController {
    /// Starts swapping `next`, a music video, for its song version if it has
    /// one. Returns at once; the queue changes later.
    func swapInSongVersion(_ next: Track) {
        if let song = songVersions.knownSong(for: next.id) {
            prefetchSongVersion(of: next.id, song)
            return
        }
        guard songVersions.beginLookup(next.id) else { return }
        let music = music
        Task { [weak self] in
            let result = await Result { try await music.songVersion(of: next) }
            guard let self else { return }
            if case .failure(let error) = result {
                Logger.playback.debug("\(next.id, privacy: .public): could not look for a song version: \(sentence(for: error), privacy: .public)")
            }
            let song = try? result.get()
            songVersions.found(song, for: next.id)
            if let song { prefetchSongVersion(of: next.id, song) }
        }
    }

    /// Resolves the song's stream, then swaps the song in. Until then the
    /// queue keeps the video and its prefetched stream.
    private func prefetchSongVersion(of videoId: String, _ song: Track) {
        guard !prefetcher.isPending(song.id) else { return }
        if prefetcher.has(song.id) {
            putSongVersion(song, for: videoId)
            return
        }
        let task = prefetcher.begin(song.id, resolver(for: song.id))
        Task { [weak self] in
            let result = await task.result
            guard let self, prefetcher.finish(song.id, task) else { return }
            switch result {
            // Kept only once the song is in the queue, which the video may
            // have left, or started playing, meanwhile.
            case .success(let stream):
                if putSongVersion(song, for: videoId) {
                    prefetcher.store(song.id, .init(stream: stream, resolvedAt: .now))
                    warm(song, stream)
                }
            // Tried again at the next song start, not from here; until then
            // the video resolves as it is queued or starts.
            case .failure(let error):
                Logger.playback.debug("\(song.id, privacy: .public): the song version did not resolve: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    /// Puts `song` in place of the video `videoId` in the queue, unless the
    /// video is playing, and drops the video's prefetched stream. Returns
    /// whether it did.
    @discardableResult
    private func putSongVersion(_ song: Track, for videoId: String) -> Bool {
        guard current?.id != videoId, !queue.replace(where: { $0.id == videoId }, with: song).isEmpty else { return false }
        prefetcher.remove(videoId)
        Logger.playback.info("\(videoId, privacy: .public): playing its song version, \(song.id, privacy: .public)")
        return true
    }
}
