import Foundation
import os
import YTMCore

/// Records plays, as ytm-native's `record_play`, run as a song's sound
/// starts: the local history, Last.fm (now playing, then a scrobble once
/// enough has been heard), and the YouTube account's history. Only
/// `PlayerController.recordPlay` calls it, so a play is recorded in one place.
@MainActor final class PlayRecorder {
    private let history: LocalHistory
    private let music: any MusicService
    private let lastFM: any Scrobbling
    private var scrobbler = Scrobbler()

    init(history: LocalHistory, music: any MusicService, lastFM: any Scrobbling) {
        self.history = history
        self.music = music
        self.lastFM = lastFM
    }

    /// `reportToYouTube`, signed in with the YouTube history setting on, adds
    /// the song to the account's history, as YouTube Music does, so its
    /// recommendations and Listen again follow what plays here too.
    func record(_ track: Track, reportToYouTube: Bool) {
        history.record(track)
        scrobbler.start(track)
        let (music, lastFM) = (music, lastFM)
        Task {
            await lastFM.nowPlaying(track)
        }
        guard reportToYouTube else { return }
        Task {
            do {
                try await music.reportPlay(videoId: track.id)
            } catch {
                Logger.playback.warning("could not add a play to the YouTube history: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    /// Counts the song heard up to `position` of `length` seconds, and
    /// scrobbles it once that counts.
    func heard(position: Double, length: Double) {
        guard let play = scrobbler.heard(position: position, length: length) else { return }
        let lastFM = lastFM
        Task {
            await lastFM.scrobble(play.track, startedAt: play.startedAt)
        }
    }
}
