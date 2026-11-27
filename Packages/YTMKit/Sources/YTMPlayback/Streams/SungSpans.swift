import Foundation
import os
import YTMAudio
import YTMCore

/// Where songs are sung, by their timed lyrics, so Automix keeps two songs' voices apart.
struct SungSpans {
    /// Songs kept; past it only the current and next stay.
    private static let limit = 8

    /// Nil while asking, untimed or failed.
    private var known: [String: [Range<Double>]?] = [:]
    /// The lookups in flight, by song.
    private var fetching: [String: Task<Void, Never>] = [:]

    /// Found, or being asked.
    func isAsked(_ id: String) -> Bool {
        known[id] != nil
    }

    /// Nil where unknown.
    func spans(of id: String) -> [Range<Double>]? {
        known[id] ?? nil
    }

    /// Cancels the lookups of songs not wanted, which are asked afresh should they come back; past the limit, forgets
    /// all but those wanted.
    mutating func keep(_ wanted: Set<String>) {
        for (id, task) in fetching where !wanted.contains(id) {
            task.cancel()
            fetching[id] = nil
            known[id] = nil
        }
        if known.count >= Self.limit { known = known.filter { wanted.contains($0.key) } }
    }

    mutating func begin(_ id: String, _ lookup: Task<Void, Never>) {
        // `.some`, as nil assigned through the subscript would remove the entry.
        known[id] = .some(nil)
        fetching[id] = lookup
    }

    mutating func found(_ spans: [Range<Double>]?, for id: String) {
        known[id] = .some(spans)
        fetching[id] = nil
    }
}

extension PlayerController {
    /// Looks up where the current and next songs are sung while the next would come in by Automix: by the lyrics
    /// shown, where they have come, else by YouTube's.
    func prefetchSung() {
        let next = queue.peekNext(repeat: repeatMode)
        let playing = [queue.current, next].compactMap(\.self)
        // "End of song" never plays the next.
        let automix = sleepTimer != .endOfSong
            && GaplessScheduler.transition(settings.value.transition, from: queue.current, to: next) == .automix
        gapless.sung.keep(automix ? Set(playing.map(\.id)) : [])
        // Not before the first sound, which fetches the next song's lyrics ahead first.
        guard playback.started, automix else { return }
        // Lyrics on their way call this again as they land, so the song isn't asked for twice.
        for track in playing where !awaitsSongVersion(track) && !gapless.sung.isAsked(track.id) && !loadingLyrics(of: track.id) {
            let id = track.id
            if let kept = lyricsCache[id] {
                // Copied, as the lyrics cache may be emptied before the song is queued.
                gapless.sung.found(kept?.sung, for: id)
                continue
            }
            let music = music
            let lookup = Task { [weak self] in
                let result = await Result { try await music.sung(videoId: id) }
                guard let self, !Task.isCancelled else { return }
                if case .failure(let error) = result {
                    Logger.playback.debug("\(id, privacy: .public): could not find where it is sung: \(sentence(for: error), privacy: .public)")
                }
                // A failure is kept as no spans, so queue edits offline don't ask again.
                gapless.sung.found(try? result.get(), for: id)
            }
            gapless.sung.begin(id, lookup)
        }
    }

    /// Where the current and next songs are sung, for Automix alone; by the lyrics shown first, as they may have come
    /// since.
    func sung(for transition: Transition, next id: String) -> Sung {
        guard transition == .automix else { return Sung() }
        let spans = { (id: String) in self.lyricsCache[id].flatMap { $0?.sung } ?? self.gapless.sung.spans(of: id) }
        return Sung(current: queue.current.flatMap { spans($0.id) }, next: spans(id))
    }

    /// A video next while its song version, asked for in its place, is still being looked for or resolved.
    private func awaitsSongVersion(_ track: Track) -> Bool {
        guard track.isVideo, track.id != queue.current?.id, localStream(track.id) == nil else { return false }
        return songVersions.isLooking(for: track.id) || songVersions.knownSong(for: track.id).map { prefetcher.isPending($0.id) } == true
    }

    private func loadingLyrics(of id: String) -> Bool {
        lyricsAhead.contains(id) || (lyricsFor == id && lyrics == .loading)
    }
}
