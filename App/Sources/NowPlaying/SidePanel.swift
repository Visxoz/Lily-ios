import SwiftUI

/// The panel's two pages, as `side-panel.slint`'s `panel-tab`.
enum PanelTab: Int {
    case upNext, lyrics
}

/// ytm-native's right-hand panel (`panel/side-panel.slint`) inside Now
/// Playing: the Up next and Lyrics chips with the close button, over the
/// queue or the lyrics, which fade out at the bottom of the screen rather
/// than end in a hard cut across the artwork's colour.
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

/// Whether letting go of a list pulled well down past its top asks for the
/// panel to close, as a swipe down on the rest of it does; the list and the
/// page share the swipe's direction, so the list would only bounce.
func pulledPastTop(_ old: ScrollPhase, _ new: ScrollPhase, _ geometry: ScrollGeometry) -> Bool {
    old == .interacting && new != .interacting && geometry.contentOffset.y + geometry.contentInsets.top < -60
}
