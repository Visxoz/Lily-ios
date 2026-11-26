import SwiftUI

/// A view of its own, so play and pause redraw this alone.
struct PlayPauseButton: View {
    let size: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    /// Counted here, as a tap that starts loading swaps the button for the spinner before its own haptic plays.
    @State private var taps = 0

    var body: some View {
        let player = app.player
        ZStack {
            if player.isBuffering {
                Spinner(size: size * 0.78)
            } else {
                PlayButton(size: size, playing: player.isPlaying, colour: theme.text, iconColour: theme.textInverse, feedback: nil) {
                    taps += 1
                    player.togglePlayPause()
                }
            }
        }
        .frame(width: size, height: size)
        .sensoryFeedback(.play, trigger: taps)
    }
}
