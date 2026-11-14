import SwiftUI
import YTMCore

/// ytm-native's `PageHeader` (`page/header.slint`): an artist's banner with
/// the name over it, or an album's or playlist's artwork above its label,
/// title and details; then Play, Shuffle and Radio.
///
/// On a portrait screen the artwork sits above the text rather than beside
/// it, and the title is set smaller to fit.
struct PageHeaderView: View {
    let header: PageHeader
    let canPlay: Bool
    let canShuffle: Bool
    let canRadio: Bool
    /// The navigation bar's height, which a banner reaches up under.
    let topInset: CGFloat
    let perform: (HeaderAction) -> Void

    @Environment(\.theme) private var theme

    /// The shorter side of the header's artwork as drawn, which the page
    /// samples for its tint at the same size, so the decode is shared: a
    /// banner's height reaching up under the bar, or the square's edge.
    static func artEdge(_ header: PageHeader, topInset: CGFloat) -> CGFloat {
        header.banner ? Metrics.bannerHeight + topInset : Metrics.headerArt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if header.banner {
                let height = Self.artEdge(header, topInset: topInset)
                ZStack(alignment: .bottomLeading) {
                    ArtworkImage(url: header.thumbnail, edge: height, placeholder: false)
                        .frame(height: height)
                        .clipped()
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.35), .init(color: theme.bannerShade, location: 1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // A banner is darkened behind its text, which stays white in every look.
                    HeaderText(header: header, foreground: theme.onColour, secondary: theme.onColour.opacity(0.7))
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.bottom, 24)
                }
                .frame(height: height)
                .padding(.top, -topInset)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if header.thumbnail != nil || canPlay {
                        ArtworkView(url: header.thumbnail, size: Self.artEdge(header, topInset: topInset), radius: Metrics.cardArtRadius)
                            .shadow(color: theme.shadowDeep, radius: 20, y: 8)
                            .frame(maxWidth: .infinity)
                    }
                    HeaderText(header: header, foreground: theme.text, secondary: theme.textSecondary)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }

            if canPlay || canRadio {
                HStack(spacing: 20) {
                    if canPlay {
                        PlayButton(size: 56) { perform(.play) }
                    }
                    if canShuffle {
                        IconButton(icon: .shuffle, size: 48, iconSize: 30) { perform(.shuffle) }
                            .accessibilityLabel("Shuffle")
                    }
                    if canRadio {
                        IconButton(icon: .radio, size: 48, iconSize: 28) { perform(.radio) }
                            .accessibilityLabel("Start radio")
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
                .frame(height: Metrics.actionsHeight)
            }
        }
    }
}

/// The label, title and "subtitle • meta" line.
private struct HeaderText: View {
    let header: PageHeader
    let foreground: Color
    let secondary: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !header.label.isEmpty {
                Text(header.label)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(header.title)
                .font(.system(size: titleSize, weight: .heavy))
                .tracking(-0.5)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            details
                .font(.system(size: 14))
                .lineLimit(2)
        }
        .foregroundStyle(foreground)
    }

    @ViewBuilder private var details: some View {
        let subtitle = Text(header.subtitle).fontWeight(.bold)
        let meta = Text(header.meta).foregroundStyle(secondary)
        switch (header.subtitle.isEmpty, header.meta.isEmpty) {
        case (false, false): Text("\(subtitle)  •  \(meta)")
        case (false, true): subtitle
        case (true, false): meta
        case (true, true): EmptyView()
        }
    }

    /// Shorter titles set larger, as ytm-native steps them, scaled for the
    /// phone (desktop 76, 60, 44 and 34).
    private var titleSize: CGFloat {
        switch header.title.count {
        case ...12: 44
        case ...18: 38
        case ...28: 32
        default: 28
        }
    }
}
