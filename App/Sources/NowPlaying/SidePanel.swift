import SwiftUI

/// The panel's two pages, as `side-panel.slint`'s `panel-tab`.
enum PanelTab: Int {
    case upNext, lyrics
}

/// ytm-native's right-hand panel (`panel/side-panel.slint`) inside Now
/// Playing: the Up next and Lyrics chips with the close button, over the
/// queue or the lyrics, which fade out above the seek bar rather than end in
/// a hard cut across the artwork's colour.
struct SidePanel: View {
    let tab: PanelTab
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
                case .upNext: UpNextPanel()
                case .lyrics: LyricsPanel()
                }
            }
            .mask(Self.fade)
        }
        .frame(maxHeight: .infinity)
    }
}
