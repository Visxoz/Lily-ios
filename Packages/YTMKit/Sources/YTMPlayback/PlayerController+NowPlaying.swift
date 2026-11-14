import Foundation
import os
import YTMCore

/// What shows the playing song, as ytm-native's `now_playing.rs` and
/// `library.rs`: the song and its stream, its lyrics, its rating, and the
/// system's Now Playing.
extension PlayerController {
    /// Likes or dislikes the song `videoId` (the one playing for nil), or
    /// takes that back if the playing song already had it; `.none` takes back
    /// either. Disliking the playing song skips it. Signed in only.
    public func rate(_ rating: Rating, videoId: String? = nil) {
        guard let id = videoId ?? current?.id else { return }
        let playing = id == current?.id
        let before = playing ? self.rating : .none
        let rating = rating == before ? .none : rating
        if playing {
            ratingGeneration += 1
            self.rating = rating
            if rating == .dislike {
                next(user: true)
                // Nothing to skip to: the queue's end, or a repeat of it.
                if current?.id == id { stop() }
            }
        }
        let music = music
        Task { [weak self] in
            let result = await Result { try await music.rate(videoId: id, rating) }
            guard let self else { return }
            switch result {
            case .success:
                libraryRevision += 1
                let message = switch (rating, before) {
                case (.like, _): "Added to your liked songs"
                case (.dislike, _): "Disliked"
                case (.none, .dislike): "Dislike removed"
                case (.none, .none): "Rating removed"
                case (.none, .like): "Removed from your liked songs"
                }
                say(message)
            case .failure(let error):
                // Undone on the player, unless it has moved on.
                if current?.id == id, self.rating == rating { self.rating = before }
                say("Couldn't rate the song: \(sentence(for: error))")
            }
        }
    }

    /// Shows `track` as the one playing, at `position`: Now Playing, the
    /// saved session, and for a new song (not one shown again, as on repeat
    /// or a retry) its rating and lyrics afresh.
    func present(_ track: Track, at position: Double) {
        let newSong = current?.id != track.id
        current = track
        duration = playback.duration
        playback.heldPosition = position
        isPlaying = true
        nowPlaying?.show(track, duration: duration)
        persistSoon()
        if newSong {
            loadRating(of: track.id)
            lyricsLoad?.cancel()
            lyricsFor = nil
            lyrics = .idle
        }
        if showsLyrics { loadLyrics() }
    }

    /// Shows the stream's quality, and fills in a length the song lacked.
    func show(_ stream: ResolvedStream) {
        self.stream = stream
        playback.currentPremium = stream.isPremium
        if playback.duration <= 0, let length = stream.duration {
            playback.duration = length
            duration = length
            nowPlaying?.setDuration(length)
        }
    }

    /// Loads the playing song's lyrics, unless they are shown or loading.
    func loadLyrics() {
        guard let id = current?.id else {
            lyrics = .idle
            return
        }
        guard lyricsFor != id else { return }
        lyricsFor = id
        lyrics = .loading
        lyricsLoad?.cancel()
        let music = music
        lyricsLoad = Task { [weak self] in
            let result = await Result { try await music.lyrics(videoId: id) }
            guard let self, !Task.isCancelled, lyricsFor == id else { return }
            switch result {
            case .success(let found?): lyrics = .loaded(found)
            case .success(nil): lyrics = .unavailable
            case .failure(let error):
                // Asked again when next shown.
                lyricsFor = nil
                lyrics = .failed("Couldn't load lyrics: \(sentence(for: error))")
            }
        }
    }

    /// Shows how the account rated `id`, the playing song, once YouTube says.
    func loadRating(of id: String) {
        ratingGeneration += 1
        rating = .none
        ratingLoad?.cancel()
        guard signedIn else { return }
        let generation = ratingGeneration
        let music = music
        ratingLoad = Task { [weak self] in
            let result = await Result { try await music.rating(videoId: id) }
            guard let self, ratingGeneration == generation else { return }
            switch result {
            case .success(let found): rating = found
            case .failure(let error): Logger.playback.debug("could not load the song's rating: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    /// Shows what the Premium path has found of the account, and remembers a
    /// firm answer across launches, so neither is asked for again on the
    /// first songs.
    func syncPremiumStatus() {
        let status = chooser.status
        if premiumStatus != status { premiumStatus = status }
        let (known, none) = (status == .premium, status == .notPremium)
        guard known || none, settings.value.premiumAccount != known || settings.value.noPremium != none else { return }
        settings.value.premiumAccount = known
        settings.value.noPremium = none
    }
}
