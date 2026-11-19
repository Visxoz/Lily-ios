import SwiftUI
import YTMAudio
import YTMCore

struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        SettingRow(label: "Audio quality", detail: qualityDetail(settings.value.quality), stacked: true) {
            ChoicePills(
                choices: [(AudioQuality.low, "Low"), (.normal, "Normal"), (.high, "High")],
                selection: $settings.value.quality
            )
        }
        ToggleRow(
            label: "Normalise volume",
            detail: "Plays every track at a similar loudness, as YouTube Music does.",
            isOn: $settings.value.normalise
        )
        ToggleRow(
            label: "Crossfade",
            detail: "Fades each track into the next. Tracks of an album played in order still run straight on.",
            isOn: $settings.value.crossfade
        )
        SettingRow(label: "Speed", detail: "Faster or slower, the pitch moving with it as on a record.", stacked: true) {
            ChoicePills(choices: Settings.speeds.map { ($0, "\($0.formatted())×") }, selection: $settings.value.speed)
        }
        SettingRow(label: "Equaliser", detail: EqualiserScreen.summary(settings.value)) {
            NavigationLink(value: SettingsPage.equaliser) {
                PillLabel(title: "Adjust", small: true)
            }
            .buttonStyle(PressScale(scale: 0.96))
        }
        ToggleRow(
            label: "Autoplay",
            detail: "Keeps playing similar music when the queue ends.",
            isOn: $settings.value.autoplay
        )
        if app.hasHinge {
            ToggleRow(
                label: "Fold to scrub",
                detail: "With Now Playing open and the phone half open like a book, rest it a moment, then fold it to skip back or open it to skip ahead, 10 seconds a step.",
                isOn: $settings.value.foldToScrub
            )
        }
        StorageRow()
    }

    private func qualityDetail(_ quality: AudioQuality) -> String {
        switch quality {
        case .low: "About 50 kbps, a third of the data of Normal. For a metered connection."
        case .normal: "About 130 kbps, as YouTube Music plays without Premium."
        case .high: app.player.premiumStatus.summary
        }
    }
}

private struct StorageRow: View {
    @Environment(AppModel.self) private var app
    @State private var size: Int64?

    var body: some View {
        SettingRow(label: "Audio cache", detail: detail) {
            PillButton(title: "Clear", small: true) {
                Task {
                    await app.audio.clearCache()
                    size = await app.audio.cacheSizeBytes
                }
            }
            .disabled(size == 0)
        }
        .task { size = await app.audio.cacheSizeBytes }
    }

    private var detail: String {
        guard let size else { return "Songs played lately, kept so they play again without the network." }
        return "\(size.formatted(.byteCount(style: .file))) of songs played lately, kept so they play again without the network."
    }
}
