import SwiftUI
import YTMCore

/// ytm-native's player bar on a phone: the song playing, play and next, and
/// a thin line of how far it has got, in a glass capsule above the tab bar
/// as tall as the tab bar, so its controls are easy to reach. Tapping it
/// opens Now Playing, which grows out of it.
struct MiniPlayer: View {
    private static let height: CGFloat = 64
    private static let art: CGFloat = 44
    /// The tab bar's own margins, so the two line up.
    private static let margin: CGFloat = 20

    /// The tab it sits in, which names it as the source Now Playing grows
    /// out of.
    let tab: AppTab
    let transition: Namespace.ID

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if let track = app.player.current, !(tab == .search && app.isSearching) {
            HStack(spacing: 12) {
                ArtworkView(url: track.thumbnail, size: Self.art, radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text(track.artistNames)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                PlayPauseButton(size: 42)
                IconButton(icon: .next, size: 44, iconSize: 26, colour: theme.text) { app.player.next() }
                    .accessibilityLabel("Next")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: Self.height)
            // Inside the capsule, clear of its rounded ends.
            .overlay(alignment: .bottom) {
                MiniProgress()
                    .padding(.horizontal, 28)
                    .padding(.bottom, 4)
            }
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            // Shaped as the capsule, so Now Playing shrinks into its rounded
            // ends rather than a rectangle they replace on the last frame.
            .matchedTransitionSource(id: tab, in: transition) { $0.clipShape(.rect(cornerRadius: Self.height / 2)) }
            .onTapGesture { app.sheet = .nowPlaying }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Open Now Playing") { app.sheet = .nowPlaying }
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 8)
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
