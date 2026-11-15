import Foundation
import Testing
@testable import YTMCore

private func json(_ text: String) throws -> JSON {
    try JSON(data: Data(text.utf8))
}

/// A list row for song `n`.
private func row(_ n: Int) -> String {
    #"{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"v\#(n)"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song \#(n)"}]}}}]}}"#
}

private let mixTile = #"""
{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"My Mix 1"}]},"subtitle":{"runs":[{"text":"Juice WRLD, MXZI"}]},
  "navigationEndpoint":{"browseEndpoint":{"browseId":"VLRDTMAK5uy_a","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}}}}
"""#

private func carousel(_ title: String, _ items: [String]) -> String {
    #"{"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"\#(title)"}]}}},"contents":[\#(items.joined(separator: ","))]}}"#
}

@Suite struct HomeFeedTests {
    @Test func readsCarouselsAndCapsLists() throws {
        let page = try json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{
          "contents":[\#(carousel("Quick picks", (1...12).map(row))),
            {"musicTastebuilderShelfRenderer":{"primaryText":{"runs":[{"text":"Tell us what you like"}]}}},
            \#(carousel("Mixed for you", [mixTile]))],
          "continuations":[{"nextContinuationData":{"continuation":"TOKEN"}}]}}}}]}}}
        """#)
        let (sections, next) = try HomeFeed.firstPage(page)
        #expect(next == "TOKEN")
        #expect(sections.map(\.title) == ["Quick picks", "Mixed for you"], "the taste picker is skipped")
        guard case .tracks(let picks) = sections[0], case .cards(let mixes) = sections[1] else {
            Issue.record("expected a track list then a card row")
            return
        }
        #expect(picks.tracks.map(\.id) == (1...HomeFeed.listLimit).map { "v\($0)" })
        #expect(mixes.layout == .carousel && mixes.cards[0].subtitle == "Juice WRLD, MXZI", "subtitles as YouTube words them")
    }

    @Test func readsSongListsAndGridsAmongTheCarousels() throws {
        let page = try json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{
          "contents":[{"musicShelfRenderer":{"title":{"runs":[{"text":"Songs for you"}]},"contents":[\#(row(1)),\#(row(2))]}},
            {"gridRenderer":{"header":{"gridHeaderRenderer":{"title":{"runs":[{"text":"Your tiles"}]}}},"items":[\#(mixTile)]}},
            {"musicCardShelfRenderer":{"title":{"runs":[{"text":"Not a shelf of the feed"}]}}}]}}}}]}}}
        """#)
        let sections = try HomeFeed.firstPage(page).sections
        #expect(sections.map(\.title) == ["Songs for you", "Your tiles"])
        guard case .tracks(let songs) = sections[0], case .cards(let tiles) = sections[1] else {
            Issue.record("expected a track list then a card grid")
            return
        }
        #expect(songs.tracks.map(\.id) == ["v1", "v2"])
        #expect(tiles.layout == .grid)
    }

    @Test func readsContinuationPages() throws {
        let page = try json(#"""
        {"continuationContents":{"sectionListContinuation":{"contents":[\#(carousel("Mixed for you", [mixTile]))],
          "continuations":[{"nextContinuationData":{"continuation":""}}]}}}
        """#)
        let (sections, next) = HomeFeed.nextPage(page)
        #expect(sections.count == 1)
        #expect(next == nil, "an empty token ends the feed")
    }

    @Test func rejectsOtherPages() throws {
        #expect(throws: YTMError.self) { try HomeFeed.firstPage(try json("{}")) }
        let (sections, next) = HomeFeed.nextPage(try json("{}"))
        #expect(sections.isEmpty && next == nil)
    }

    @Test func retriesOnlyRefusals() {
        #expect(HomeFeed.isRefusal(YTMError(.http, "Invalid argument", status: 400)))
        #expect(!HomeFeed.isRefusal(YTMError(.http, "Unauthorised", status: 401)))
        #expect(!HomeFeed.isRefusal(YTMError(.network, "Offline")))
        #expect(!HomeFeed.isRefusal(CancellationError()))
        #expect(HomeFeed.retryDelay(after: 2) == .milliseconds(600))
    }
}

@Suite struct ExploreTests {
    private func chip(_ name: String, _ params: String, colour: Int) -> String {
        #"{"musicNavigationButtonRenderer":{"buttonText":{"runs":[{"text":"\#(name)"}]},"solid":{"leftStripeColor":\#(colour)},"clickCommand":{"browseEndpoint":{"browseId":"FEmusic_moods_and_genres_category","params":"\#(params)"}}}}"#
    }

    @Test func splitsMoodsFromGenres() throws {
        let page = try json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"gridRenderer":{"items":[\#(chip("For you", "x", colour: 0))]}},
          {"gridRenderer":{"items":[\#(chip("Chill", "c", colour: 4288988671)), \#(chip("Focus", "f", colour: 4278190080))]}},
          {"gridRenderer":{"items":[\#(chip("Blues", "b", colour: 4278232339))]}}]}}}}]}}}
        """#)
        let chips = try MoodsAndGenres(page)
        #expect(chips.moods.map(\.title) == ["Chill", "Focus"], "the last two grids, moods first")
        #expect(chips.genres.map(\.id) == ["b"])
        #expect(chips.moods[0].color == 0xA4C5FF)
        #expect(chips.all.map(\.title) == ["Chill", "Focus", "Blues"])
    }

    @Test func refusesAReplyWithoutChips() throws {
        let error = #"{"error":{"code":400,"message":"Request contains an invalid argument."}}"#
        #expect(throws: YTMError.self, "so the session cache doesn't keep it") { try MoodsAndGenres(try json(error)) }
    }

    @Test func findsTrendingAndTopArtists() {
        let song = { (id: String) in Track(id: id, title: id) }
        let sections: [Section] = [
            .tracks(TrackSection(title: "Top songs", tracks: [song("top")], mode: .section, more: .playlist("PLtop"))),
            .tracks(TrackSection(title: "Trending", tracks: [song("trend")], mode: .section, more: .playlist("PLtrend"))),
            .cards(CardSection(title: "Video charts", cards: [
                Card(kind: .playlist, id: "PL100", title: "Top 100 Music Videos"),
                Card(kind: .playlist, id: "OLAKtrend", title: "Trending 20 United Kingdom"),
            ], layout: .carousel)),
            .cards(CardSection(title: "Top artists", cards: [Card(kind: .artist, id: "UCa", title: "A")], layout: .carousel)),
        ]
        let charts = Charts(sections)
        #expect(charts.trendingPlaylistId == "OLAKtrend")
        #expect(charts.trendingTracks.map(\.id) == ["trend"], "the second chart list")
        #expect(charts.artists.map(\.id) == ["UCa"])
    }

    @Test func sharesOneFetchAndForgetsFailures() async throws {
        let counter = Counter()
        let cache = SessionCache<Int>()
        await #expect(throws: YTMError.self) {
            try await cache.value {
                _ = await counter.next()
                throw YTMError(.network, "Offline")
            }
        }
        let fetch: @Sendable () async throws -> Int = {
            try await Task.sleep(for: .milliseconds(50))
            return await counter.next()
        }
        async let first = cache.value(fetch)
        async let second = cache.value(fetch)
        let values = try await [first, second]
        #expect(values == [2, 2], "the failure was not kept; the two callers shared one fetch")
        #expect(try await cache.value(fetch) == 2)
        #expect(await counter.calls == 2)
    }
}

private actor Counter {
    var calls = 0

    func next() -> Int {
        calls += 1
        return calls
    }
}

@Suite struct LibraryPagesTests {
    private let albumTile = #"""
    {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Discovery"}]},
      "subtitle":{"runs":[{"text":"Album"},{"text":" • "},{"text":"Daft Punk","navigationEndpoint":{"browseEndpoint":{"browseId":"UCdp"}}},{"text":" • "},{"text":"2001"}]},
      "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_d","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}}}
    """#

    @Test func readsFirstAndLaterPages() throws {
        let first = try json(#"""
        {"continuationContents":{"sectionListContinuation":{"contents":[
          {"itemSectionRenderer":{"contents":[]}},
          {"gridRenderer":{"items":[\#(albumTile)],"continuations":[{"nextContinuationData":{"continuation":"MORE"}}]}}]}}}
        """#)
        let shelf = LibraryList.shelf(in: first)
        #expect(Renderers.continuation(shelf) == "MORE")
        let albums = Renderers.cards(LibraryList.items(shelf))
        #expect(albums.count == 1)
        #expect(albums.first?.kind == .album && albums.first?.subtitle == "Album • Daft Punk • 2001")

        let later = try json(#"{"continuationContents":{"musicShelfContinuation":{"contents":[\#(row(1)), \#(row(2))]}}}"#)
        let rows = LibraryList.shelf(in: later)
        #expect(Renderers.tracks(LibraryList.items(rows)).count == 2 && Renderers.continuation(rows) == nil)
    }

    @Test func mapsRoutes() {
        for list in LibraryList.allCases {
            #expect(LibraryList(list.route) == list)
        }
        #expect(LibraryList(.library) == nil)
    }

    private func likedPage(rows: [String], more: Bool) -> String {
        let trailing = more ? #",{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"T"}}}}"# : ""
        return #"""
        {"contents":{"twoColumnBrowseResultsRenderer":{
          "tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicResponsiveHeaderRenderer":{
            "title":{"runs":[{"text":"Liked music"}]},
            "secondSubtitle":{"runs":[{"text":"1,234 songs"},{"text":" • "},{"text":"70+ hours"}]},
            "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://www.gstatic.com/youtube/media/ytm/images/pbg/liked-music@576.png","width":576}]}}}}}]}}}}],
          "secondaryContents":{"sectionListRenderer":{"contents":[{"musicPlaylistShelfRenderer":{"contents":[\#(rows.joined(separator: ","))\#(trailing)]}}]}}}}}
        """#
    }

    @Test func countsLikedMusic() throws {
        let long = try #require(LibraryList.likedMusicCard(try json(likedPage(rows: [row(1)], more: true))))
        #expect(long.id == "LM" && long.title == "Liked music")
        #expect(long.subtitle == "Auto playlist • 1234 songs", "the header's count when not all are listed")
        #expect(long.thumbnail == "https://www.gstatic.com/youtube/media/ytm/images/pbg/liked-music@576.png")

        let short = try #require(LibraryList.likedMusicCard(try json(likedPage(rows: [row(1), row(2)], more: false))))
        #expect(short.subtitle == "Auto playlist • 2 songs", "the songs listed when they all are")

        #expect(LibraryList.likedMusicCard(try json("{}")) == nil)
    }
}

@Suite struct HistoryPageTests {
    @Test func joinsEveryDaysShelf() throws {
        let page = try json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicShelfRenderer":{"title":{"runs":[{"text":"Today"}]},"contents":[\#(row(1)), \#(row(2))]}},
          {"musicShelfRenderer":{"title":{"runs":[{"text":"Yesterday"}]},"contents":[\#(row(3))]}}]}}}}]}}}
        """#)
        #expect(YTMusic.historyTracks(in: page).map(\.id) == ["v1", "v2", "v3"])
        #expect(YTMusic.historyTracks(in: try json("{}")).isEmpty)
    }
}
