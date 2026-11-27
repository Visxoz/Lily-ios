import SwiftUI
import YTMCore

struct SpeedDial: View {
    let cards: [Card]
    /// The page's width inside its padding.
    let width: CGFloat

    @State private var page: Int? = 0

    private static let columns = 3
    private static let perPage = 9
    /// Past a phone's width, as on iPhone Duo's inner display, a page this wide is as tall as the screen, so the next
    /// one shows beside it instead.
    static let maxPageWidth: CGFloat = 420
    static let gap: CGFloat = 5
    static let radius: CGFloat = 10

    /// The die ends the last page, as YouTube's does.
    private enum Tile {
        case card(Card)
        case die
    }

    var body: some View {
        let pageWidth = min(width, Self.maxPageWidth)
        let cell = (pageWidth - CGFloat(Self.columns - 1) * Self.gap) / CGFloat(Self.columns)
        let pages = Self.pages(of: cards)
        // Every page as tall as a full one, so the dots stay put; a lone page as tall as its rows.
        let rows = pages.count > 1 ? 3 : Self.rows(pages.first?.count ?? 0)
        VStack(spacing: 16) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 2 * Metrics.pagePadding) {
                    ForEach(pages.indices, id: \.self) { index in
                        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
                            ForEach(0..<Self.rows(pages[index].count), id: \.self) { row in
                                GridRow {
                                    ForEach(pages[index].indices.dropFirst(row * Self.columns).prefix(Self.columns), id: \.self) { slot in
                                        tile(pages[index][slot], size: cell)
                                    }
                                }
                            }
                        }
                        .frame(width: pageWidth, height: CGFloat(rows) * cell + CGFloat(max(rows - 1, 0)) * Self.gap, alignment: .topLeading)
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .contentMargins(.leading, Metrics.pagePadding, for: .scrollContent)
            // Room after the last page for it to scroll to the front, so its dot can light.
            .contentMargins(.trailing, Metrics.pagePadding + width - pageWidth, for: .scrollContent)
            .scrollClipDisabled()
            if pages.count > 1 {
                PageDots(count: pages.count, current: min(page ?? 0, pages.count - 1))
            }
        }
        .padding(.bottom, 8)
        // A fresh feed starts from its first page, as the page itself starts from the top.
        .onChange(of: cards) { page = 0 }
    }

    @ViewBuilder
    private func tile(_ tile: Tile, size: CGFloat) -> some View {
        switch tile {
        case .card(let card): SpeedDialTile(card: card, size: size)
        case .die: SpeedDialDie(cards: cards, size: size)
        }
    }

    private static func pages(of cards: [Card]) -> [[Tile]] {
        var tiles = cards.map(Tile.card)
        if !tiles.isEmpty { tiles.append(.die) }
        return stride(from: 0, to: tiles.count, by: perPage).map { Array(tiles[$0..<min($0 + perPage, tiles.count)]) }
    }

    private static func rows(_ count: Int) -> Int {
        (count + columns - 1) / columns
    }
}

private struct SpeedDialTile: View {
    let card: Card
    let size: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    private static let shade = LinearGradient(
        stops: [.init(color: .clear, location: 0), .init(color: Theme.titleShade, location: 0.6)],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        Button { app.activate(card, displayScale: displayScale) } label: {
            ZStack(alignment: .bottom) {
                ArtworkView(
                    url: card.thumbnail, size: size, round: card.kind == .artist, radius: 0,
                    pixelEdge: CardView.artPixels(scale: displayScale)
                )
                HStack(spacing: 2) {
                    Text(card.title)
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(theme.onColour)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if card.route != nil {
                        IconView(icon: .chevron, size: 16, colour: theme.onColour)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.bottom, 6)
                .padding(.top, 8)
                // On the title, not the tile, so the strip grows with the text.
                .background(Self.shade)
            }
            .frame(width: size, height: size)
            // Dark behind an artist's round art, so the strip darkens its corners evenly.
            .background(card.kind == .artist ? Color.black : theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: SpeedDial.radius))
            .overlay {
                if let track = card.track, app.isPlaying(track) {
                    RoundedRectangle(cornerRadius: SpeedDial.radius + 3)
                        .strokeBorder(theme.text, lineWidth: 2)
                        .padding(-3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.97))
        // The subtitle the tile has no room for says what it is, as a card's does.
        .accessibilityLabel(card.subtitle.isEmpty ? card.title : "\(card.title), \(card.subtitle)")
        .contextMenu { CardMenu(card: card) }
    }
}

private struct SpeedDialDie: View {
    let cards: [Card]
    let size: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            if let card = cards.randomElement() { app.play(card) }
        } label: {
            ZStack {
                let glow = [theme.accent.opacity(0.35), theme.accent.opacity(0)]
                // Black with paled dots in the dark looks; a light tile with softened ones in Light.
                let light = theme.isLight
                let dot = theme.accent.mix(with: theme.onColour, by: light ? 0.45 : 0.6).opacity(light ? 1 : 0.75)
                light ? theme.elevated : Color.black
                // The accent glows in from two opposite corners, as on YouTube's.
                RadialGradient(colors: glow, center: .topTrailing, startRadius: 0, endRadius: size * 0.6)
                RadialGradient(colors: glow, center: .bottomLeading, startRadius: 0, endRadius: size * 0.6)
                // A die's three, corner to corner.
                ForEach(-1...1, id: \.self) { step in
                    Circle()
                        .fill(dot)
                        .frame(width: size * 0.2, height: size * 0.2)
                        .offset(x: CGFloat(step) * size * 0.26, y: CGFloat(step) * size * 0.26)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: SpeedDial.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.97))
        .accessibilityLabel("Play one at random")
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? theme.text : theme.textDim)
                    .frame(width: 8, height: 8)
            }
        }
        .animation(Theme.normal, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
