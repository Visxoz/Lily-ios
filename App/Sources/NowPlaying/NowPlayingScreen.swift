import SwiftUI
import YTMCore

/// ytm-native's player bar and right-hand panel as one screen, grown out of
/// the mini player, in two pages a swipe moves between: the artwork, title,
/// seek bar, transport, and the volume, quality badge and panel buttons;
/// and below it the same controls folded into one row over the Up next and
/// Lyrics chips with the queue or the lyrics, all over the artwork's colour.
///
/// The pages scroll natively, so a swipe follows the finger and can't be
/// lost to the zoom's own close. At the artwork a swipe down closes the
/// screen into the mini player; on the panel it scrolls back to the artwork
/// first.
struct NowPlayingScreen: View {
    static let padding: CGFloat = 24

    private enum Page: Hashable {
        case artwork, panel
    }

    @Environment(AppModel.self) private var app
    @State private var page: Page? = .artwork
    /// What the panel page shows, kept while the artwork does.
    @State private var tab = PanelTab.upNext

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            if let track = app.player.current {
                NowPlayingTopBar(track: track)
                ScrollView {
                    VStack(spacing: 0) {
                        // Each page hidden from VoiceOver while off screen,
                        // so it reads one set of controls.
                        artworkPage(track)
                            .containerRelativeFrame(.vertical)
                            .accessibilityHidden(page != .artwork)
                            .id(Page.artwork)
                        panelPage(track)
                            .containerRelativeFrame(.vertical)
                            .accessibilityHidden(page != .panel)
                            .id(Page.panel)
                    }
                    .scrollTargetLayout()
                    .background(PagerBounceOff())
                }
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                // The page counts as shown once past halfway, so a swipe
                // down from the panel stays one page until it settles.
                .scrollPosition(id: $page, anchor: .center)
                .scrollIndicators(.hidden)
            }
        }
        .padding(.bottom, 8)
        .background { NowPlayingBackground() }
        // On the panel a pull down, even on the queue at its top, goes back
        // to the artwork rather than closing the screen.
        .interactiveDismissDisabled(page == .panel)
        .sheet(item: $app.nowPlayingPicker) { PlaylistPickerSheet(track: $0) }
        .onAppear { app.nowPlayingShown = true }
        .onDisappear { app.nowPlayingShown = false }
    }

    private func artworkPage(_ track: Track) -> some View {
        VStack(spacing: 0) {
            LargeArtwork(url: track.thumbnail)
                .accessibilityAction(named: "Up next") { show(.upNext) }
                .padding(.vertical, 12)
            TrackTitle(track: track, compact: false)
            Scrubber()
                .padding(.top, 12)
            TransportControls()
            PlayerOptions(open: show)
        }
        .padding(.horizontal, Self.padding)
    }

    private func panelPage(_ track: Track) -> some View {
        VStack(spacing: 0) {
            CompactControls(track: track)
            SidePanel(tab: tab, isShown: page == .panel) { next in
                if let next { show(next) } else { withAnimation(Theme.normal) { page = .artwork } }
            }
        }
    }

    private func show(_ next: PanelTab) {
        withAnimation(Theme.normal) {
            tab = next
            page = .panel
        }
    }
}

/// Stops the pager bouncing, so a swipe down at the artwork goes straight to
/// the zoom's own close, which follows the finger, rather than stretching
/// the page inside the shrinking screen. SwiftUI's `scrollBounceBehavior`
/// can't stop it while the content overflows, as two pages always do. Its
/// nearest scroll view is the pager, never the queue, whose bounce a pull
/// past its top needs.
// shortcut: relies on SwiftUI's ScrollView being a UIScrollView; drop it once SwiftUI can turn the bounce off.
private struct PagerBounceOff: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        // Behind both pages, so it must never take a touch meant for them.
        probe.isUserInteractionEnabled = false
        return probe
    }

    // The work is done in `didMoveToWindow`, once the probe is in the pager.
    func updateUIView(_ probe: Probe, context: Context) {}

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            (view as? UIScrollView)?.bounces = false
        }
    }
}

/// Above the panel, the controls folded into one row, as the mini player's:
/// the artwork, the title, play and next, over how far the song has got.
private struct CompactControls: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(url: track.thumbnail, size: 52)
                TrackTitle(track: track, compact: true)
                PlayPauseButton(size: 44)
                IconButton(icon: .next, size: 44, iconSize: 26, colour: theme.text) { app.player.next() }
                    .accessibilityLabel("Next")
            }
            MiniProgress()
        }
        .padding(.horizontal, NowPlayingScreen.padding)
        .padding(.vertical, 8)
    }
}

/// The close button, and the song's menu as the player bar's: saving it
/// (signed in), its artist and its album. Rating is beside the title, and
/// queueing the song playing has no use.
private struct NowPlayingTopBar: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            IconButton(icon: .close, size: 40, iconSize: 22, colour: theme.text) { dismiss() }
                .accessibilityLabel("Close")
            Spacer()
            Menu {
                if app.isSignedIn {
                    Button("Save to playlist") { app.addToPlaylist(track) }
                }
                TrackLinks(track: track)
            } label: {
                IconView(icon: .more, size: 22, colour: theme.text)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, NowPlayingScreen.padding - 8)
        .padding(.top, 12)
    }
}

/// The artwork as large as the room left for it, square, decoded at the
/// player's shared size, which is fetched ahead with the song.
private struct LargeArtwork: View {
    let url: String?

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { space in
            let edge = min(space.size.width, space.size.height)
            ArtworkView(url: url, size: edge, radius: 8, pixelEdge: ImagePipeline.playerEdge, shadow: (theme.shadowSoft, 16, 8))
                .frame(width: space.size.width, height: space.size.height)
        }
    }
}

/// Behind the screen, the artwork's colour darkening downwards, as the
/// side panel's lyrics, fading as the song changes; the panel's own colour
/// without artwork.
private struct NowPlayingBackground: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let colour = app.artwork?.background {
                LinearGradient(colors: [theme.tint(colour), theme.tint(colour.darker(0.5))], startPoint: .top, endPoint: .bottom)
            } else {
                theme.panel
            }
        }
        .animation(.easeInOut(duration: 0.5), value: app.artwork)
        .ignoresSafeArea()
    }
}
