import SwiftUI
import YTMCore

/// The player bar's right side: the volume with its mute button,
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

/// Mute and the phone's own volume, which the slider shows and sets and
/// which follows the side buttons.
private struct VolumeControl: View {
    @Environment(AppModel.self) private var app
    @State private var volume = SystemVolume()

    var body: some View {
        let player = app.player
        let muted = app.settings.value.muted
        HStack(spacing: 8) {
            IconButton(icon: icon(muted: muted), size: 36, iconSize: 20) { player.toggleMute() }
                .accessibilityLabel(muted ? "Unmute" : "Mute")
            BarSlider(value: muted ? 0 : Double(volume.level), changed: setVolume, committed: setVolume)
                .accessibilityLabel("Volume")
                .background { SystemVolumeView(volume: volume).frame(width: 1, height: 1).accessibilityHidden(true) }
        }
    }

    private func icon(muted: Bool) -> Icon {
        if muted || volume.level == 0 { return .volumeOff }
        return volume.level < 0.5 ? .volumeLow : .volume
    }

    /// Moving the slider unmutes, as it would on a muted phone.
    private func setVolume(_ value: Double) {
        if app.settings.value.muted { app.player.toggleMute() }
        volume.set(Float(value))
    }
}
