import Foundation
import Observation
import YTMAudio
import YTMCore

/// Settings changes take effect as made: normalisation within the few seconds the engine has scheduled, quality,
/// crossfade and Automix from the next song queued, speed and the cache's cap at once.
extension PlayerController {
    public func toggleMute() {
        settings.value.muted.toggle()
        apply(settings.value)
    }

    public func cycleShuffle() {
        settings.value.shuffle = switch settings.value.shuffle {
        case .off: .on
        case .on: .smart
        case .smart: .off
        }
        apply(settings.value)
    }

    public func cycleRepeat() {
        settings.value.repeatMode = switch settings.value.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        apply(settings.value)
    }

    /// Plays go to the account's YouTube history, and their watch time with them.
    var reportsToYouTube: Bool { signedIn && settings.value.youtubeHistory }

    /// Call after signing in or out. Dropping the saved Home, the old account's, is the caller's job.
    public func accountDidChange() async {
        recorder.forgetWatch()
        chooser.reset()
        premiumStatus = .unknown
        settings.value.premiumAccount = false
        settings.value.noPremium = false
        signedIn = await music.isSignedIn
        // Streams kept are the old account's, Premium ones too.
        prefetcher.clear()
        preparePremium()
        if let id = current?.id { loadRating(of: id) }
    }

    func followSettings() {
        let settings = settings
        listening.append(Task { [weak self] in
            for await value in Observations({ settings.value }) {
                self?.apply(value)
            }
        })
    }

    /// Does only what changed since the settings last applied.
    func apply(_ new: Settings) {
        let old = applied
        applied = new
        if audio.isMuted != new.muted { audio.isMuted = new.muted }
        let level = Self.level(new.normalise)
        if audio.normalise != level { audio.normalise = level }
        if audio.crossfeed != new.crossfeed { audio.crossfeed = new.crossfeed }
        if audio.widen != new.widen { audio.widen = new.widen }
        if audio.mono != new.mono { audio.mono = new.mono }
        if audio.balance != new.balance { audio.balance = new.balance }
        if audio.pauseOnUnplug != new.pauseOnUnplug { audio.pauseOnUnplug = new.pauseOnUnplug }
        if audio.cacheLimitBytes != new.audioCacheBytes { audio.cacheLimitBytes = new.audioCacheBytes }
        if audio.speed != new.speed {
            audio.speed = new.speed
            nowPlaying?.speed = new.speed
            publishPlayback()
        }
        if old?.equaliserEnabled != new.equaliserEnabled || old?.equaliserGains != new.equaliserGains {
            audio.equaliser = (new.equaliserEnabled, new.equaliserGains)
        }
        guard let old else { return }
        downloads.settingsChanged(from: old, to: new)
        // A song not yet played only shows what is on the phone, as at restore.
        if old.animatedArt != new.animatedArt, let current { nowPlaying?.showMotion(of: current, new.animatedArt, fetching: !isStopped) }
        if old.shuffle != new.shuffle {
            if new.shuffle != .smart {
                queue.removeRecommended()
                smart.reset()
            }
            queue.setShuffle(new.shuffle != .off)
        }
        if old.shuffle != new.shuffle || old.repeatMode != new.repeatMode {
            queueEdited()
        }
        if old.blockedArtists != new.blockedArtists {
            // Only those just blocked, so a song chosen by one blocked before stays.
            let added = new.blockedArtists.filter { !old.blockedArtists.contains(where: $0.matches) }
            if !added.isEmpty { leaveOutBlocked(Blocked(artists: added)) }
        }
        if old.blockAI != new.blockAI { blockAIChanged(to: new.blockAI) }
        if old.quality != new.quality {
            // Streams resolved ahead, or being resolved, at the old quality are dropped; the playing song carries on.
            queueing?.cancel()
            prefetcher.clear()
            gapless.forget()
            audio.setNext(nil, .gapless, sung: Sung())
            preparePremium()
        } else if old.transition != new.transition {
            // A song queued, or being queued, with the old setting is queued again.
            dropQueuedNext()
        }
        if old.transition != new.transition { prefetchSung() }
    }

    /// The engine's gain on top of the loudness correction: Quiet's 0.5 is 6 dB under Normal before the boost cap.
    private static func level(_ normalise: Normalise) -> Float? {
        switch normalise {
        case .off: nil
        case .quiet: 0.5
        case .normal: 1
        }
    }

    /// Prepares the Premium player script ahead, so the first song doesn't wait for it.
    func preparePremium() {
        guard signedIn, settings.value.quality == .high else { return }
        let music = music
        Task { await music.preparePremium() }
    }
}
