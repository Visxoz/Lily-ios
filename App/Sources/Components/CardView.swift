import SwiftUI
import YTMCore

/// ytm-native's `Card` (`page/cards.slint`): artwork, round for artists, over
/// the title and subtitle. Tapping opens it (a song plays); holding offers
/// Play and Start radio.
struct CardView: View {
    let card: Card
    let width: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    /// Every card's decode, whatever its layout: carousel and grid cards share
    /// one, so a grid of art already seen in a carousel draws on its first
    /// frame, as ytm-native decodes every card at one size.
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(card.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.97))
        .contextMenu { CardMenu(card: card) }
    }
}

/// ytm-native's `Carousel`: a row of cards. The finger scrolls it in place of
/// the desktop's arrows, and it settles on whole cards as they do.
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

/// ytm-native's `CardGrid`: as many cards a row as fit `width`.
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
