import SwiftUI
import YTMAudio
import YTMCore

struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingBlockAI = false

    var body: some View {
        @Bindable var settings = app.settings
        SettingRow(label: "Audio quality", detail: qualityDetail(settings.value.quality), stacked: true) {
            ChoicePills(
                choices: [(AudioQuality.low, "Low"), (.normal, "Normal"), (.high, "High")],
                selection: $settings.value.quality
            )
        }
        SettingRow(label: "Speed", detail: "Faster or slower, the pitch moving with it as on a record.", stacked: true) {
            ChoicePills(choices: Settings.speeds.map { ($0, "\($0.formatted())×") }, selection: $settings.value.speed)
        }
        ToggleRow(
            label: "Automix",
            detail: "Blends each track into the next as a DJ would: over a fade-out or a quiet intro, on the beat when tempos agree, one bass at a time. Tracks of an album played in order still run straight on.",
            isOn: $settings.value.automix
        )
        // Automix blends in its place.
        if !settings.value.automix {
            SettingRow(label: "Crossfade", detail: "Fades each track into the next. Tracks of an album played in order still run straight on.") {
                HStack(spacing: 12) {
                    if settings.value.crossfade {
                        Menu {
                            ForEach(Settings.crossfadeLengths, id: \.self) { seconds in
                                Button(Self.length(seconds)) { settings.value.crossfadeSeconds = seconds }
                            }
                        } label: {
                            PillLabel(title: Self.length(settings.value.crossfadeSeconds), small: true)
                        }
                    }
                    Toggle("Crossfade", isOn: $settings.value.crossfade)
                        .labelsHidden()
                }
            }
        }
        ToggleRow(
            label: "Pause when unplugged",
            detail: "Pauses when headphones or the device playing are unplugged, rather than carrying on through another.",
            isOn: $settings.value.pauseOnUnplug
        )
        ToggleRow(
            label: "Autoplay",
            detail: "Keeps playing similar music when the queue ends.",
            isOn: $settings.value.autoplay
        )
        ToggleRow(
            label: "Block AI music",
            detail: "Experimental. Leaves out songs by artists on a community list.",
            // On only once the alert is confirmed, off at once.
            isOn: Binding(get: { settings.value.blockAI }, set: { on in
                if on { confirmingBlockAI = true } else { settings.value.blockAI = false }
            })
        )
        .alert("Block AI music", isPresented: $confirmingBlockAI) {
            Button("Cancel", role: .cancel) {}
            Button("Turn on") { settings.value.blockAI = true }
        } message: {
            Text("This is experimental. Songs by artists on a community list of AI-generated music are left out of queues, radios and shuffles, matched by name. The list comes from a third party, not from Lily, and Lily can't check it: it may name real artists, and anyone sharing a listed artist's name is left out too. A song you pick to play still plays.")
        }
        SettingRow(
            label: "Blocked artists",
            detail: "Their songs are left out of what plays unless you pick one yourself. Block an artist from a song's or artist's menu."
        ) {
            NavigationLink(value: SettingsPage.blockedArtists) {
                PillLabel(title: "Manage", small: true)
            }
            .buttonStyle(PressScale(scale: 0.96))
        }
        if app.hasHinge {
            ToggleRow(
                label: "Fold to scrub",
                detail: "With Now Playing open and the phone half open like a book, rest it a moment, then fold it to skip back or open it to skip ahead, 10 seconds a step.",
                isOn: $settings.value.foldToScrub
            )
        }
        StorageRow()
    }

    private static func length(_ seconds: Double) -> String {
        "\(seconds.formatted()) s"
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
        let limit = app.settings.value.audioCacheBytes
        SettingRow(label: "Audio cache", detail: detail) {
            HStack(spacing: 12) {
                Menu {
                    // A picker, so the size chosen is ticked.
                    Picker("Cache size", selection: Binding(get: { limit }, set: setLimit)) {
                        ForEach(Settings.audioCacheSizes, id: \.self) { Text(Self.bytes($0)).tag($0) }
                    }
                } label: {
                    PillLabel(title: Self.bytes(limit), small: true)
                }
                .accessibilityLabel("Cache size")
                .accessibilityValue(Self.bytes(limit))
                PillButton(title: "Clear", small: true) {
                    Task {
                        await app.audio.clearCache()
                        size = await app.audio.cacheSizeBytes
                    }
                }
                .disabled(size == 0)
            }
        }
        .task { size = await app.audio.cacheSizeBytes }
    }

    private var detail: String {
        guard let size else { return "Songs played lately, kept so they play again without the network." }
        return "\(Self.bytes(size)) of songs played lately, kept so they play again without the network."
    }

    private func setLimit(_ bytes: Int64) {
        app.settings.value.audioCacheBytes = bytes
        // Set here as well as by the player, so the trim is queued ahead of the size read.
        app.audio.cacheLimitBytes = bytes
        Task { size = await app.audio.cacheSizeBytes }
    }

    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}
