import SwiftUI
import YTMCore

/// Above the page it carries on, so pulling to refresh opens on the
/// colour rather than on the bare panel.
struct PageTint: View {
    /// Further than a pull can open.
    static let overscroll: CGFloat = 1000

    let colour: RGB?
    /// The artwork blurred, as if behind frosted glass; without it the page is tinted evenly.
    var frosted: Frosted?
    let top: CGFloat

    @Environment(\.theme) private var theme

    /// Opaque from `edge` to `start`, then gone by `end` on a cosine ease,
    /// so there is no line where a straight fade would visibly end.
    static func fade(from start: Double = 0, to end: Double = 1, edge: UnitPoint = .top) -> LinearGradient {
        let stops = (0...12).map { step in
            let t = Double(step) / 12
            return Gradient.Stop(color: .black.opacity((1 + cos(.pi * t)) / 2), location: start + (end - start) * t)
        }
        return LinearGradient(stops: stops, startPoint: edge, endPoint: UnitPoint(x: 1 - edge.x, y: 1 - edge.y))
    }

    var body: some View {
        let tint = theme.pageTint(colour)
        glass(tint)
            .background(alignment: .top) {
                tint
                    .frame(height: Self.overscroll)
                    // Mirrored, so a pull to refresh opens on the artwork carried on rather than on a seam.
                    .overlay(alignment: .bottom) {
                        glass(tint).scaleEffect(y: -1)
                    }
                    .offset(y: -Self.overscroll)
            }
            .padding(.top, -top)
            // On under iPhone Duo's column of tabs, so the page's colour reaches the screen's edge.
            .ignoresSafeArea(edges: .horizontal)
            .animation(.easeOut(duration: 0.5), value: colour)
            .animation(.easeOut(duration: 0.5), value: frosted == nil)
            .accessibilityHidden(true)
    }

    /// The tint until the artwork is frosted, then the artwork; behind the artwork in full, gone by the songs.
    private func glass(_ tint: Color) -> some View {
        tint
            .overlay {
                if let frosted {
                    FrostedGlass(frosted: frosted)
                        .transition(.opacity)
                }
            }
            .frame(height: Metrics.tintHeight + top)
            .clipped()
            .mask(Self.fade(from: 0.3))
    }
}

/// Artwork already blurred by `ArtworkColours.backdrop`, filling its frame.
struct FrostedGlass: View {
    let frosted: Frosted

    @Environment(\.theme) private var theme

    var body: some View {
        Image(decorative: frosted.image, scale: 1)
            .interpolation(.high)
            .resizable()
            .scaledToFill()
            // The frost: the page's own colour over the glass, so text reads on it, thicker the more the artwork
            // fights the text: bright artwork in the dark looks, enough to bring its mean down to 0.25 luminance
            // where white text reads, and dark artwork in the light one. Never so thick the glass is lost.
            .overlay(theme.panel.opacity(frost))
    }

    private var frost: Double {
        let needed = theme.isLight ? 0.6 - frosted.luminance : 1 - 0.25 / max(frosted.luminance, 0.01)
        return min(max(needed, theme.isLight ? 0.4 : 0.3), 0.65)
    }
}
