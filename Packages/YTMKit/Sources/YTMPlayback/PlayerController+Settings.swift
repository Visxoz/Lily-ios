import Foundation
import Observation
import YTMCore

/// The settings the player follows, and the account it plays for. Any
/// change to `SettingsStore.value`, from here or from Settings, takes effect
/// as it is made: mute and the equaliser at once, normalisation
/// within the few seconds the engine has scheduled; shuffle in the queue;
/// quality and crossfade from the next song queued.
extension PlayerController {
    public func toggleMute() {
        settings.value.muted.toggle()
        apply(settings.value)
    }

    /// The shuffle button: off, shuffle, Smart Shuffle, then off again.
    public func cycleShuffle() {
        settings.value.shuffle = switch settings.value.shuffle {
        case .off: .on
        case .on: .smart
        case .smart: .off
        }
        apply(settings.value)
    }

    /// The repeat button: off, all, one, then off again.
    public func cycleRepeat() {
        settings.value.repeatMode = switch settings.value.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        apply(settings.value)
    }

    /// Call after signing in or out: a new account says nothing yet about
    /// Premium, and the playing song's rating is its own. The saved Home
    /// belongs to the old account; dropping it is the caller's.
    public func accountDidChange() async {
        chooser.reset()
        premiumStatus = .unknown
        settings.value.premiumAccount = false
        settings.value.noPremium = false
        signedIn = await music.isSignedIn
        preparePremium()
        if let id = current?.id { loadRating(of: id) }
    }

    /// Follows every change to the settings from now on.
    func followSettings() {
        let settings = settings
        listening.append(Task { [weak self] in
            for await value in Observations({ settings.value }) {
                self?.apply(value)
            }
        })
    }

    /// Puts `new` into effect, doing only what changed since the settings
    /// last applied.
    func apply(_ new: Settings) {
        let old = applied
        applied = new
        if audio.isMuted != new.muted { audio.isMuted = new.muted }
        if audio.normalise != new.normalise { audio.normalise = new.normalise }
        if old?.equaliserEnabled != new.equaliserEnabled || old?.equaliserGains != new.equaliserGains {
            audio.equaliser = (new.equaliserEnabled, new.equaliserGains)
        }
        guard let old else { return }
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
        if old.quality != new.quality {
            // Streams resolved ahead, or being resolved, at the old quality
            // are dropped; the playing song carries on as it is.
            queueing?.cancel()
            prefetcher.clear()
            gapless.forget()
            audio.setNext(nil, crossfade: false)
            preparePremium()
        } else if old.crossfade != new.crossfade {
            // A song queued, or being queued, with the old setting is queued again.
            dropQueuedNext()
        }
    }

    /// Prepares the Premium player script in the background, so the first
    /// song doesn't wait for it, when Premium audio can apply.
    func preparePremium() {
        guard signedIn, settings.value.quality == .high else { return }
        let music = music
        Task { await music.preparePremium() }
    }
}
