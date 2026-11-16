import SwiftUI
import YTMCore

/// The two pages scroll natively, so a swipe follows the finger and can't be
/// lost to the zoom's own close.
struct NowPlayingScreen: View {
    static let padding: CGFloat = 24

    private enum Page: Hashable {
        case artwork, panel
    }

    @Environment(AppModel.self) private var app
    @State private var page: Page? = .artwork
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
/// the zoom's close; `scrollBounceBehavior` can't while content overflows. Its
/// nearest scroll view is the pager, never the queue, which needs its bounce.
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

/// The menu leaves out rating, which is beside the title, and queueing, which
/// has no use for the song playing.
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

/// Decoded at the player's shared size, which is fetched ahead with the song.
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

/// The artwork's colours where they sit in it, as a blurred copy would show
/// them without the cost of blurring.
private struct NowPlayingBackground: View {
    private static let edge = ArtworkPalette.meshEdge
    private static let points = (0..<edge * edge).map { cell in
        SIMD2(Float(cell % edge), Float(cell / edge)) / Float(edge - 1)
    }

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let mesh = app.artwork?.mesh {
                // Each row darker than the one above, the bottom by a third.
                let colours = mesh.enumerated().map { cell, colour in
                    theme.tint(colour.darker(Double(cell / Self.edge) / Double(2 * (Self.edge - 1))))
                }
                MeshGradient(width: Self.edge, height: Self.edge, points: Self.points, colors: colours)
            } else {
                theme.panel
            }
        }
        .animation(.easeInOut(duration: 0.5), value: app.artwork)
        .ignoresSafeArea()
    }
}
