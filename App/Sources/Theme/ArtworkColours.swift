import CoreGraphics
import CoreImage
import YTMCore

nonisolated struct ArtworkColours: Equatable, Sendable {
    /// Nil for greyish artwork, whose hue means nothing.
    let vivid: RGB?
    /// `ArtworkPalette.meshEdge` squared, row by row from the top.
    let mesh: [RGB]

    @concurrent
    static func of(_ image: CGImage) async -> ArtworkColours {
        let (accent, mesh) = ArtworkPalette.colours(image)
        return ArtworkColours(vivid: ArtworkPalette.vivid(accent), mesh: mesh)
    }

    /// Nil when the artwork can't be had.
    static func of(url: String, pixelEdge: Int) async -> ArtworkColours? {
        guard let image = await image(url, pixelEdge: pixelEdge) else { return nil }
        return await of(image)
    }

    /// Made once, as Core Image contexts are costly to set up and safe to share.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// A page's tint, and its artwork frosted for behind its header; `maxWidth` as the banner's, so both share one decode.
    @concurrent
    static func backdrop(url: String, pixelEdge: Int, maxWidth: Int? = nil) async -> PageBackdrop? {
        guard let image = await image(url, pixelEdge: pixelEdge, maxWidth: maxWidth) else { return nil }
        return PageBackdrop(tint: ArtworkPalette.accent(image), frosted: frost(image))
    }

    /// Blurred once here, not by the view on every frame, and shrunk first as nothing sharp survives the blur.
    private static func frost(_ image: CGImage) -> Frosted? {
        let frostedEdge = 64.0
        let scale = frostedEdge / Double(min(image.width, image.height))
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let frosted = small.clampedToExtent()
            .applyingGaussianBlur(sigma: frostedEdge / 20)
            // A little livelier, as a blur greys colours that sat side by side.
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15])
            .cropped(to: small.extent.integral)
        guard let output = context.createCGImage(frosted, from: frosted.extent) else { return nil }
        var mean = [UInt8](repeating: 0, count: 4)
        let average = frosted.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: frosted.extent)])
        context.render(
            average, toBitmap: &mean, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        let colour = RGB(r: Double(mean[0]) / 255, g: Double(mean[1]) / 255, b: Double(mean[2]) / 255)
        return Frosted(image: output, luminance: ArtworkPalette.luminance(colour))
    }

    private static func image(_ url: String, pixelEdge: Int, maxWidth: Int? = nil) async -> CGImage? {
        let image = await ImagePipeline.shared.image(for: url, pixelEdge: pixelEdge, maxWidth: maxWidth)
        return Task.isCancelled ? nil : image
    }
}

/// The colour a page is tinted, and its artwork blurred as if behind frosted glass.
nonisolated struct PageBackdrop: Sendable {
    let tint: RGB
    let frosted: Frosted?
}

nonisolated struct Frosted: Sendable {
    let image: CGImage
    /// WCAG relative luminance of its mean colour, which sets how thick the frost over it must be.
    let luminance: Double
}
