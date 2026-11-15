import SwiftUI
import YTMCore

/// The seek bar with the time played and the song's length, as the player
/// bar's. The position is pulled four times a second, as the player ticks,
/// while the song plays, never while paused or while the bar is being
/// dragged; the drag shows where it would seek to and seeks once let go.
struct Scrubber: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    /// Where the bar is being dragged to, as a fraction of the song.
    @State private var scrubbing: Double?

    var body: some View {
        let player = app.player
        let length = player.duration
        TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying || scrubbing != nil)) { _ in
            let position = scrubbing.map { $0 * length } ?? player.currentTime
            VStack(spacing: 0) {
                BarSlider(value: length > 0 ? position / length : 0, buffered: player.bufferedFraction, changed: { scrubbing = $0 }) { fraction in
                    player.seek(to: fraction * length)
                    scrubbing = nil
                }
                .disabled(length <= 0)
                .accessibilityLabel("Position")
                HStack {
                    Text(Formatting.duration(Int(position)))
                    Spacer()
                    Text(Formatting.duration(Int(length)))
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            }
        }
    }
}
