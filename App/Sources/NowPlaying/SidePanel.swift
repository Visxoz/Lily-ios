import SwiftUI

enum PanelTab: Int {
    case upNext, lyrics
}

/// The queue and lyrics fade out at the bottom rather than end in a hard cut
/// across the artwork's colour.
struct SidePanel: View {
    let tab: PanelTab
    /// Whether the panel's page is the one on screen.
    let isShown: Bool
    /// Shows another page, or with nil closes the panel.
    let show: (PanelTab?) -> Void

    private static let fade = LinearGradient(
        stops: [.init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PillGroup(
                    titles: ["Up next", "Lyrics"],
                    selection: Binding { tab.rawValue } set: { show(PanelTab(rawValue: $0)) }
                )
                Spacer()
                IconButton(icon: .close) { show(nil) }
                    .accessibilityLabel("Close panel")
            }
            .frame(height: 48)
            .padding(.leading, NowPlayingScreen.padding)
            .padding(.trailing, NowPlayingScreen.padding - 8)
            Group {
                switch tab {
                case .upNext:
                    UpNextPanel(isShown: isShown) { show(nil) }
                case .lyrics:
                    // Only while on screen, as the player loads lyrics then
                    // and they follow the song many times a second.
                    if isShown {
                        LyricsPanel { show(nil) }
                    } else {
                        Color.clear
                    }
                }
            }
            .mask(Self.fade)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Whether letting go of a list pulled well past its top closes the panel;
/// the list and the page share the swipe's direction, so it would only bounce.
func pulledPastTop(_ old: ScrollPhase, _ new: ScrollPhase, _ geometry: ScrollGeometry) -> Bool {
    old == .interacting && new != .interacting && geometry.contentOffset.y + geometry.contentInsets.top < -60
}
