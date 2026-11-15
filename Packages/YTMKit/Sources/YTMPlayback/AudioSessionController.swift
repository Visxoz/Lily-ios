import AVFoundation
import os

/// The app's audio session: music that plays on with the screen locked and
/// in the background, paused by calls and other apps' audio, and resumed
/// when the system recommends it.
///
/// Route changes are left alone, as ytm-native leaves them: unplugging
/// headphones carries on through the next device rather than pausing, and
/// the engine follows the new output itself. Only iOS has an audio session;
/// on macOS this does nothing.
@MainActor final class AudioSessionController {
    #if os(iOS)
    private var isActive = false
    /// The music was playing when the system took the session away, so it
    /// resumes only then.
    private var resumeAfterInterruption = false
    private var observers: [NotificationCenter.ObservationToken] = []
    /// The media services reset has no typed message, so it is observed by name.
    private var resetObserver: (any NSObjectProtocol)?

    init(player: PlayerController) {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(of: session, for: .didBecomeInactive) { [weak self, weak player] message in
                guard let self else { return }
                // However the system took the session, the next play must ask
                // for it again; only an interruption pauses the player.
                isActive = false
                guard let player, case .systemInterruption = message.deactivationResult else { return }
                interrupted(player)
            },
            center.addObserver(of: session, for: .resumptionRecommendation) { [weak self, weak player] message in
                guard let self, let player else { return }
                resume(player, recommended: message.recommendation == .shouldResume)
            },
        ]
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self, weak player] _ in
            guard let self, let player else { return }
            MainActor.assumeIsolated { self.servicesReset(player) }
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    }

    /// Makes the session active for playback, as it must be before the
    /// engine plays; only the first call, or the first after the system
    /// took the session away, reaches the system.
    func activate() {
        guard !isActive else { return }
        do {
            // The default route sharing, not long-form audio's, under which
            // headphone presses (AirPods squeezes) never reached the app,
            // though the lock screen's buttons did.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            isActive = true
        } catch {
            Logger.playback.error("The audio session couldn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The system has stopped the sound, for a call or another app; the
    /// player follows, so it shows paused and its position holds.
    private func interrupted(_ player: PlayerController) {
        resumeAfterInterruption = player.isPlaying
        if player.isPlaying { player.setPaused(true) }
    }

    /// The system's media services restarted and took the session with
    /// them, so it is set up again, as Apple asks, when the player next
    /// activates it to play.
    private func servicesReset(_ player: PlayerController) {
        isActive = false
        resumeAfterInterruption = false
        player.mediaServicesReset()
    }

    private func resume(_ player: PlayerController, recommended: Bool) {
        defer { resumeAfterInterruption = false }
        guard recommended, resumeAfterInterruption else { return }
        player.setPaused(false)
    }
    #else
    init(player _: PlayerController) {}

    func activate() {}
    #endif
}
