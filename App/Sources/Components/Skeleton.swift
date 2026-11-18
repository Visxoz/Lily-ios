import SwiftUI
import YTMCore

/// A wash in the shape of something still loading.
struct Bone: View {
    var width: CGFloat?
    var height: CGFloat?
    var radius: CGFloat = 4

    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(theme.ink.opacity(0.1))
            .frame(width: width, height: height)
    }

    /// Ragged, so lines read as text.
    private static let lengths: [CGFloat] = [170, 120, 150, 100, 140, 180, 130]

    static func length(_ index: Int) -> CGFloat {
        lengths[index % lengths.count]
    }
}

extension View {
    /// Shown after 250 ms, so a quick load never flashes it, then pulsing.
    func skeleton() -> some View {
        modifier(SkeletonPulse())
    }
}

private struct SkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var due = false

    func body(content: Content) -> some View {
        content
            .phaseAnimator(reduceMotion ? [1] : [1, 0.5]) { bones, opacity in
                bones.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
            .opacity(due ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                withAnimation(Theme.normal) { due = true }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
    }
}

/// Shaped as the route's page builder lays it out, so the page lands in place.
struct PageSkeleton: View {
    let route: Route

    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch route {
                case .album, .playlist, .history, .librarySongs:
                    HeaderBones(art: true)
                    // Its space only.
                    TrackColumns()
                        .hidden()
                        .padding(.horizontal, Metrics.pagePadding)
                    TrackBones(count: 10, art: !isAlbum)
                case .artist:
                    BannerBones()
                    SectionBones(layouts: [nil])
                case .libraryPlaylists, .libraryAlbums, .libraryArtists:
                    HeaderBones(art: false)
                    GridBones()
                case .browse, .newReleases:
                    // Grids: a discography, most often, or new releases.
                    HeaderBones(art: false, label: false)
                    GridBones()
                case .library, .downloads:
                    SectionBones(layouts: [.grid])
                case .explore:
                    SectionBones(layouts: [.chips, .chips])
                case .moodsAndGenres:
                    HeaderBones(art: false, label: false)
                    SectionBones(layouts: [.chips])
                case .search:
                    SectionBones(layouts: [nil])
                case .genre:
                    HeaderBones(art: false)
                    SectionBones(layouts: [.carousel, .carousel])
                case .charts:
                    HeaderBones(art: false, label: false)
                    SectionBones(layouts: [.carousel, .carousel])
                case .home:
                    Bone(width: 220, height: 28)
                        .padding(.horizontal, Metrics.pagePadding)
                        .frame(height: Metrics.greetingHeight, alignment: .bottom)
                    // Signed out, the charts.
                    SectionBones(layouts: app.isSignedIn ? YTMusic.homeShelves.map(\.layout) : [nil, .carousel, .carousel, .chips])
                }
            }
        }
        .scrollDisabled(true)
        .skeleton()
    }

    private var isAlbum: Bool {
        if case .album = route { true } else { false }
    }
}

/// `TrackRow`s; an album's have no art.
struct TrackBones: View {
    let count: Int
    let art: Bool

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            HStack(spacing: Metrics.rowSpacing) {
                Bone(width: 14, height: 12)
                    .frame(width: Metrics.rowNumber)
                if art {
                    Bone(width: Metrics.rowArt, height: Metrics.rowArt)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Bone(width: Bone.length(index), height: 12)
                    Bone(width: Bone.length(index + 3) * 0.6, height: 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Metrics.rowPadding)
            .frame(height: Metrics.rowHeight)
            .padding(.horizontal, Metrics.pagePadding)
        }
    }
}

/// Titled sections in these layouts; nil is a song list.
struct SectionBones: View {
    let layouts: [CardLayout?]

    var body: some View {
        ForEach(layouts.indices, id: \.self) { index in
            SectionTitleBone()
            switch layouts[index] {
            case nil: TrackBones(count: 10, art: true)
            case .speedDial?: SpeedDialBones()
            case .grid?: GridBones()
            case .chips?: ChipBones()
            case .carousel?, .top?: CarouselBones()
            }
        }
    }
}

private struct CarouselBones: View {
    var body: some View {
        HStack(spacing: Metrics.cardGap) {
            ForEach(0..<3, id: \.self) { _ in
                CardBones()
                    .frame(width: Metrics.cardWidth)
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
        // Runs off the edge; the zero minimum stops it widening the page.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.bottom, 8)
    }
}

private struct SectionTitleBone: View {
    var body: some View {
        Bone(width: 160, height: 22)
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .frame(minHeight: Metrics.titleHeight, alignment: .bottom)
    }
}

/// As wide as it is given, as `CardView` is.
private struct CardBones: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Bone(radius: Metrics.cardArtRadius)
                .aspectRatio(1, contentMode: .fit)
                .padding(.bottom, 4)
            Bone(height: 12)
                .padding(.trailing, 30)
            Bone(height: 10)
                .padding(.trailing, 78)
        }
    }
}

/// Adaptive columns size as `CardGrid`'s do.
private struct GridBones: View {
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Metrics.cardWidth), spacing: Metrics.cardGap, alignment: .top)],
            alignment: .leading,
            spacing: Metrics.cardGap * 2
        ) {
            ForEach(0..<6, id: \.self) { _ in CardBones() }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }
}

/// `SpeedDial`'s first page and its dots.
private struct SpeedDialBones: View {
    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.cardGap), count: 3), spacing: Metrics.cardGap) {
                ForEach(0..<9, id: \.self) { _ in
                    Bone(radius: 10)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in Bone(width: 8, height: 8, radius: 4) }
            }
        }
        .padding(.bottom, 8)
    }
}

/// `GenreGrid`'s tiles.
private struct ChipBones: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.chipMinWidth), spacing: Metrics.chipGap)], spacing: Metrics.chipGap) {
            ForEach(0..<8, id: \.self) { _ in Bone(height: Metrics.chipHeight, radius: 8) }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }
}

/// Only a header with art has songs, so details and actions.
private struct HeaderBones: View {
    let art: Bool
    var label = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if art {
                Bone(width: Metrics.headerArt, height: Metrics.headerArt, radius: Metrics.cardArtRadius)
                    .frame(maxWidth: .infinity)
            }
            HeaderTextBones(label: label, details: art)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 16)
        .padding(.bottom, 24)
        if art {
            ActionBones()
        }
    }
}

/// Stops at the bar; the real banner reaches under it.
private struct BannerBones: View {
    var body: some View {
        Bone(height: Metrics.bannerHeight, radius: 0)
            .overlay(alignment: .bottomLeading) {
                HeaderTextBones(label: true, details: true)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.bottom, 24)
            }
        ActionBones()
    }
}

/// `HeaderText`'s lines, at their heights; it leaves out an empty label or details.
private struct HeaderTextBones: View {
    let label: Bool
    let details: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if label {
                Bone(width: 70, height: 12)
                    .frame(height: 17)
            }
            Bone(width: 220, height: 40)
                .frame(height: 52)
            if details {
                Bone(width: 160, height: 12)
                    .frame(height: 17)
            }
        }
    }
}

private struct ActionBones: View {
    var body: some View {
        HStack(spacing: 20) {
            Bone(width: 56, height: 56, radius: 28)
            Bone(width: 48, height: 48, radius: 24)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .frame(height: Metrics.actionsHeight)
    }
}
