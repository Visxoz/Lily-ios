import Foundation
import Testing
@testable import YTMCore

@Suite struct SpotifyCanvasTests {
    // MARK: - Codes

    @Test func makesRFC6238sSHA1Codes() {
        let key = Data("12345678901234567890".utf8)
        #expect(SpotifyCanvas.totp(key: key, at: Date(timeIntervalSince1970: 59)) == "287082")
        #expect(SpotifyCanvas.totp(key: key, at: Date(timeIntervalSince1970: 1_111_111_109)) == "081804", "zero-padded")
    }

    @Test func derivesTheKeyAsTheWebPlayerDoes() {
        // 65 ^ 9, 122 ^ 10, 33 ^ 11.
        #expect(SpotifyCanvas.key(fromSecret: "Az!") == Data("7211242".utf8))
        let long = String(decoding: SpotifyCanvas.key(fromSecret: String(repeating: "a", count: 34)), as: UTF8.self)
        #expect(long.hasPrefix("104") && long.hasSuffix("72104"), "the XOR rolls over after 33 characters")
    }

    // MARK: - Script

    private let hash = String(repeating: "0123456789abcdef", count: 4)

    @Test func readsTheNewestKeyAndTheSearchHashFromTheScript() throws {
        let script = #"""
            x.generate({secret:e,algorithm:t});let ej=[{secret:'q\'w',version:12},{secret:"a\\b\"c",version:15},
            {secret:'old',version:9}].map(e=>e);let hJ=new hz.l("searchSuggestions","query","\#(hash)",null);
            """#
        let config = try #require(SpotifyCanvas.config(inScript: Data(script.utf8)))
        #expect(config == SpotifyCanvas.Config(version: 15, secret: #"a\b"c"#, search: hash))
        let single = #"{secret:'q\'w\\',version:3};("searchSuggestions","query","\#(hash)""#
        #expect(SpotifyCanvas.config(inScript: Data(single.utf8))?.secret == #"q'w\"#)
    }

    @Test func wantsAKeyAndAWholeLowercaseHash() {
        let keyless = #"{secret:e,version:3};("searchSuggestions","query","\#(hash)""#
        #expect(SpotifyCanvas.config(inScript: Data(keyless.utf8)) == nil)
        let upper = #"{secret:'k',version:3};("searchSuggestions","query","\#(hash.uppercased())""#
        #expect(SpotifyCanvas.config(inScript: Data(upper.utf8)) == nil)
        let short = #"{secret:'k',version:3};("searchSuggestions","query","\#(hash.dropLast())""#
        #expect(SpotifyCanvas.config(inScript: Data(short.utf8)) == nil)
        #expect(SpotifyCanvas.config(inScript: Data(#"{secret:'unterminated"#.utf8)) == nil)
    }

    @Test func findsTheMainScriptInThePage() {
        let page = #"""
            <link href="https://open.spotifycdn.com/cdn/build/web-player/web-player.9f8e7d6c.css"/>
            <script src="https://open.spotifycdn.com/cdn/build/web-player/web-player.1a2b3c4d.js"></script>
            """#
        #expect(SpotifyCanvas.scriptURL(inPage: page)?.absoluteString == "https://open.spotifycdn.com/cdn/build/web-player/web-player.1a2b3c4d.js")
        #expect(SpotifyCanvas.scriptURL(inPage: #"web-player.1a2b.css"#) == nil)
    }

    // MARK: - Protobuf

    @Test func encodesTheCanvasRequest() {
        let uri = "spotify:track:a"
        #expect(SpotifyCanvas.canvasRequest([uri]) == Data([0x0A, 17, 0x0A, 15]) + Data(uri.utf8))
        #expect(Protobuf.field(1, Data(count: 200)).prefix(3) == Data([0x0A, 0xC8, 0x01]), "lengths past 127 take two bytes")
    }

    private func varint(_ number: UInt8, _ value: UInt8) -> Data { Data([number << 3, value]) }
    private func text(_ number: UInt8, _ value: String) -> Data { Protobuf.field(number, Data(value.utf8)) }

    private func canvas(_ uri: String, type: UInt8, url: String, still: String? = nil) -> Data {
        // A fixed64 and a fixed32 field the reader must step over.
        var body = text(1, "id") + Data([3 << 3 | 1] + [UInt8](repeating: 7, count: 8)) + Data([10 << 3 | 5, 1, 2, 3, 4])
        body += text(2, url) + varint(4, type) + text(5, uri)
        // A `Thumbnail`, which the reader steps over.
        if let still { body += Protobuf.field(13, varint(1, 120) + varint(2, 60) + text(3, still)) }
        return Protobuf.field(1, body)
    }

    private var response: Data {
        canvas("spotify:track:image", type: 0, url: "https://canvaz.scdn.co/upload/a.jpg")
            + canvas("spotify:track:song", type: 3, url: "https://canvaz.scdn.co/upload/b.cnvs.mp4", still: "https://i.scdn.co/image/large")
            + canvas("spotify:track:other", type: 1, url: "https://canvaz.scdn.co/upload/c.cnvs.mp4")
            + canvas("spotify:track:foreign", type: 2, url: "https://example.com/upload/d.cnvs.mp4")
            + varint(2, 60)
    }

    @Test func readsLoopingVideosByTrackWithoutSpotifysStills() throws {
        let found = try #require(SpotifyCanvas.canvases(in: response))
        #expect(Set(found.keys) == ["spotify:track:song", "spotify:track:other"], "an image and a foreign host are passed over")
        #expect(found["spotify:track:song"]?.video.absoluteString == "https://canvaz.scdn.co/upload/b.cnvs.mp4")
        #expect(found.values.allSatisfy { $0.still == nil }, "9:16 stills are passed over")
    }

    @Test func readsHostileBytesAsMalformedWithoutTrapping() {
        let whole = response
        for end in 0..<whole.count {
            _ = SpotifyCanvas.canvases(in: whole.prefix(end))
        }
        #expect(SpotifyCanvas.canvases(in: Data([0x0A, 0x05, 0x01])) == nil, "a length past the end")
        #expect(SpotifyCanvas.canvases(in: Data([0x0A] + [UInt8](repeating: 0xFF, count: 9) + [0x01])) == nil, "a huge length")
        #expect(SpotifyCanvas.canvases(in: Data([0x08] + [UInt8](repeating: 0x80, count: 11))) == nil, "a varint past ten bytes")
        #expect(SpotifyCanvas.canvases(in: Data([0x0B, 0x0C])) == nil, "groups aren't read")
        for _ in 0..<500 {
            _ = SpotifyCanvas.canvases(in: Data((0..<Int.random(in: 0..<64)).map { _ in UInt8.random(in: 0...255) }))
        }
    }

    // MARK: - Search and match

    @Test func readsTheTracksAmongTheTopResults() throws {
        let answer = #"""
            {"data":{"searchV2":{"topResultsV2":{"itemsV2":[
            {"item":{"data":{"__typename":"Album","uri":"spotify:album:x","name":"Song"}}},
            {"item":{"data":{"__typename":"Track","uri":"spotify:track:1","name":"Song",
              "artists":{"items":[{"profile":{"name":"The Band"}}]},"albumOfTrack":{"name":"Hits"},
              "duration":{"totalMilliseconds":201800}}}}]}}}}
            """#
        let found = try #require(SpotifyCanvas.candidates(in: JSON(data: Data(answer.utf8))))
        #expect(found.map(\.uri) == ["spotify:track:1"])
        #expect(found.first?.artists == ["The Band"] && found.first?.album == "Hits" && found.first?.seconds == 201.8)
        #expect(try SpotifyCanvas.candidates(in: JSON(data: Data(#"{"data":{}}"#.utf8))) == nil, "another shape isn't none")
    }

    private func candidate(_ uri: String, _ name: String, by artist: String, on album: String, _ seconds: Double) -> SpotifyCanvas.Candidate {
        SpotifyCanvas.Candidate(uri: uri, name: name, artists: ["Guest", artist], album: album, seconds: seconds)
    }

    @Test func matchesOnlyTheSongItsAlbumFirst() {
        let found = [
            candidate("compilation", "Song (Remastered 2009)", by: "The Band", on: "Greatest Hits", 200.4),
            candidate("wrong-artist", "Song - Remastered 2009", by: "Other Band", on: "Original Album", 200),
            candidate("album", "Song - Remastered 2009", by: "The Band & Friend", on: "Original Album", 198),
            candidate("long", "Song - Remastered 2009", by: "The Band", on: "Original Album", 205),
            candidate("album", "Song - Remastered 2009", by: "The Band", on: "Original Album", 198),
            candidate("other-song", "Other Song", by: "The Band", on: "Original Album", 200),
        ]
        let title = "Song - Remastered 2009"
        #expect(SpotifyCanvas.matches(found, title: title, artist: "The Band", album: "Original Album", duration: 200) == ["album", "compilation"])
        #expect(SpotifyCanvas.matches(found, title: title, artist: "The Band", album: nil, duration: nil) == ["compilation", "album", "long"])
        #expect(SpotifyCanvas.matches(found, title: "!!!", artist: "The Band", album: nil, duration: nil).isEmpty)
    }
}
