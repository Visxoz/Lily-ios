import SwiftUI
import YTMCore

/// A loaded page, as ytm-native's `PageView` and `PageRow`: under a tint
/// that scrolls with it, Home's greeting, the header, then every section, in
/// one lazy stack so only rows near the screen are built. The page's title
/// takes the bar once the header has scrolled away.
struct PageContent: View {
    let page: Page
    let route: Route
    /// Loads further steps of the page and refreshes it; nil for a page held
    /// on the device, as the songs played are.
    var model: PageModel?

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var frame = Frame()
    @State private var position = ScrollPosition(edge: .top)
    @State private var titleShown = false
    /// The header artwork's colour, once sampled.
    @State private var artworkTint: RGB?

    /// Header colours already sampled, so a page opened again starts in its
    /// colour, as ytm-native's accent cache has it. Keyed by URL alone, as
    /// the size isn't known until the header is measured and doesn't change
    /// the colour.
    @MainActor private static var tints: [String: RGB] = [:]

    /// The scroll view's width and the bar's height over it.
    private nonisolated struct Frame: Equatable {
        var width: CGFloat = 0
        var top: CGFloat = 0
    }

    /// The header artwork sampled for the tint, at the pixels it is drawn.
    private nonisolated struct TintSource: Hashable {
        let url: String
        let pixels: Int
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if route == .home {
                    Greeting()
                }
                if let header = page.header {
                    PageHeaderView(
                        header: header,
                        canPlay: canPlay,
                        canShuffle: canPlay || header.shufflePlaylistId != nil,
                        canRadio: header.radioId != nil,
                        topInset: frame.top
                    ) { app.perform($0, on: page) }
                }
                ForEach(page.sections.indices, id: \.self) { index in
                    SectionRows(section: page.sections[index], width: frame.width - 2 * Metrics.pagePadding)
                }
                // The rest loads while the page is on screen (`PageScreen`).
                if page.more != nil {
                    Spinner(size: 28)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
            }
            .padding(.bottom, Metrics.pageBottom)
            .background(alignment: .top) {
                PageTint(colour: artworkTint ?? tintSource.flatMap { Self.tints[$0.url] } ?? Theme.routeTint(route), top: frame.top)
                    .modifier(PastEdges())
            }
        }
        // Clipped as before, but past the sides while the page's colours are.
        .scrollClipDisabled()
        .mask { Rectangle().modifier(PastEdges()).ignoresSafeArea() }
        .scrollPosition($position)
        .onChange(of: model?.replacements) { position.scrollTo(edge: .top) }
        .background { theme.panel.modifier(PastEdges()).ignoresSafeArea() }
        // The tint runs unbroken under the bar, whose edge shows only with
        // the sticky title, as ytm-native's.
        .scrollEdgeEffectHidden(!titleShown, for: .top)
        .onGeometryChange(for: Frame.self) { proxy in
            Frame(width: proxy.size.width, top: proxy.safeAreaInsets.top)
        } action: { frame = $0 }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > Metrics.stickyTitleAfter
        } action: { _, shown in
            titleShown = shown
        }
        .navigationTitle(page.header?.title ?? "")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let header = page.header {
                ToolbarItem(placement: .principal) {
                    StickyTitle(title: header.title, canPlay: canPlay) { app.perform(.play, on: page) }
                        .opacity(titleShown ? 1 : 0)
                        .animation(Theme.normal, value: titleShown)
                }
            }
        }
        .modifier(Refresh(model: model))
        .task(id: tintSource) {
            guard let tintSource else { return }
            // Held in the view too, as another page may empty the cache while this one stays in a stack.
            if let cached = Self.tints[tintSource.url] {
                artworkTint = cached
                return
            }
            if let colours = await ArtworkColours.of(url: tintSource.url, pixelEdge: tintSource.pixels) {
                artworkTint = colours.background
                // shortcut: drops everything once full; upgrade to LRU only if revisits show the fade again.
                if Self.tints.count >= 64 { Self.tints.removeAll() }
                Self.tints[tintSource.url] = colours.background
            }
        }
        // As ytm-native's `load_art`: the page's art is fetched as the page is
        // built, rather than as each row scrolls in, and stops once it is left.
        .task(id: [itemCount, model?.replacements ?? 0]) { await prefetchArt() }
    }

    private var canPlay: Bool {
        !page.headerTracks.isEmpty
    }

    /// Tracks and cards on the page, so a further step, which may only grow
    /// one section's tracks, fetches its art too.
    private var itemCount: Int {
        page.sections.reduce(0) { count, section in
            switch section {
            case .tracks(let s): count + s.tracks.count
            case .cards(let s): count + s.cards.count
            }
        }
    }

    /// Downloads the art of every track row, then every card, at the pixels
    /// each will be drawn at. Albums' numbered rows and the chips and top
    /// result draw none of it, or their own, so they are left out.
    private func prefetchArt() async {
        // The first screen's own loads go first, so none is asked for twice.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        var tracks: [String] = []
        var cards: [String] = []
        for section in page.sections {
            switch section {
            case .tracks(let s) where !s.numbered:
                tracks += s.tracks.compactMap(\.thumbnail)
            case .cards(let s) where s.layout == .carousel || s.layout == .grid:
                cards += s.cards.compactMap(\.thumbnail)
            case .tracks, .cards:
                break
            }
        }
        await ImagePipeline.shared.prefetch(tracks, pixelEdge: ArtworkImage.pixels(edge: Metrics.rowArt, scale: displayScale))
        await ImagePipeline.shared.prefetch(cards, pixelEdge: CardView.artPixels(scale: displayScale))
    }

    private var tintSource: TintSource? {
        guard let header = page.header, let url = header.thumbnail else { return nil }
        let edge = PageHeaderView.artEdge(header, topInset: frame.top)
        return TintSource(url: url, pixels: Int((edge * displayScale).rounded(.up)))
    }
}

/// "Good morning" and so on, by the local time, as ytm-native greets Home.
private struct Greeting: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text(Self.greeting(hour: Calendar.current.component(.hour, from: .now)))
            .font(.system(size: 32, weight: .heavy))
            .foregroundStyle(theme.text)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Metrics.pagePadding)
            .frame(height: Metrics.greetingHeight, alignment: .bottom)
    }

    private static func greeting(hour: Int) -> String {
        switch hour {
        case 4..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<23: "Good evening"
        default: "Good night"
        }
    }
}

/// The page's colour fading into the panel behind its top, reaching up under
/// the bar, and easing to a new colour as ytm-native's does. Above the page
/// it carries on solid, so pulling to refresh opens on the colour rather
/// than on the bare panel.
struct PageTint: View {
    /// Further than a pull can open.
    private static let overscroll: CGFloat = 1000

    let colour: RGB?
    let top: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        let tint = theme.pageTint(colour)
        LinearGradient(colors: [tint, theme.panel], startPoint: .top, endPoint: .bottom)
            .frame(height: Metrics.tintHeight + top)
            .background(alignment: .top) {
                tint
                    .frame(height: Self.overscroll)
                    .offset(y: -Self.overscroll)
            }
            .padding(.top, -top)
            .animation(.easeOut(duration: 0.5), value: colour)
            .accessibilityHidden(true)
    }
}

/// While Now Playing opens, shows or closes, the page's colours run past
/// the screen's sides. The zoom shrinks the screen behind it a little, which
/// would otherwise show the black behind the app down each side. Only then,
/// as a page sliding in or out would show them over the page beside it.
private struct PastEdges: ViewModifier {
    static let width: CGFloat = 16

    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.padding(.horizontal, app.sheet == .nowPlaying || app.nowPlayingShown ? -Self.width : 0)
    }
}

/// The bar's title once the header has scrolled away, with Play beside it
/// as ytm-native's sticky title has.
private struct StickyTitle: View {
    let title: String
    let canPlay: Bool
    let play: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if canPlay {
                PlayButton(size: 30, action: play)
            }
            Text(title)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(theme.text)
                .lineLimit(1)
        }
    }
}

/// Pull to refresh, for pages fetched from YouTube.
private struct Refresh: ViewModifier {
    let model: PageModel?

    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        if let model {
            content.refreshable { await model.refresh(in: app) }
        } else {
            content
        }
    }
}
