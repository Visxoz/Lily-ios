import Foundation
import Testing
@testable import YTMCore

@Suite struct HLSPlaylistTests {
    private let masterURL = URL(string: "https://mvod.itunes.apple.com/itunes-assets/HLSMusic112/v4/14/P524581047_default.m3u8")

    /// Shaped as Apple's: I-frame lines, an average bandwidth before the peak one, and pairs at one resolution.
    private let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS


        #EXT-X-I-FRAME-STREAM-INF:AVERAGE-BANDWIDTH=692796,_AVG-BANDWIDTH=692796,BANDWIDTH=710556,VIDEO-RANGE=SDR,CODECS="avc1.64001f",RESOLUTION=2048x2732,URI="https://mvod.itunes.apple.com/a/trickPlay.iframe.m3u8"
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2140560,_AVG-BANDWIDTH=2140560,BANDWIDTH=2279733,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=664x886,STABLE-VARIANT-ID="4368a1c1"
        https://mvod.itunes.apple.com/a/avc_664x886.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2800000,_AVG-BANDWIDTH=2800000,BANDWIDTH=2999000,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=24.000,RESOLUTION=1078x1438,STABLE-VARIANT-ID="a1"
        https://mvod.itunes.apple.com/a/avc_1078x1438.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2700000,_AVG-BANDWIDTH=2700000,BANDWIDTH=2844954,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="hvc1.2.20000000.L123.B0",FRAME-RATE=24.000,RESOLUTION=1078x1438,STABLE-VARIANT-ID="h2"
        https://mvod.itunes.apple.com/a/hvc_1078x1438_more.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2600000,_AVG-BANDWIDTH=2600000,BANDWIDTH=2829518,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="hvc1.2.20000000.L123.B0",FRAME-RATE=24.000,RESOLUTION=1078x1438,STABLE-VARIANT-ID="h1"
        https://mvod.itunes.apple.com/a/hvc_1078x1438.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2900000,_AVG-BANDWIDTH=2900000,BANDWIDTH=12061404,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="hvc1.2.20000000.H150.B0",FRAME-RATE=24.000,RESOLUTION=2048x2732,STABLE-VARIANT-ID="big"
        https://mvod.itunes.apple.com/a/hvc_2048x2732.m3u8
        """

    private func chosen(_ text: String) throws -> String? {
        try HLSPlaylist.variant(inMaster: text, at: #require(masterURL))?.absoluteString
    }

    @Test func choosesTheMostPixelsUnderTheCapThenHEVCThenTheSmallerFile() throws {
        #expect(try chosen(master) == "https://mvod.itunes.apple.com/a/hvc_1078x1438.m3u8")
    }

    @Test func readsTheBandwidthItselfNotTheAverage() {
        let big = HLSPlaylist.variants(in: master).last
        #expect(big?.bandwidth == 12_061_404 && big?.pixels == 2048 * 2732 && big?.hevc == true)
        #expect(HLSPlaylist.variants(in: master).count == 5, "I-frame playlists are not variants")
    }

    @Test func takesTheSmallestWithNoneUnderTheCap() throws {
        let over = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=7184476,CODECS="hvc1.2.20000000.H150.B0",RESOLUTION=2048x2732
            hvc_2048x2732.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=4001233,CODECS="avc1.640028",RESOLUTION=1078x1438
            avc_1078x1438.m3u8
            """
        #expect(try chosen(over) == "https://mvod.itunes.apple.com/itunes-assets/HLSMusic112/v4/14/avc_1078x1438.m3u8", "relative URIs resolve")
        #expect(try chosen("#EXTM3U\n") == nil)
    }

    @Test func splitsAttributesOnlyOutsideQuotes() {
        let found = HLSPlaylist.attributes(#"CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1078x1438,URI="a.mp4""#)
        #expect(found["CODECS"] == "avc1.640028,mp4a.40.2" && found["RESOLUTION"] == "1078x1438" && found["URI"] == "a.mp4")
    }

    private let variantURL = URL(string: "https://mvod.itunes.apple.com/itunes-assets/HLSMusic112/v4/d3/P524581047_Anull_video_gr565_sdr_1078x1438_-.m3u8")
    private let clip = "https://mvod.itunes.apple.com/itunes-assets/HLSMusic112/v4/d3/P524581047_Anull_video_gr565_sdr_1078x1438_-.mp4"

    private func file(_ text: String) throws -> String? {
        try HLSPlaylist.mediaFile(inVariant: text, at: #require(variantURL))?.absoluteString
    }

    @Test func findsTheOneFileEverySegmentIsARangeOf() throws {
        let variant = """
            #EXTM3U
            #EXT-X-TARGETDURATION:3
            #EXT-X-VERSION:7
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-MAP:URI="P524581047_Anull_video_gr565_sdr_1078x1438_-.mp4",BYTERANGE="985@0"
            #EXTINF:2.83333,\t
            #EXT-X-BYTERANGE:947221@985
            P524581047_Anull_video_gr565_sdr_1078x1438_-.mp4
            #EXTINF:2.87500,\t
            #EXT-X-BYTERANGE:958168@948206
            P524581047_Anull_video_gr565_sdr_1078x1438_-.mp4
            #EXT-X-ENDLIST
            """
        #expect(try file(variant) == clip)
        #expect(try file("#EXTM3U\n#EXTINF:2.8,\nP524581047_Anull_video_gr565_sdr_1078x1438_-.mp4\n") == clip, "without a map")
        #expect(try file("#EXTM3U\n#EXTINF:2.8,\nseg1.mp4\n#EXTINF:2.8,\nseg2.mp4\n") == nil, "several files")
    }
}

@Suite struct AppleMusicCatalogueTests {
    private func albums(_ items: String...) throws -> [JSON] {
        try JSON(data: Data("[\(items.joined(separator: ","))]".utf8)).array
    }

    private func album(_ name: String, by artist: String, video: String? = nil) -> String {
        let editorial = video.map {
            #","editorialVideo":{"motionDetailSquare":{"video":"https://mvod.itunes.apple.com/\#($0)/square.m3u8"},"motionDetailTall":{"video":"https://mvod.itunes.apple.com/\#($0)/tall.m3u8","previewFrame":{"url":"https://is1-ssl.mzstatic.com/image/thumb/\#($0)/Preview.png/{w}x{h}bb.jpg"}}}"#
        } ?? ""
        return #"{"id":"1","attributes":{"name":"\#(name)","artistName":"\#(artist)"\#(editorial)}}"#
    }

    private func tall(_ albums: [JSON], album: String, artist: String) -> String? {
        AppleMusicCatalogue.covers(in: albums, album: album, artist: artist)[.tall]?.video.absoluteString
    }

    @Test func takesTheExactAlbumWithAVideoAmongItsVersions() throws {
        let found = try albums(
            album("SOS Deluxe: LANA", by: "SZA", video: "deluxe"),
            album("SOS", by: "SZA"),
            album("SOS", by: "SZA", video: "explicit"),
            album("SOS", by: "SZA", video: "later")
        )
        let covers = AppleMusicCatalogue.covers(in: found, album: "SOS", artist: "SZA")
        #expect(covers[.tall]?.video.absoluteString == "https://mvod.itunes.apple.com/explicit/tall.m3u8")
        #expect(covers[.square]?.video.absoluteString == "https://mvod.itunes.apple.com/explicit/square.m3u8")
    }

    @Test func takesApplesStillAtTheSizeItIsDrawn() throws {
        let covers = try AppleMusicCatalogue.covers(in: albums(album("SOS", by: "SZA", video: "sos")), album: "SOS", artist: "SZA")
        #expect(covers[.tall]?.still?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/sos/Preview.png/720x960bb.jpg")
        #expect(covers[.square]?.still == nil)
        #expect(MotionShape.square.still("https://is2-ssl.mzstatic.com/a.png/{w}x{h}{c}.{f}")?.absoluteString == "https://is2-ssl.mzstatic.com/a.png/720x720bb.jpg")
        #expect(MotionShape.tall.still("https://example.com/a.png/{w}x{h}bb.jpg") == nil)
    }

    @Test func neverTakesAnotherEdition() throws {
        #expect(try tall(albums(album("SOS Deluxe: LANA", by: "SZA", video: "deluxe")), album: "SOS", artist: "SZA") == nil)
        #expect(try tall(albums(album("SOS", by: "SZA", video: "sos")), album: "SOS Deluxe", artist: "SZA") == nil)
    }

    @Test func readsSinglesAndEPsByTheirOwnName() throws {
        #expect(try tall(albums(album("Snooze - Single", by: "SZA", video: "single")), album: "Snooze", artist: "SZA") != nil)
        #expect(try tall(albums(album("Hitchhiker - EP", by: "SZA", video: "ep")), album: "Hitchhiker", artist: "SZA") != nil)
        #expect(AppleMusicCatalogue.normalised("Beyoncé - Single") == "beyonce")
        #expect(AppleMusicCatalogue.normalised("good days (Remix)") == AppleMusicCatalogue.normalised("Good Days - Remix"))
    }

    @Test func needsTheTracksArtistInApplesArtist() throws {
        #expect(try tall(albums(album("SOS", by: "SZA", video: "sos")), album: "SOS", artist: "ABBA") == nil)
        #expect(try tall(albums(album("Good News", by: "Metro Boomin, Future & SZA", video: "joint")), album: "Good News", artist: "Future") != nil)
        #expect(try tall(albums(album("Bookends", by: "Simon & Garfunkel", video: "duo")), album: "Bookends", artist: "Simon & Garfunkel") != nil)
        #expect(try tall(albums(album("Christmas", by: "Flowers", video: "other")), album: "Christmas", artist: "Low") == nil)
    }

    @Test func matchesNothingOnNamesOfOnlySymbols() throws {
        #expect(try tall(albums(album("÷", by: "Ed Sheeran", video: "divide")), album: "+", artist: "Ed Sheeran") == nil)
    }

    @Test func dropsVideosOffTheAllowedHosts() throws {
        let elsewhere = #"{"attributes":{"name":"SOS","artistName":"SZA","editorialVideo":{"motionDetailTall":{"video":"https://example.com/tall.m3u8"}}}}"#
        #expect(try tall(albums(elsewhere, album("SOS", by: "SZA", video: "sos")), album: "SOS", artist: "SZA") == "https://mvod.itunes.apple.com/sos/tall.m3u8")
    }

    private func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func token(kid: String, issuer: String, expires: Int) -> String {
        [#"{"alg":"ES256","typ":"JWT","kid":"\#(kid)"}"#, #"{"iss":"\#(issuer)","iat":1793900708,"exp":\#(expires)}"#]
            .map(base64URL).joined(separator: ".") + ".MEUCIQDx-_sig"
    }

    @Test func picksTheWebPlayersTokenFromTheScript() throws {
        let refused = token(kid: "97DQU9QUD6", issuer: "5IKPP2IECQ", expires: 1_799_948_708)
        // Payloads of different lengths, so the base64 padding left off differs.
        for expires in [1_799_948_708, 17_999_487_080] {
            let webPlay = token(kid: "WebPlayKid", issuer: "AMPWebPlay", expires: expires)
            let script = #"var a="\#(refused)";const b={token:"\#(webPlay)"},c="eyJnot a token";"#
            let found = try #require(AppleMusicCatalogue.webPlayToken(in: Data(script.utf8)))
            #expect(found.jwt == webPlay)
            #expect(found.expires == Date(timeIntervalSince1970: TimeInterval(expires)))
        }
        #expect(AppleMusicCatalogue.webPlayExpiry(refused) == nil)
        #expect(AppleMusicCatalogue.webPlayToken(in: Data("eyJ.eyJ.".utf8)) == nil)
    }

    @Test func findsThePlayersModuleScript() {
        let page = #"<link rel="stylesheet" href="/assets/index~Cz.css"><script nomodule src="/assets/index-legacy~Dq.js"></script><script type="module" crossorigin src="/assets/index~B8RKPfmaCI.js"></script>"#
        #expect(AppleMusicCatalogue.scriptPath(inPage: page) == "/assets/index~B8RKPfmaCI.js")
        #expect(AppleMusicCatalogue.scriptPath(inPage: "<html></html>") == nil)
    }
}

@Suite struct MotionArtworkTests {
    @Test func namesClipsInsideTheirFolderOnly() {
        #expect(MotionArtwork.clipName("MPREb_4pL8gzRtw1p", .tall) == "MPREb_4pL8gzRtw1p-tall.mp4")
        #expect(MotionArtwork.clipName("../../x/y", .square) == "xy-square.mp4")
        #expect(MotionArtwork.clipName("/..", .tall) == nil)
    }

    @Test func trimsTheClipsUsedLongestAgoButNeverTheOneJustKept() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Kept is the oldest, so only its being kept saves it.
        let names = ["kept", "old", "newer", "newest"]
        for (age, name) in names.enumerated() {
            let file = folder.appending(path: "\(name).mp4")
            try Data(count: 100).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(age))], ofItemAtPath: file.path)
        }
        // A still goes with its clip, even one used since, and is kept with it.
        for (age, name) in [(0.0, "kept"), (2.5, "old")] {
            let still = folder.appending(path: "\(name).jpg")
            try Data(count: 10).write(to: still)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: age)], ofItemAtPath: still.path)
        }
        try Data(count: 500).write(to: folder.appending(path: "token"))
        MotionArtwork.trim(folder, keeping: folder.appending(path: "kept.jpg"), limit: 250)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["kept.jpg", "kept.mp4", "newest.mp4", "token"])
    }

    @Test func keptIsOnlyAClipAlreadyOnThePhone() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let motion = MotionArtwork(directory: folder, storefront: "us")
        let track = Track(id: "t", title: "t", album: AlbumRef(id: "MPREb_x", name: "x"))
        #expect(await motion.kept(.tall, for: track) == nil)
        let file = folder.appending(path: "MPREb_x-tall.mp4")
        try Data(count: 10).write(to: file)
        #expect(await motion.kept(.tall, for: track) == file)
        #expect(await motion.kept(.square, for: track) == nil)
        #expect(await motion.kept(.tall, for: Track(id: "u", title: "u")) == nil)
    }
}
