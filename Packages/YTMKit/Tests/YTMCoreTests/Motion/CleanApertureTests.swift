import Foundation
import Testing
@testable import YTMCore

@Suite struct CleanApertureTests {
    private static let origin = 20

    @Test func cutsATallClipToItsMiddleThreeByFour() throws {
        let moov = Self.moov(width: 1080, height: 1920)
        let mdat = Self.origin + moov.count
        let cut = try #require(CleanAperture.tall(moov: moov, at: Self.origin))
        #expect(cut.count == moov.count + 40)
        #expect(Array(cut[0 ..< 4]) == Self.be32(cut.count), "the moov grows by the box")
        let clap = Self.be32(40) + Array("clap".utf8) + [1080, 1, 1440, 1, 0, 1, 0, 1].flatMap(Self.be32)
        // trak, mdia, minf, stbl, stsd and avc1 each grow by it, and it ends the avc1.
        for at in [8, 108, 116, 124, 132, 148] {
            #expect(Array(cut[at ..< at + 4]) == Self.be32(moov[at ..< at + 4].reduce(0) { $0 << 8 | Int($1) } + 40))
        }
        #expect(Array(cut[245 ..< 285]) == clap, "centred, 1080x1440, inside the avc1")
        #expect(Array(cut[104 ..< 108]) == Self.be32(1440 << 16), "the track's height is the cut one")
        #expect(Array(cut.suffix(8)) == Self.be32(mdat + 48) + Self.be32(4), "only offsets past the moov move")
    }

    @Test func movesLongOffsetsAcrossTheirHighWordAndRefusesOverflow() throws {
        let moov = Self.moov(width: 1080, height: 1920, co64: 0xFFFF_FFF0)
        let cut = try #require(CleanAperture.tall(moov: moov, at: Self.origin))
        #expect(Array(cut.suffix(8)) == Self.be32(1) + Self.be32(0x18))
        #expect(CleanAperture.tall(moov: Self.moov(width: 1080, height: 1920, co64: Int.max - 8), at: Self.origin) == nil)
    }

    @Test func leavesARotatedClip() {
        #expect(CleanAperture.tall(moov: Self.moov(width: 1080, height: 1920, rotated: true), at: Self.origin) == nil)
    }

    @Test func leavesAClipThatFitsOrIsMalformed() {
        #expect(CleanAperture.tall(moov: Self.moov(width: 1080, height: 1440), at: Self.origin) == nil)
        let moov = Self.moov(width: 1080, height: 1920)
        for count in stride(from: 0, to: moov.count, by: 5) {
            #expect(CleanAperture.tall(moov: Array(moov.prefix(count)), at: Self.origin) == nil)
        }
    }

    @Test func writesTheCutClipAsANewFile() throws {
        let moov = Self.moov(width: 1080, height: 1920)
        let clip = Self.box("ftyp", Array(repeating: 0, count: 12)) + moov + Self.box("mdat", [1, 2, 3])
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(clip).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let cut = try #require(try CleanAperture.tall(file))
        defer { try? FileManager.default.removeItem(at: cut) }
        let written = try [UInt8](Data(contentsOf: cut))
        #expect(written.count == clip.count + 40)
        #expect(Array(written.suffix(3)) == [1, 2, 3])
    }

    /// One video track: `tkhd`, then an `avc1` entry and a chunk table, of an offset into the mdat and one before, or
    /// of one long offset.
    private static func moov(width: Int, height: Int, co64: Int? = nil, rotated: Bool = false) -> [UInt8] {
        // a, b, u, c, d, v, x, y, w: upright, or turned a quarter.
        let matrix = (rotated ? [0, 1 << 16, 0, -(1 << 16), 0, 0] : [1 << 16, 0, 0, 0, 1 << 16, 0]) + [0, 0, 1 << 30]
        let tkhd = box("tkhd", Array(repeating: 0, count: 40) + matrix.flatMap(be32) + be32(width << 16) + be32(height << 16))
        let avc1 = box("avc1", Array(repeating: 0, count: 24) + be16(width) + be16(height) + Array(repeating: 0, count: 50) + box("avcC", [1, 2, 3]))
        let stsd = box("stsd", be32(0) + be32(1) + avc1)
        let unmoved = 4
        // The moov's own size is known before it is built: these boxes add 8 bytes each.
        let size = 8 + 8 + tkhd.count + 8 + 8 + 8 + stsd.count + 24
        let stco = if let co64 {
            box("co64", be32(0) + be32(1) + be32(co64 >> 32) + be32(co64))
        } else {
            box("stco", be32(0) + be32(2) + be32(origin + size + 8) + be32(unmoved))
        }
        return box("moov", box("trak", tkhd + box("mdia", box("minf", box("stbl", stsd + stco)))))
    }

    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(8 + payload.count) + Array(type.utf8) + payload
    }

    private static func be32(_ value: Int) -> [UInt8] {
        (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }
    }

    private static func be16(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
}
