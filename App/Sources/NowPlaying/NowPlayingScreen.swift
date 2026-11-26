import SwiftUI
import YTMCore
import YTMPlayback

/// The two pages scroll natively, so a swipe follows the finger and can't be lost to the zoom's own close. iPhone
/// Duo's inner display has room for both at once; stood half open, the artwork or lyrics take the upright half.
struct NowPlayingScreen: View {
    static let padding: CGFloat = 24

    private enum Page: Hashable {
        case artwork, panel
    }

    private enum Layout {
        case pager, sideBySide, stand
    }

    private nonisolated struct Shape: Equatable {
        var isWide = false
        var isStood = false
        /// Until measured, a regular width may yet turn out side by side or stood.
        var measured = false
    }

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Page? = .artwork
    @State private var tab = PanelTab.upNext
    @State private var shape = Shape()
    /// Off the artwork page, which the fixed clip behind the pager can't follow, so it gives way to the still on the page.
    @State private var paging = false

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            if let track = app.player.current {
                if #available(iOS 27.1, *), layout == .stand {
                    stand(track)
                } else {
                    NowPlayingTopBar(track: track, overClip: tallMotionShown)
                    if #available(iOS 27.1, *), layout == .sideBySide {
                        sideBySide(track)
                    } else {
                        pager(track)
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .onGeometryChange(for: Shape.self) { proxy in
            Shape(isWide: proxy.size.width > proxy.size.height, isStood: Fold.isStood(proxy), measured: true)
        } action: { shape = $0 }
        // Each layout starts at the artwork; stood, a tab left on lyrics would open them.
        .onChange(of: layout) {
            page = .artwork
            // A pager gone mid-swipe never says it stopped.
            paging = false
            if $1 == .stand { tab = .upNext }
        }
        // The clip is dark or bright whatever the look, so the bar and status bar over it are light, as in Apple Music.
        .preferredColorScheme(tallMotionShown ? .dark : app.theme.colorScheme)
        .background {
            NowPlayingBackground()
            ZStack {
                if let tallClip {
                    // By source, so another's crossfades in place rather than through the still.
                    TallMotion(clip: tallClip, active: tallMotionShown, onPage: page == .artwork)
                        .id(tallClip.id)
                        .transition(.opacity)
                }
            }
            .animation(MotionArtworkView.fade, value: tallClip?.id)
        }
        // On the panel, or stood lyrics, a pull down goes back to the artwork rather than closing the screen.
        .interactiveDismissDisabled((page == .panel && layout != .sideBySide) || (layout == .stand && lyricsShown))
        // In the look's own scheme, not the dark one over the clip.
        .sheet(item: $app.nowPlayingPicker) { PlaylistPickerSheet(track: $0).preferredColorScheme(app.theme.colorScheme).cappedTypeSize() }
        .onAppear { app.nowPlayingShown = true }
        .onDisappear {
            app.nowPlayingShown = false
            app.player.showsLyrics = false
        }
        // Set here, not as the lyrics appear, as opening or closing the phone swaps lyrics views in no set order.
        .onChange(of: lyricsShown, initial: true) { app.player.showsLyrics = $1 }
        .modifier(FoldToScrub(isSideBySide: layout == .sideBySide))
    }

    private var layout: Layout {
        if Fold.isSplit(sizeClass, isWide: shape.isWide) { return .sideBySide }
        return sizeClass == .regular && shape.isStood ? .stand : .pager
    }

    /// The player's, from its first frame, so the screen opens laid out for it; on a regular width only once measured,
    /// or the pager guessed at first would start it only to fade it out.
    private var tallClip: MotionClip? {
        layout == .pager && (shape.measured || sizeClass == .compact) && !reduceMotion ? app.player.motionClip : nil
    }

    private var tallMotionShown: Bool {
        tallClip != nil && page == .artwork && !paging
    }

    private var lyricsShown: Bool {
        tab == .lyrics && (layout != .pager || page == .panel)
    }

    private func pager(_ track: Track) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Each page hidden from VoiceOver while off screen, so it reads one set of controls.
                artworkPage(track, open: show)
                    .containerRelativeFrame(.vertical)
                    .accessibilityHidden(page != .artwork)
                    .id(Page.artwork)
                panelPage(track, select: show)
                    .containerRelativeFrame(.vertical)
                    .accessibilityHidden(page != .panel)
                    .id(Page.panel)
            }
            .scrollTargetLayout()
            .background(PagerBounceOff())
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        // The page counts as shown once past halfway, so a swipe down from the panel stays one page until it settles.
        .scrollPosition(id: $page, anchor: .center)
        // Off the artwork page, not merely touched or dragged by the zoom's close, which leaves the pager still.
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 0.5 } action: { paging = $1 }
        .scrollIndicators(.hidden)
    }

    @available(iOS 27.1, *)
    private func sideBySide(_ track: Track) -> some View {
        ArrangementView {
            artworkPage(track, open: select)
        } secondary: {
            SidePanel(tab: tab, isShown: true, select: select, close: nil)
        }
        .arrangementViewStyle(.split)
    }

    /// Stood, the upright half is out of reach, so every control is on the flat one.
    @available(iOS 27.1, *)
    private func stand(_ track: Track) -> some View {
        ArrangementView {
            if lyricsShown {
                LyricsPanel { standSelect(.lyrics) }
            } else {
                LargeArtwork(track: track, moves: true)
                    .padding(Self.padding)
            }
        } secondary: {
            // On the queue alone, even for the frame before a change of layout resets the tab.
            if page == .panel, tab == .upNext {
                panelPage(track, select: standSelect)
            } else {
                VStack(spacing: 0) {
                    NowPlayingTopBar(track: track)
                    Spacer(minLength: 0)
                    controls(track, open: standSelect)
                }
            }
        }
        .arrangementViewStyle(.split)
    }

    /// Lyrics swap in for the artwork above, and back again; the queue opens below.
    private func standSelect(_ next: PanelTab) {
        withAnimation(Theme.normal) {
            if next == .lyrics {
                tab = lyricsShown ? .upNext : .lyrics
                page = .artwork
            } else {
                tab = .upNext
                page = .panel
            }
        }
    }

    private func artworkPage(_ track: Track, open: @escaping (PanelTab) -> Void) -> some View {
        VStack(spacing: 0) {
            LargeArtwork(track: track, moves: layout != .pager, stillHidden: tallMotionShown)
                .accessibilityAction(named: "Up next") { open(.upNext) }
                .padding(.vertical, 12)
                .padding(.horizontal, Self.padding)
            controls(track, open: open)
        }
    }

    private func controls(_ track: Track, open: @escaping (PanelTab) -> Void) -> some View {
        VStack(spacing: 0) {
            TrackTitle(track: track, compact: false)
            Scrubber()
                .padding(.top, 12)
            TransportControls()
            PlayerOptions(open: open)
        }
        .padding(.horizontal, Self.padding)
    }

    private func panelPage(_ track: Track, select: @escaping (PanelTab) -> Void) -> some View {
        VStack(spacing: 0) {
            CompactControls(track: track)
            SidePanel(tab: tab, isShown: page == .panel, select: select) {
                withAnimation(Theme.normal) { page = .artwork }
            }
        }
    }

    private func select(_ next: PanelTab) {
        withAnimation(Theme.normal) { tab = next }
    }

    private func show(_ next: PanelTab) {
        withAnimation(Theme.normal) {
            tab = next
            page = .panel
        }
    }
}

/// Stops the pager bouncing, so a swipe down at the artwork goes straight to the zoom's close; `scrollBounceBehavior`
/// can't while content overflows. Its nearest scroll view is the pager, never the queue, which needs its bounce.
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
                IconButton(icon: .next, size: 44, iconSize: 26, colour: theme.text, feedback: .skip) { app.player.next() }
                    .accessibilityLabel("Next")
            }
            MiniProgress()
        }
        .padding(.horizontal, NowPlayingScreen.padding)
        .padding(.vertical, 8)
    }
}

/// The menu leaves out rating, which is beside the title, and queueing, of no use for the song playing.
private struct NowPlayingTopBar: View {
    let track: Track
    var overClip = false

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        let colour = overClip ? .white : theme.text
        HStack {
            IconButton(icon: .close, size: 40, iconSize: 22, colour: colour) { dismiss() }
                .accessibilityLabel("Close")
            Spacer()
            Menu {
                if app.isSignedIn {
                    Button("Save to playlist") { app.addToPlaylist(track) }
                    PinItem(card: Card(song: track))
                }
                TrackDownloadItem(track: track)
                TrackLinks(track: track)
            } label: {
                IconView(icon: .more, size: 22, colour: colour)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, NowPlayingScreen.padding - 8)
        .padding(.top, 12)
    }
}

/// Apple Music's way: the whole width at the top, under the bar, fading into the background below.
private struct TallMotion: View {
    let clip: MotionClip
    let active: Bool
    /// Off the page, the player and its buffers go, made again from the file on return.
    let onPage: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    /// The video has drawn, and fades in over its first frame only to hide the frame's lower resolution.
    @State private var drawn = false

    private static let mask = LinearGradient(
        stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Shades the clip under the status bar and the top bar's light icons, as a bright clip would hide them.
    private static let scrim = LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)

    var body: some View {
        GeometryReader { space in
            ZStack {
                Image(decorative: clip.frame, scale: 1)
                    .resizable()
                    .scaledToFill()
                // Likewise in the background.
                if let file = clip.file, onPage, scenePhase != .background {
                    LoopingVideo(url: file, playing: active && app.player.isPlaying && scenePhase == .active) {
                        drawn = true
                    }
                    .opacity(drawn ? 1 : 0)
                    .animation(MotionArtworkView.fade, value: drawn)
                    .onDisappear { drawn = false }
                }
            }
            // A shorter screen, as iPhone Duo's outer one, crops it rather than run it under the controls.
            .frame(width: space.size.width, height: min(space.size.width * 4 / 3, space.size.height * 0.62))
            .clipped()
            .overlay(alignment: .top) { Self.scrim.frame(height: 160) }
            .mask(Self.mask)
        }
        .ignoresSafeArea()
        .opacity(active ? 1 : 0)
        .animation(MotionArtworkView.fade, value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The artwork's colours where they sit in it, as a blurred copy would show them without the cost of blurring.
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
