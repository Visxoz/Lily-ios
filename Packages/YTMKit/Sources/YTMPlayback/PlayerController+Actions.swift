import Foundation
import os
import YTMCore

/// Starting playback from pages, cards and menus, and the radios that carry a queue on.
extension PlayerController {
    /// Plays from `index`, or with nil from a random track when shuffling and the
    /// first when not. `shuffle`, as a Shuffle button, turns shuffle on first.
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

    /// The whole section from `index`, or for a `.radio` section the song with a radio after it.
    public func play(_ section: TrackSection, at index: Int) {
        guard section.tracks.indices.contains(index) else { return }
        switch section.mode {
        case .section: play(section.tracks, startAt: index)
        case .radio: startRadio(from: section.tracks[index])
        }
    }

    /// Returns once the songs have started, or failed to. With shuffle on, the
    /// whole playlist loads first, so the first song can be any of it. A downloaded
    /// album or playlist plays from the phone when YouTube can't load it.
    public func play(_ card: Card) async {
        let local = card.route.flatMap(downloads.page(for:))
        switch card.kind {
        case .song:
            if let track = card.track { startRadio(from: track) }
        case .playlist where settings.value.shuffle == .off:
            let music = music
            await load({
                do { return try await music.page(.playlist(card.id)) } catch { if let local { return local } else { throw error } }
            }, failure: "Couldn't load") { player, page in
                player.play(page.headerTracks)
                player.continuePlaylist(page)
            }
        case .album, .playlist, .artist:
            let music = music
            await load({
                do { return try await music.tracks(of: card) } catch { if let local { return local.headerTracks } else { throw error } }
            }, failure: "Couldn't load") { $0.play($1) }
        case .genre:
            break
        }
    }

    public func startRadio(from card: Card) async {
        switch card.kind {
        case .playlist:
            await startRadio(playlistId: YTMusic.radioId(forPlaylist: card.id))
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

    /// Unshuffled Play starts the page's tracks at once and adds the rest of the
    /// playlist as it arrives; Shuffle, or Play with shuffle on, first loads the whole playlist.
    public func play(_ page: Page, shuffle: Bool = false) async {
        let tracks = page.headerTracks
        let unfinished: String? = if case .tracks? = page.more { page.header?.playlistId } else { nil }
        if !shuffle, settings.value.shuffle == .off, unfinished != nil {
            // The rest follows from where the page has got to, without asking
            // again for the batches it shows.
            play(tracks)
            continuePlaylist(page)
            return
        }
        guard let playlist = (shuffle ? page.header?.shufflePlaylistId : nil) ?? unfinished else {
            play(tracks, shuffle: shuffle)
            return
        }
        let music = music
        // Failing that, the page's own tracks play.
        await load({ (try? await music.playlistTracks(playlist)) ?? [] }, failure: "Couldn't load") { player, found in
            player.play(found.isEmpty ? tracks : found, shuffle: shuffle)
        }
    }

    /// An artist page's radio, or a playlist's from `YTMusic.radioId(forPlaylist:)`.
    public func startRadio(playlistId: String) async {
        let music = music
        await load({ try await music.radio(playlistId: playlistId) }, failure: "Couldn't start the radio") { $0.play($1) }
    }

    /// Plays `track` now and queues a radio based on it.
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

    /// Into an empty queue, they start playing.
    public func playNext(_ tracks: [Track]) {
        insert(tracks, next: true)
    }

    /// Into an empty queue, they start playing.
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
            // is not for; one alone is an edit, or a skip, in the same queue.
            case .success where queue.revision != revision && playback.generation != generation:
                break
            case .success(let tracks):
                appendUnique(tracks)
            case .failure(let error):
                Logger.playback.warning("autoplay radio failed: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    /// Once each: a song's radio leaves out the song itself, but may repeat others.
    func appendUnique(_ tracks: [Track]) {
        var known = Set(queue.items.map(\.id))
        appendKeepingShuffle(tracks.filter { known.insert($0.id).inserted })
    }

    private func appendKeepingShuffle(_ tracks: [Track]) {
        queue.append(contentsOf: tracks)
        // Recommendations are taken out first, as they are placed again
        // where they are due.
        if settings.value.shuffle != .off {
            queue.removeRecommended()
            queue.setShuffle(false)
            queue.setShuffle(true)
        }
        prefetchNext()
    }

    /// Adds the rest of a long playlist as each batch arrives. Every track is
    /// kept, as a playlist may hold a song twice.
    func continuePlaylist(_ page: Page) {
        guard case .tracks? = page.more, !page.headerTracks.isEmpty else { return }
        let music = music
        // Its own task, so another queue, or clearing what is up next, drops
        // the batches still to come, and nothing else.
        continuing = Task { [weak self] in
            var page = page
            var shown = page.headerTracks.count
            while case .tracks? = page.more {
                guard let next = try? await music.loadMore(page), !Task.isCancelled, let self else { return }
                page = next
                let all = page.headerTracks
                guard all.count > shown else { continue }
                // Unshuffled before the batch goes on, so it follows the
                // playlist's own last song rather than the shuffle's.
                let shuffled = settings.value.shuffle != .off
                if shuffled {
                    queue.removeRecommended()
                    queue.setShuffle(false)
                }
                queue.append(contentsOf: all[shown...])
                if shuffled { queue.setShuffle(true) }
                prefetchNext()
                shown = all.count
            }
        }
    }

    /// Loads off the main actor, then plays unless something else was asked for meanwhile.
    private func load<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T, failure: String,
        then play: @escaping @MainActor (PlayerController, T) -> Void
    ) async {
        pendingPlay?.cancel()
        let task = Task { [weak self] in
            let result = await Result(work)
            guard let self, !Task.isCancelled else { return }
            pendingPlay = nil
            switch result {
            case .success(let value): play(self, value)
            case .failure(let error): say("\(failure): \(sentence(for: error))")
            }
        }
        pendingPlay = task
        await task.value
    }
}
