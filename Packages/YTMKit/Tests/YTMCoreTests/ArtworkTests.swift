import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YTMCore

/// An sRGB image `width` × `height` coloured pixel by pixel.
private func image(_ width: Int = 8, _ height: Int = 8, _ colour: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = colour(x, y)
            bytes.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 3, with: [r, g, b])
        }
    }
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    return try #require(CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
}

/// What the downloads under test did, in order.
private actor DownloadLog {
    private(set) var events: [String] = []

    func add(_ event: String) {
        events.append(event)
    }
}

@Suite struct ArtworkPaletteTests {
    @Test func roundTripsHSL() {
        for colour in [RGB(r: 1, g: 0, b: 0), RGB(r: 0.2, g: 0.6, b: 0.4), RGB(r: 0.5, g: 0.5, b: 0.5), RGB(r: 0.1, g: 0.2, b: 0.9)] {
            let (h, s, l) = ArtworkPalette.hsl(colour)
            let back = ArtworkPalette.rgb(h, s, l)
            #expect(abs(back.r - colour.r) < 1e-9 && abs(back.g - colour.g) < 1e-9 && abs(back.b - colour.b) < 1e-9)
        }
    }

    @Test func accentKeepsTheHueAndDarkens() throws {
        let accent = ArtworkPalette.accent(try image { _, _ in (230, 20, 20) })
        #expect(accent.r > accent.g && accent.r > accent.b)
        #expect(accent.r < 180.0 / 255, "dark enough for white text")
        let bright = try #require(ArtworkPalette.vivid(accent), "red artwork has a hue")
        #expect(bright.r > accent.r, "brighter")
        #expect(bright.r > bright.g && bright.r > bright.b, "same hue")
        #expect(ArtworkPalette.vivid(try image { _, _ in (128, 128, 128) }) == nil, "no hue to follow")
    }

    @Test func followsMutedAndMixedArtwork() throws {
        let blue = try #require(ArtworkPalette.vivid(try image { _, _ in (90, 100, 130) }), "a bluish photo has a hue")
        #expect(blue.b > blue.r && blue.b > blue.g)

        // Red and cyan halves, which average to grey.
        let halves = try #require(ArtworkPalette.vivid(try image { x, _ in x < 4 ? (230, 20, 20) : (20, 230, 230) }))
        let hue = ArtworkPalette.hsl(halves).h
        #expect(!(15..<165).contains(hue) && !(195..<345).contains(hue), "red or cyan")

        // A quarter of sky over beige buildings, the dull area the larger.
        let sky = try #require(ArtworkPalette.vivid(try image { _, y in y < 2 ? (90, 150, 220) : (200, 170, 130) }))
        #expect(sky.b > sky.r, "the sky, not the beige")

        #expect(ArtworkPalette.vivid(try image { _, _ in (40, 36, 32) }) == nil, "a cast isn't a colour")
        let yellow = ArtworkPalette.accent(try image { _, _ in (240, 220, 20) })
        #expect(ArtworkPalette.luminance(yellow) <= 0.18, "white text still reads on it")
    }

    @Test func makesAccentsReadableInEachLook() {
        let green = RGB(hex: 0x1db954)
        #expect(ArtworkPalette.luminance(ArtworkPalette.readable(green, look: .light)) <= 0.18, "darkened on white")
        let red = RGB(hex: 0xff0033)
        #expect(ArtworkPalette.readable(red, look: .dark) == red, "already fine on black")
        let blue = RGB(hex: 0x0000ff)
        #expect(ArtworkPalette.luminance(ArtworkPalette.readable(blue, look: .black)) >= 0.175, "lightened on black")
        let fixed = ArtworkPalette.readable(RGB(hex: 0xeeee22), look: .dark)
        #expect(ArtworkPalette.luminance(fixed) <= 0.3, "dark enough behind white icons")
        #expect(fixed.r > fixed.b, "keeps its hue")
    }
}

@Suite struct ImagePipelineTests {
    @Test func asksForTheSizeDrawnButKeepsBannersWide() {
        let square = "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj"
        #expect(ImagePipeline.requestURL(square, edge: 240)?.absoluteString == "https://lh3.googleusercontent.com/abc=w240-h240-l90-rj")
        let banner = "https://lh3.googleusercontent.com/abc=w1440-h600-p-l90-rj"
        #expect(ImagePipeline.isWide(banner))
        #expect(ImagePipeline.requestURL(banner, edge: 360)?.absoluteString == banner)
        let ytimg = "https://i.ytimg.com/vi/x/hqdefault.jpg"
        #expect(ImagePipeline.requestURL(ytimg, edge: 120)?.absoluteString == ytimg)
        #expect(ImagePipeline.requestURL("https://example.com/a.jpg", edge: 120) == nil, "not on the allowlist")
    }

    @Test func sharesOneDecodeForArtworkStoredAtDifferentSizes() {
        let row = "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj"
        let header = "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj"
        #expect(ImagePipeline.key(row, 168) == ImagePipeline.key(header, 168))
        #expect(ImagePipeline.key(row, 168) != ImagePipeline.key(row, 1080))
        let banner = "https://lh3.googleusercontent.com/abc=w1440-h600-p-l90-rj"
        #expect(ImagePipeline.key(banner, 360) != ImagePipeline.key(row, 360), "a banner keeps its own rendition")
    }

    @Test func aRequestDuringAPrefetchWaitsForItsDownload() async {
        let downloads = Downloads()
        let log = DownloadLog()
        let (started, didStart) = AsyncStream.makeStream(of: Void.self)
        let prefetch = Task {
            await downloads.prefetch("art") {
                didStart.yield()
                try? await Task.sleep(for: .milliseconds(50))
                await log.add("prefetched")
            }
        }
        for await _ in started { break }
        let image = await downloads.image(for: "art") {
            await log.add("loaded")
            return nil
        }
        await prefetch.value
        #expect(image == nil)
        #expect(await log.events == ["prefetched", "loaded"], "the request reads what the prefetch downloaded")
        await downloads.prefetch("art") { await log.add("prefetched again") }
        #expect(await log.events.count == 3, "a finished prefetch no longer blocks another")
    }

    @Test func decodesWithTheShorterSideAtTheEdge() throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(400, 300) { x, _ in (UInt8(x % 256), 0, 0) }, nil)
        #expect(CGImageDestinationFinalize(destination))
        let scaled = try #require(ImagePipeline.decode(data as Data, edge: 150))
        #expect((scaled.width, scaled.height) == (200, 150))
        let whole = try #require(ImagePipeline.decode(data as Data, edge: 600))
        #expect((whole.width, whole.height) == (400, 300), "never scaled up")
        #expect(ImagePipeline.decode(Data("not an image".utf8), edge: 100) == nil)
    }
}
