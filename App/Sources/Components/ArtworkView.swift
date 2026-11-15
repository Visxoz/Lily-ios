import SwiftUI
import YTMCore

/// ytm-native's `Art` (`widgets/art.slint`): square artwork with rounded
/// corners, or round for artists, over a placeholder note until it loads.
struct ArtworkView: View {
    let url: String?
    let size: CGFloat
    var round = false
    var radius: CGFloat = 4
    /// The decode's edge in pixels, for artwork sharing a decode made for
    /// elsewhere rather than one at the size drawn.
    var pixelEdge: Int?

    @Environment(\.theme) private var theme

    var body: some View {
        ArtworkImage(url: url, edge: size, pixelEdge: pixelEdge)
            .frame(width: size, height: size)
            .background(theme.highlight)
            .clipShape(RoundedRectangle(cornerRadius: round ? size / 2 : radius))
    }
}

/// Artwork filling its frame, decoded by `ImagePipeline` at the pixels shown,
/// except that small artwork shares one size, `ImagePipeline.smallEdge`, so a
/// song's rows, mini player and queue entry reuse one decode. An image already
/// in memory shows on the first frame, so scrolling back never flickers, as
/// does the song's copy at a shared size while its own loads; one fetched
/// fades in, and the fetch is cancelled when the view goes.
struct ArtworkImage: View {
    let url: String?
    /// The shorter side drawn, in points: what the decode is sized to.
    let edge: CGFloat
    /// Shows the note while there is no image, as square artwork does.
    var placeholder = true
    /// The decode's edge in pixels, in place of the edge drawn.
    var pixelEdge: Int?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.theme) private var theme
    @State private var loaded: Loaded?

    private struct Key: Hashable {
        let url: String
        let pixels: Int
    }

    private struct Loaded {
        let key: Key
        let image: CGImage
    }

    var body: some View {
        let key = url.map { Key(url: $0, pixels: pixels) }
        ZStack {
            if let key, let image = image(for: key) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if placeholder {
                IconView(icon: .note, size: edge * 0.38, colour: theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: key) { await load(key) }
    }

    /// The decode's edge: as asked, else what is drawn, or the shared small size.
    private var pixels: Int {
        pixelEdge ?? max(Int((edge * displayScale).rounded(.up)), ImagePipeline.smallEdge)
    }

    /// The loaded image, or until the load has run, one already in memory:
    /// at this size, else at the shared sizes the mini player and the lock
    /// screen decode, scaled until this size comes.
    private func image(for key: Key) -> CGImage? {
        if let loaded, loaded.key == key { return loaded.image }
        return [key.pixels, ImagePipeline.playerEdge, ImagePipeline.smallEdge].lazy
            .compactMap { ImagePipeline.shared.cachedImage(for: key.url, pixelEdge: $0) }
            .first
    }

    private func load(_ key: Key?) async {
        guard let key, loaded?.key != key else { return }
        if let image = ImagePipeline.shared.cachedImage(for: key.url, pixelEdge: key.pixels) {
            loaded = Loaded(key: key, image: image)
            return
        }
        guard let image = await ImagePipeline.shared.image(for: key.url, pixelEdge: key.pixels), !Task.isCancelled else {
            return
        }
        withAnimation(.easeOut(duration: 0.3)) { loaded = Loaded(key: key, image: image) }
    }
}
