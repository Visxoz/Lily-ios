import CoreGraphics
import YTMCore

/// The colours ytm-native takes from artwork (`images::accent` and `vivid`):
/// a dark one for behind white text, and a saturated one for controls when
/// the accent follows the artwork.
nonisolated struct ArtworkColours: Equatable, Sendable {
    let background: RGB
    /// Nil for greyish artwork, whose hue means nothing.
    let vivid: RGB?

    /// Sampled off the main actor, as decoding artwork is.
    @concurrent
    static func of(_ image: CGImage) async -> ArtworkColours {
        let background = ArtworkPalette.accent(image)
        return ArtworkColours(background: background, vivid: ArtworkPalette.vivid(background))
    }

    /// The colours of the artwork at `url`, decoded at `pixelEdge`, or nil
    /// when it can't be had.
    static func of(url: String, pixelEdge: Int) async -> ArtworkColours? {
        guard let image = await ImagePipeline.shared.image(for: url, pixelEdge: pixelEdge), !Task.isCancelled else {
            return nil
        }
        return await of(image)
    }
}
