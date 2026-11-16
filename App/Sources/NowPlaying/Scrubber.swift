import SwiftUI
import YTMCore

/// The position is pulled four times a second, as the player ticks, never
/// while paused or dragged; a drag seeks once let go.
struct Scrubber: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    /// Where the bar is being dragged to, as a fraction of the song.
    @State private var scrubbing: Double?
    /// The place last sought, shown while paused as the engine's clock may not
    /// have reached it and a paused bar is never pulled again.
    @State private var sought: Double?

    var body: some View {
        let player = app.player
        let length = player.duration
        let total = Formatting.duration(Int(length))
        TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying || scrubbing != nil)) { _ in
            let position = scrubbing.map { $0 * length } ?? (player.isPlaying ? nil : sought) ?? player.currentTime
            let played = Formatting.duration(Int(position))
            VStack(spacing: 0) {
                BarSlider(
                    value: length > 0 ? position / length : 0,
                    buffered: player.bufferedFraction,
                    valueText: "\(played) of \(total)",
                    changed: { scrubbing = $0 }
                ) { fraction in
                    player.seek(to: fraction * length)
                    scrubbing = nil
                }
                .disabled(length <= 0)
                .accessibilityLabel("Position")
                HStack {
                    Text(played)
                    Spacer()
                    Text(total)
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            }
        }
        .onChange(of: player.lastSeek) { _, seek in sought = seek.to }
        .onChange(of: player.isPlaying) { sought = nil }
        .onChange(of: player.current?.id) { sought = nil }
    }
}
