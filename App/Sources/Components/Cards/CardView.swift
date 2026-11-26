import SwiftUI
import YTMCore

extension EnvironmentValues {
    /// Pinned cards show a badge: on Library and its See all pages.
    @Entry var showsPinBadges = false
}

struct CardView: View {
    let card: Card
    let width: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.showsPinBadges) private var showsPinBadges

    /// Carousel and grid cards share one decode, so art already seen in a carousel draws at once.
    static func artPixels(scale: CGFloat) -> Int {
        ArtworkImage.pixels(edge: Metrics.cardWidth, scale: scale)
    }

    var body: some View {
        Button { app.activate(card, displayScale: displayScale) } label: {
            VStack(alignment: .leading, spacing: 4) {
                ArtworkView(
                    url: card.thumbnail, size: width, round: card.kind == .artist, radius: Metrics.cardArtRadius,
                    pixelEdge: Self.artPixels(scale: displayScale), shadow: (theme.shadowSoft, 8, 6)
                )
                    .padding(.bottom, 4)
                Text(card.title)
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(theme.text)
                HStack(spacing: 4) {
                    if showsPinBadges { PinBadge(card: card) }
                    Text(card.subtitle)
                        .scaledFont(13)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.97))
        .contextMenu { CardMenu(card: card) }
    }
}

/// Its own view, so a pin redraws the badge rather than the card.
private struct PinBadge: View {
    let card: Card

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if app.isPinned(card) {
            IconView(icon: .pin, size: 14, colour: theme.accent)
                .accessibilityLabel("Pinned")
        }
    }
}

struct CarouselRow: View {
    let cards: [Card]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Metrics.cardGap) {
                ForEach(cards.indices, id: \.self) { index in
                    CardView(card: cards[index], width: Metrics.cardWidth)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, Metrics.pagePadding, for: .scrollContent)
        .scrollClipDisabled()
    }
}

struct CardGrid: View {
    let cards: [Card]
    let width: CGFloat

    var body: some View {
        let (count, cell) = Metrics.cardColumns(width: width)
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cell), spacing: Metrics.cardGap, alignment: .top), count: count),
            alignment: .leading,
            spacing: Metrics.cardGap * 2
        ) {
            ForEach(cards.indices, id: \.self) { index in
                CardView(card: cards[index], width: cell)
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }
}
