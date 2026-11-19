import Foundation
import os
import YTMCore

/// Only `PlayerController.recordPlay` calls it, so a play is recorded in one place.
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

    /// `reportToYouTube` adds the song to the account's history, so its
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

    /// Lets the song into Speed dial, then scrobbles it, once enough of its
    /// `length` seconds has been heard.
    func heard(position: Double, length: Double, speed: Double) {
        let (heard, scrobble) = scrobbler.heard(position: position, length: length, speed: speed)
        if let heard { history.markHeard(heard.id) }
        guard let play = scrobble else { return }
        let lastFM = lastFM
        Task {
            await lastFM.scrobble(play.track, startedAt: play.startedAt)
        }
    }
}
