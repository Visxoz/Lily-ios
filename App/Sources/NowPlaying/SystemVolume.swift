import AVFAudio
import MediaPlayer
import SwiftUI

/// The phone's own volume, as the side buttons and Control Centre set it,
/// for the volume slider to show and set.
@MainActor @Observable final class SystemVolume {
    /// From 0 to 1.
    private(set) var level = AVAudioSession.sharedInstance().outputVolume

    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private weak var volumeView: MPVolumeView?

    /// Follows the volume from when its view is made, which happens once,
    /// rather than from `init`, which SwiftUI runs again on every redraw of
    /// the view holding it as state and then throws away.
    fileprivate func attach(_ view: MPVolumeView) {
        volumeView = view
        let session = AVAudioSession.sharedInstance()
        level = session.outputVolume
        // Sendable, as the session reports from a thread of its own.
        observation = session.observe(\.outputVolume) { @Sendable [weak self] session, _ in
            let level = session.outputVolume
            Task { @MainActor in self?.level = level }
        }
    }

    /// iOS offers no call that sets the volume; a system volume view's own
    /// slider is the supported way to move it. Without one the bar stays
    /// put, rather than showing a change that never happened.
    func set(_ value: Float) {
        guard let slider = volumeView?.subviews.lazy.compactMap({ $0 as? UISlider }).first else { return }
        level = value
        slider.value = value
        slider.sendActions(for: .valueChanged)
    }
}

/// The system volume view `SystemVolume` sets the volume through. While it
/// is on screen, iOS leaves out its own volume overlay, as the slider beside
/// it already shows each press of the side buttons.
struct SystemVolumeView: UIViewRepresentable {
    let volume: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        // Nearly transparent rather than hidden, which iOS would take as off screen.
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        volume.attach(view)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
