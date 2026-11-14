import Foundation
import Testing
@testable import YTMCore

/// ytm-native's `api/account.rs` and `api/history.rs` tests.
@Suite struct AccountTests {
    private let menu = #"""
        {"actions":[{"openPopupAction":{"popup":{"multiPageMenuRenderer":{"header":
          {"activeAccountHeaderRenderer":{"accountName":{"runs":[{"text":"Alex"}]},"channelHandle":{"runs":[{"text":"@alex"}]},
          "accountPhoto":{"thumbnails":[
            {"url":"https://yt3.ggpht.com/a=s88","width":88,"height":88},
            {"url":"https://yt3.ggpht.com/a=s176","width":176,"height":176}]}}}}}}}]}
        """#

    private func json(_ text: String) throws -> JSON {
        try JSON(data: Data(text.utf8))
    }

    @Test func readsTheAccountMenu() throws {
        let account = try #require(Account(menu: json(menu), guidePhoto: nil))
        #expect(account == Account(name: "Alex", handle: "@alex", photo: "https://yt3.ggpht.com/a=s176-rj"))
        let fromGuide = Account(menu: try json(menu), guidePhoto: "https://yt3.ggpht.com/yti/b=s88-c-k-no-rj")
        #expect(fromGuide?.photo == "https://yt3.ggpht.com/yti/b=s88-c-k-no-rj", "the guide's picture is the current one")
        #expect(Account(menu: try json(#"{"actions":[]}"#), guidePhoto: nil) == nil, "a signed-out menu")
    }

    @Test func readsTheAccountPhoto() throws {
        let guide = try json(#"{"items":[],"userProfile":{"accountPhoto":{"thumbnails":[{"url":"https://yt3.ggpht.com/yti/b=s88-c-k-no-rj"}]}}}"#)
        #expect(Account.photo(guide["userProfile", "accountPhoto", "thumbnails"]) == "https://yt3.ggpht.com/yti/b=s88-c-k-no-rj")
        #expect(Account.photo(.missing) == nil)
    }

    @Test func readsTheStatsURL() throws {
        let player = try json(#"""
            {"playabilityStatus":{"status":"OK"},"playbackTracking":{
              "videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/api/stats/playback?ns=yt&docid=abc&ei=a%2Bb"},
              "videostatsWatchtimeUrl":{"baseUrl":"https://s.youtube.com/api/stats/watchtime?ns=yt"}}}
            """#)
        let url = try #require(PlayReport.pingURL(in: player, client: "WEB_REMIX"))
        let query = try #require(url.query(percentEncoded: true))
        #expect(url.host() == "s.youtube.com")
        #expect(query.hasPrefix("ns=yt&docid=abc&ei=a%2Bb&ver=2&c=WEB_REMIX&cpn="), "the response's own parameters kept as sent")
        #expect(PlayReport.pingURL(in: try json(#"{"playabilityStatus":{}}"#), client: "WEB_REMIX") == nil)
    }

    @Test func sendsTheCookieOnlyToYouTube() throws {
        let elsewhere = try json(#"{"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"https://s.googlevideo.com/api/stats/playback"}}}"#)
        #expect(PlayReport.pingURL(in: elsewhere, client: "WEB_REMIX") == nil)
        let lookalike = try json(#"{"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"https://evilyoutube.com/api/stats/playback"}}}"#)
        #expect(PlayReport.pingURL(in: lookalike, client: "WEB_REMIX") == nil)
    }

    @Test func makesNoncesLikeTheWebPlayer() {
        let (a, b) = (PlayReport.cpn(), PlayReport.cpn())
        #expect(a.count == 16)
        #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(a != b, "random each time")
    }
}
