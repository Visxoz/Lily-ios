import SwiftUI
import YTMCore

/// The player bar's right side: the app's own volume with its mute button,
/// then the quality badge and the buttons that open the panel on Lyrics or
/// Up next, closing it when it already shows that.
struct PlayerOptions: View {
    @Binding var panel: PanelTab?

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 4) {
            VolumeControl()
            HStack(spacing: 4) {
                if let stream = app.player.stream {
                    QualityBadge(stream: stream)
                }
                Spacer()
                toggle(.lyrics, icon: .lyrics, label: "Lyrics")
                toggle(.upNext, icon: .queue, label: "Up next")
            }
        }
    }

    private func toggle(_ tab: PanelTab, icon: Icon, label: String) -> some View {
        IconButton(icon: icon, size: 44, iconSize: 22, active: panel == tab) {
            panel = panel == tab ? nil : tab
        }
        .accessibilityLabel(label)
    }
}

/// Mute and the volume slider, which follows the finger.
private struct VolumeControl: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        let settings = app.settings.value
        HStack(spacing: 8) {
            IconButton(icon: icon(settings), size: 36, iconSize: 20) { player.toggleMute() }
                .accessibilityLabel(settings.muted ? "Unmute" : "Mute")
            BarSlider(value: settings.muted ? 0 : Double(settings.volume), changed: setVolume, committed: setVolume)
                .accessibilityLabel("Volume")
        }
    }

    private func icon(_ settings: Settings) -> Icon {
        if settings.muted || settings.volume == 0 { return .volumeOff }
        return settings.volume < 0.5 ? .volumeLow : .volume
    }

    private func setVolume(_ value: Double) {
        app.player.setVolume(Float(value))
    }
}
