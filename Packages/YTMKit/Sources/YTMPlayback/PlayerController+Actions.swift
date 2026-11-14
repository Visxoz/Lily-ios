import Foundation
import os
import YTMCore

/// Starting playback from pages, cards and menus, as ytm-native's
/// `actions.rs`, and the radios that carry a queue on.
extension PlayerController {
    /// Replaces the queue with `tracks` and plays it from `index`, or with
    /// nil from a random track when shuffling and the first when not. With
    /// shuffle on, the tracks after the first are shuffled. `shuffle`, as a
    /// Shuffle button, turns shuffle on first; Play leaves it, and Smart
    /// Shuffle, as they are.
    public func play(_ tracks: [Track], startAt index: Int? = nil, shuffle: Bool = false) {
        guard !tracks.isEmpty else {
            say("Nothing to play here")
            return
        }
        if shuffle, settings.value.shuffle == .off {
            // The queue is replaced next, shuffled, so only the setting changes.
            settings.value.shuffle = .on
            applied?.shuffle = .on
        }
        let shuffling = settings.value.shuffle != .off
        let start = index ?? (shuffling ? queue.randomBelow(tracks.count) : 0)
        replaceQueue(with: tracks, start: start, shuffle: shuffling)
        startCurrent()
    }

    /// One track of a page's section tapped: the whole section from it, or
    /// for a section of separate songs (`QueueMode.radio`) the song with a
    /// radio after it.
    public func play(_ section: TrackSection, at index: Int) {
        guard section.tracks.indices.contains(index) else { return }
        switch section.mode {
        case .section: play(section.tracks, startAt: index)
        case .radio: startRadio(from: section.tracks[index])
        }
    }

    /// A card played: an album's, playlist's or artist's songs from the
    /// start, or a song card's song with a radio after it. Returns once the
    /// songs have loaded and started, or failed to.
    public func play(_ card: Card) async {
        switch card.kind {
        case .song:
            if let track = card.track { startRadio(from: track) }
        case .album, .playlist, .artist:
            let music = music
            await load({ try await music.tracks(of: card) }, failure: "Couldn't load") { $0.play($1) }
        case .genre:
            break
        }
    }

    /// A card's Start radio: a playlist's own radio, otherwise a radio of
    /// its first song.
    public func startRadio(from card: Card) async {
        switch card.kind {
        case .playlist:
            await startRadio(playlistId: "RDAMPL" + card.id)
        case .song:
            if let track = card.track { startRadio(from: track) }
        case .album, .artist:
            let music = music
            await load({ try await music.tracks(of: card) }, failure: "Couldn't load") { player, tracks in
                if let first = tracks.first {
                    player.startRadio(from: first)
                } else {
                    player.say("Nothing to play here")
                }
            }
        case .genre:
            break
        }
    }

    /// A page header's Play or Shuffle: the page's track list, or the whole
    /// playlist behind a page that shows only part of it, for Shuffle on an
    /// artist's songs and for a long playlist whose further tracks have yet
    /// to load.
    public func play(_ page: Page, shuffle: Bool = false) async {
        let tracks = page.headerTracks
        let unfinished: String? = if case .tracks? = page.more { page.header?.playlistId } else { nil }
        guard let playlist = (shuffle ? page.header?.shufflePlaylistId : nil) ?? unfinished else {
            play(tracks, shuffle: shuffle)
            return
        }
        let music = music
        // Failing that, the page's own tracks play, as ytm-native's do.
        await load({ (try? await music.playlistTracks(playlist)) ?? [] }, failure: "Couldn't load") { player, found in
            player.play(found.isEmpty ? tracks : found, shuffle: shuffle)
        }
    }

    /// Plays a radio by its playlist ID: an artist page's radio, or a
    /// playlist's (`"RDAMPL"` and its ID).
    public func startRadio(playlistId: String) async {
        let music = music
        await load({ try await music.radio(playlistId: playlistId) }, failure: "Couldn't start the radio") { $0.play($1) }
    }

    /// Plays `track` now and queues a radio based on it, as YouTube Music does.
    public func startRadio(from track: Track) {
        replaceQueue(with: [track], start: 0, shuffle: false)
        // Autoplay would otherwise ask for the same radio once this starts.
        playback.extending = true
        startCurrent()
        let music = music
        extending = Task { [weak self] in
            let result = await Result { try await music.radio(videoId: track.id) }
            guard let self, !Task.isCancelled else { return }
            playback.extending = false
            switch result {
            case .success(let tracks):
                if queue.item(at: 0)?.id == track.id { appendUnique(tracks) }
            case .failure(let error):
                Logger.playback.warning("radio failed: \(sentence(for: error), privacy: .public)")
                extendWithRadioIfEnding()
            }
        }
    }

    /// Puts `tracks` right after the song playing, in their order; into an
    /// empty queue, they start playing.
    public func playNext(_ tracks: [Track]) {
        insert(tracks, next: true)
    }

    /// Adds `tracks` to the end of the queue; into an empty queue, they
    /// start playing.
    public func addToQueue(_ tracks: [Track]) {
        insert(tracks, next: false)
    }

    private func insert(_ tracks: [Track], next: Bool) {
        guard let first = tracks.first else { return }
        if queue.isEmpty {
            queue.append(contentsOf: tracks)
            startCurrent()
            return
        }
        if next {
            for track in tracks.reversed() { queue.playNext(track) }
        } else {
            queue.append(contentsOf: tracks)
        }
        queueEdited()
        let what = tracks.count == 1 ? "“\(first.title)”" : Formatting.songs(tracks.count)
        say(next ? "\(what) \(tracks.count == 1 ? "plays" : "play") next" : "Added \(what) to the queue")
    }

    /// Queues a radio when the last song starts, so playback carries on.
    func extendWithRadioIfEnding() {
        guard settings.value.autoplay, repeatMode == .off, queue.peekNext(repeat: repeatMode) == nil,
              !playback.extending, let seed = queue.current?.id else { return }
        let (revision, generation) = (queue.revision, playback.generation)
        playback.extending = true
        let music = music
        extending = Task { [weak self] in
            let result = await Result { try await music.radio(videoId: seed) }
            guard let self, !Task.isCancelled else { return }
            playback.extending = false
            switch result {
            // Both changing means another queue was started, which the radio
            // is not for; should that one end, `next` asks again. One alone
            // is an edit, or a skip, in the same queue.
            case .success where queue.revision != revision && playback.generation != generation:
                break
            case .success(let tracks):
                appendUnique(tracks)
            case .failure(let error):
                Logger.playback.warning("autoplay radio failed: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    /// Adds the tracks the queue lacks, once each, as ytm-native's
    /// `append_unique`: a song's radio leaves out the song itself, but may
    /// repeat others.
    func appendUnique(_ tracks: [Track]) {
        var known = Set(queue.items.map(\.id))
        queue.append(contentsOf: tracks.filter { known.insert($0.id).inserted })
        // Keeps the new tracks in the shuffle. Recommendations are taken out
        // first, as they are placed again where they are due.
        if settings.value.shuffle != .off {
            queue.removeRecommended()
            queue.setShuffle(false)
            queue.setShuffle(true)
        }
        prefetchNext()
    }

    /// Loads what to play off the main actor, then plays it, unless something
    /// else was asked for meanwhile; says `failure` and why when it can't.
    private func load(
        _ work: @escaping @Sendable () async throws -> [Track], failure: String,
        then play: @escaping @MainActor (PlayerController, [Track]) -> Void
    ) async {
        pendingPlay?.cancel()
        let task = Task { [weak self] in
            let result = await Result(work)
            guard let self, !Task.isCancelled else { return }
            pendingPlay = nil
            switch result {
            case .success(let tracks): play(self, tracks)
            case .failure(let error): say("\(failure): \(sentence(for: error))")
            }
        }
        pendingPlay = task
        await task.value
    }
}
