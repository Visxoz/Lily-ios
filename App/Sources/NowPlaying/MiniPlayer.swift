import SwiftUI
import YTMCore

/// ytm-native's player bar on a phone: the song playing, play and next, and
/// a thin line of how far it has got, in the tab bar's accessory. Tapping it
/// opens Now Playing, which grows out of it.
struct MiniPlayer: View {
    private static let art: CGFloat = 32

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let track = app.player.current {
            HStack(spacing: 10) {
                ArtworkView(url: track.thumbnail, size: Self.art)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text(track.artistNames)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                PlayPauseButton(size: 32)
                // The accessory shrinks into the tab bar as a page scrolls,
                // leaving room for play alone.
                if placement != .inline {
                    IconButton(icon: .next, size: 36, iconSize: 22, colour: theme.text) { app.player.next() }
                        .accessibilityLabel("Next")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(maxHeight: .infinity)
            // Inside the capsule, clear of its rounded ends.
            .overlay(alignment: .bottom) {
                MiniProgress()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 3)
            }
            .contentShape(Rectangle())
            .onTapGesture { app.sheet = .nowPlaying }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Open Now Playing") { app.sheet = .nowPlaying }
        }
    }
}

/// How far the song has got, pulled twice a second while it plays and left
/// alone while paused. A 2-point line moves too little to need more.
private struct MiniProgress: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let player = app.player
        TimelineView(.animation(minimumInterval: 0.5, paused: !player.isPlaying)) { _ in
            let fraction = player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
            Capsule()
                .fill(theme.ink.opacity(0.19))
                .overlay {
                    Capsule()
                        .fill(theme.text)
                        .scaleEffect(x: fraction, anchor: .leading)
                }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
