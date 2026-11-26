import SwiftUI

/// Play and next beside a song's title, with previous too while the title still fits whole.
struct CompactTransport<Title: View>: View {
    let playSize: CGFloat
    @ViewBuilder let title: Title

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    /// Counted here, as a skip to a longer title takes previous away before its own haptic plays.
    @State private var skips = 0

    var body: some View {
        HStack(spacing: 12) {
            // Play and next outside, so they're built once and keep their state as previous comes and goes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    title
                    skip(.previous, "Previous") { app.player.previous() }
                }
                title
            }
            PlayPauseButton(size: playSize)
            skip(.next, "Next") { app.player.next() }
        }
        .sensoryFeedback(.skip, trigger: skips)
    }

    private func skip(_ icon: Icon, _ label: String, action: @escaping () -> Void) -> some View {
        IconButton(icon: icon, size: 44, iconSize: 26, colour: theme.text) {
            skips += 1
            action()
        }
        .accessibilityLabel(label)
    }
}
