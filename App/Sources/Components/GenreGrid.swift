import SwiftUI
import YTMCore

/// ytm-native's `GenreGrid`: the moods and genres as large colour tiles, as
/// many a row as fit `width`.
struct GenreGrid: View {
    let cards: [Card]
    let width: CGFloat

    var body: some View {
        let (count, cell) = Metrics.chipColumns(width: width)
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cell), spacing: Metrics.chipGap), count: count),
            spacing: Metrics.chipGap
        ) {
            ForEach(cards.indices, id: \.self) { index in
                GenreTile(card: cards[index])
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }
}

/// ytm-native's `GenreTile`: YouTube's colour for the genre, darkening
/// across the tile, its name, and a tilted square in the corner.
struct GenreTile: View {
    let card: Card

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        Button { app.activate(card) } label: {
            ZStack(alignment: .topLeading) {
                background
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.onColour.opacity(0.133))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(25))
                    .offset(x: 12, y: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                Text(card.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.onColour)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }
            .frame(height: Metrics.chipHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressScale(scale: 0.97))
    }

    @ViewBuilder private var background: some View {
        if let hex = card.color {
            let colour = RGB(hex: hex)
            LinearGradient(
                colors: [Color(rgb: colour), Color(rgb: colour.darker(0.45))],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            theme.highlight
        }
    }
}
