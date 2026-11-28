import Foundation
import os
import YTMCore

/// Starting playback from pages, cards and menus, and the radios that carry a queue on.
extension PlayerController {
    /// Plays from `index`, or with nil from a random track when shuffling and the first when not. `shuffle`, as a
    /// Shuffle button, turns shuffle on first. Answers whether anything played.
    @discardableResult
    public func play(_ tracks: [Track], startAt index: Int? = nil, shuffle: Bool = false) -> Bool {
        guard !tracks.isEmpty else {
            say("Nothing to play here")
            return false
        }
        // A song chosen plays though its artist is blocked.
        let (tracks, index) = tracks.removingSongs(by: settings.blocked, sparing: index)
        guard !tracks.isEmpty else {
            say("Every song here is by a blocked artist")
            return false
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
        return true
    }

    /// The whole section from `index`, or for a `.radio` section the song with a radio after it.
    public func play(_ section: TrackSection, at index: Int) {
        guard section.tracks.indices.contains(index) else { return }
        switch section.mode {
        case .section: play(section.tracks, startAt: index)
        case .radio: startRadio(from: section.tracks[index])
        }
    }

    /// Returns once the songs have started, or failed to. An album or playlist plays from its first page, from
    /// `page` when given (the app's cached copy), and the rest of a long playlist joins as it arrives; `whole` is
    /// given the playlist once every batch has. A downloaded album or playlist plays from the phone when YouTube
    /// can't load it.
    public func play(
        _ card: Card, page: (@MainActor @Sendable () async throws -> Page)? = nil,
        whole: (@MainActor @Sendable (Page) -> Void)? = nil
    ) async {
        let local = card.route.flatMap(downloads.page(for:))
        switch card.kind {
        case .song:
            if let track = card.track { startRadio(from: track) }
        case .album, .playlist:
            guard let route = card.route else { return }
            let music = music
            await load({
                do {
                    if let page { return try await page() }
                    return try await music.page(route)
                } catch {
                    if let local { return local } else { throw error }
                }
            }, failure: "Couldn't load") { player, found in
                if player.play(found.headerTracks) { player.continuePlaylist(found, whole: whole) }
            }
        case .artist:
            let music = music
            await load({ try await music.tracks(of: card) }, failure: "Couldn't load") { $0.play($1) }
        case .genre:
            break
        }
    }

    /// An album's radio starts from the first song of `page` when given, as `play(_:page:whole:)`.
    public func startRadio(from card: Card, page: (@MainActor @Sendable () async throws -> Page)? = nil) async {
        switch card.kind {
        case .playlist:
            await startRadio(playlistId: YTMusic.radioId(forPlaylist: card.id))
        case .song:
            if let track = card.track { startRadio(from: track) }
        case .album, .artist:
            let music = music
            await load({
                if card.kind == .album, let page { return try await page().headerTracks }
                return try await music.tracks(of: card)
            }, failure: "Couldn't load") { player, tracks in
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

    /// A partly loaded playlist plays from the page, shuffled with Shuffle, and adds the rest as it arrives; a
    /// whole page's Shuffle plays its shuffle playlist when it has one.
    public func play(_ page: Page, shuffle: Bool = false) async {
        let tracks = page.headerTracks
        if case .tracks? = page.more, page.header?.playlistId != nil {
            if play(tracks, shuffle: shuffle) { continuePlaylist(page) }
            return
        }
        guard shuffle, let playlist = page.header?.shufflePlaylistId else {
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
        // Shuffled, if on, so the radio is shuffled in as it arrives.
        replaceQueue(with: [track], start: 0, shuffle: settings.value.shuffle != .off)
        // Autoplay would otherwise ask for the same radio once this starts.
        playback.extending = true
        startCurrent()
        queueRadio(of: track.id, forAutoplay: false)
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
        queueRadio(of: seed, forAutoplay: true)
    }

    /// A song's radio that fails falls back on autoplay's. Another queue, or clearing what is up next, cancels it,
    /// so the radio joins only the queue it is for.
    private func queueRadio(of seed: String, forAutoplay: Bool) {
        playback.extending = true
        autoplayed = forAutoplay ? (seed, queue.nextId..<queue.nextId) : nil
        let music = music
        extending = Task { [weak self] in
            let result = await Result { try await music.radio(videoId: seed) }
            guard let self, !Task.isCancelled else { return }
            playback.extending = false
            switch result {
            case .success(let tracks):
                let first = queue.nextId
                appendUnique(tracks)
                // Unless another song started meanwhile.
                if forAutoplay, autoplayed?.seed == seed { autoplayed?.entries = first..<queue.nextId }
            case .failure(let error) where forAutoplay:
                Logger.playback.warning("autoplay radio failed: \(sentence(for: error), privacy: .public)")
            case .failure(let error):
                Logger.playback.warning("radio failed: \(sentence(for: error), privacy: .public)")
                extendWithRadioIfEnding()
            }
        }
    }

    /// Once each: a song's radio leaves out the song itself, but may repeat others.
    func appendUnique(_ tracks: [Track]) {
        var known = Set(queue.items.map(\.id))
        appendShuffledIn(tracks.filter { known.insert($0.id).inserted })
    }

    /// Leaves out blocked artists' songs. While shuffled, among the songs still to play, so one may now be next.
    private func appendShuffledIn(_ tracks: [Track]) {
        let tracks = tracks.leavingOut(settings.blocked)
        guard !tracks.isEmpty else { return }
        queue.extend(tracks)
        dropStaleNext()
        prefetchNext()
    }

    /// Adds the rest of a long playlist as each batch arrives, then gives `whole` the playlist unless a batch
    /// failed. Every track but blocked artists' is kept, as a playlist may hold a song twice.
    func continuePlaylist(_ page: Page, whole: (@MainActor @Sendable (Page) -> Void)? = nil) {
        guard case .tracks? = page.more, !page.headerTracks.isEmpty else { return }
        let music = music
        // Its own task, so another queue, or clearing what is up next, drops the batches still to come, and nothing
        // else.
        continuing = Task { [weak self] in
            var page = page
            var shown = page.headerTracks.count
            var complete = true
            while case .tracks? = page.more {
                guard let step = try? await music.loadStep(page), !Task.isCancelled, let self else { return }
                page = step.page
                complete = complete && step.whole
                let all = page.headerTracks
                guard all.count > shown else { continue }
                appendShuffledIn(Array(all[shown...]))
                shown = all.count
            }
            if complete { whole?(page) }
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
