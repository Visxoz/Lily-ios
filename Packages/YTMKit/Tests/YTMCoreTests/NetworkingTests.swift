import Foundation
import Synchronization
import Testing
@testable import YTMCore

@Suite struct AllowlistTests {
    private func allowed(_ url: String) -> Bool {
        URL(string: url).map(HTTP.isAllowed) ?? false
    }

    @Test func allowsYouTubeHostsOverHTTPS() {
        #expect(allowed("https://music.youtube.com/youtubei/v1/player"))
        #expect(allowed("https://www.youtube.com/s/player/abc/base.js"))
        #expect(allowed("https://rr3---sn-abc.googlevideo.com/videoplayback?x=1"))
        #expect(allowed("https://i.ytimg.com/vi/x/hqdefault.jpg"))
        #expect(allowed("https://lh3.googleusercontent.com/abc=w120-h120"))
        #expect(allowed("https://yt3.ggpht.com/abc=s88"))
        #expect(allowed("https://www.gstatic.com/youtube/media/ytm/images/pbg/liked-music-@576.png"))
        #expect(allowed("https://ws.audioscrobbler.com/2.0/"))
        #expect(allowed("https://www.last.fm/api/auth/?api_key=k&token=t"))
    }

    @Test func blocksEverythingElse() {
        #expect(!allowed("http://music.youtube.com/"), "plain HTTP")
        #expect(!allowed("https://youtube.com.evil.com/"))
        #expect(!allowed("https://evilyoutube.com/"))
        #expect(!allowed("https://example.com/image.jpg"))
        #expect(!allowed("https://accounts.google.com/"))
        #expect(!allowed("https://last.fm/"), "only Last.fm's own two hosts")
        #expect(!allowed("file:///etc/passwd"))
    }

    @Test func wordsFailuresWithoutURLs() {
        let error = YTMError(URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://a.googlevideo.com/x?sig=secret") as Any]))
        #expect(error.kind == .network)
        #expect(!error.message.contains("googlevideo"))
        #expect(YTMError(status: 403).status == 403)
        #expect(YTMError(status: 302).kind == .http)
    }
}

@Suite struct ClientProfileTests {
    @Test func appClientsDescribeTheirDevice() {
        let context = ClientProfile.androidVR.context(hl: "en", gl: "GB", visitorData: "V")
        #expect(context["clientName"] as? String == "ANDROID_VR")
        #expect(context["deviceModel"] as? String == "Quest 3")
        #expect(context["androidSdkVersion"] as? Int == 32)
        #expect(context["visitorData"] as? String == "V")
        #expect(context["userAgent"] as? String == ClientProfile.androidVR.userAgent)
        let web = ClientProfile.webRemix.context(hl: "en", gl: "US", visitorData: nil)
        #expect(web["deviceMake"] == nil && web["visitorData"] == nil)
    }

    @Test func headersNameTheClient() {
        let headers = ClientProfile.webRemix.headers(visitorData: "V")
        #expect(headers["X-YouTube-Client-Name"] == "67")
        #expect(headers["Origin"] == "https://music.youtube.com")
        #expect(headers["Referer"] == "https://music.youtube.com/")
        #expect(headers["X-Goog-Visitor-Id"] == "V")
        let android = ClientProfile.androidMusic.headers(visitorData: nil)
        #expect(android["Origin"] == nil && android["X-Goog-Visitor-Id"] == nil)
        #expect(ClientProfile.visionOS.headers(visitorData: nil)["Origin"] == "https://www.youtube.com")
    }

    @Test func buildsEndpointURLs() {
        let url = ClientProfile.webRemix.url("browse")
        #expect(url?.absoluteString == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(ClientProfile.plainStreamClients.map(\.name) == ["VISIONOS", "ANDROID_VR", "IOS"])
    }
}

/// Answers each request with the next status queued, then with 200, each with `body`.
private final class FlakyServer: URLProtocol {
    static let statuses = Mutex<[Int]>([])
    static let body = Mutex("{}")
    static let requests = Mutex(0)
    /// Each request's `X-Attempt` header.
    static let attempts = Mutex<[String?]>([])

    static func reset(_ statuses: [Int], body: String) {
        self.statuses.withLock { $0 = statuses }
        self.body.withLock { $0 = body }
        requests.withLock { $0 = 0 }
        attempts.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        Self.attempts.withLock { $0.append(request.value(forHTTPHeaderField: "X-Attempt")) }
        let status = Self.statuses.withLock { $0.isEmpty ? 200 : $0.removeFirst() }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.withLock(\.self).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct RetryTests {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlakyServer.self]
        return URLSession(configuration: config)
    }()

    private func ask(_ statuses: [Int], retries: Int, body: String = "{}", refusals: Refusals? = nil) async throws -> Int {
        FlakyServer.reset(statuses, body: body)
        let url = try #require(URL(string: "https://music.youtube.com/youtubei/v1/browse"))
        return try await HTTP.data(for: URLRequest(url: url), session: session, retries: retries, refusals: refusals).1.statusCode
    }

    @Test func signsEachAttemptAndSeesEveryAnswer() async throws {
        FlakyServer.reset([403], body: "{}")
        let url = try #require(URL(string: "https://music.youtube.com/youtubei/v1/browse"))
        var signed = 0
        var answers: [Int] = []
        let (_, response) = try await HTTP.data(
            for: URLRequest(url: url), session: session, retries: 1,
            sign: { request in
                signed += 1
                request.setValue("\(signed)", forHTTPHeaderField: "X-Attempt")
            },
            answered: { answers.append($0.statusCode) }
        )
        #expect(response.statusCode == 200 && answers == [403, 200])
        #expect(FlakyServer.attempts.withLock(\.self) == ["1", "2"])
    }

    @Test func countsAnswersAndFailsAtOnceWhenRefusedAfterAPause() async throws {
        let refusals = Refusals { $0 >= Refusals.run ? .milliseconds(300) : nil }
        for _ in 1..<Refusals.run { refusals.answered(refused: true) }
        // The run's last refusal, which pauses what follows.
        await #expect(throws: YTMError(status: 403)) { try await ask([403], retries: 0, refusals: refusals) }
        await #expect(throws: YTMError(status: 403)) { try await ask([403, 403], retries: 2, refusals: refusals) }
        #expect(FlakyServer.requests.withLock(\.self) == 1, "refused after the pause, so not retried")
    }

    @Test func asksAgainAfterAServerError() async throws {
        #expect(try await ask([503], retries: 1) == 200)
        #expect(FlakyServer.requests.withLock(\.self) == 2)
    }

    @Test func failsAtOnceOnARefusalOrWithoutRetries() async {
        await #expect(throws: YTMError(status: 404)) { try await ask([404], retries: 2) }
        #expect(FlakyServer.requests.withLock(\.self) == 1)
        await #expect(throws: YTMError(status: 503)) { try await ask([503], retries: 0) }
        #expect(FlakyServer.requests.withLock(\.self) == 1)
    }

    @Test func asksAgainAfterAStrayRefusal() async throws {
        #expect(try await ask([403], retries: 1) == 200)
        #expect(FlakyServer.requests.withLock(\.self) == 2)
    }

    @Test func failsAtOnceWhenRefusedForWantOfPermission() async {
        let denied = #"{"error":{"code":403,"message":"The caller does not have permission"}}"#
        await #expect(throws: YTMError(status: 403)) { try await ask([403], retries: 2, body: denied) }
        #expect(FlakyServer.requests.withLock(\.self) == 1)
    }

    @Test func retriesAsRustypipeDoes() {
        let transient = { (status: Int, message: String) in
            HTTP.isTransient(status: status, body: Data(#"{"error":{"message":"\#(message)"}}"#.utf8))
        }
        #expect(transient(429, "") && transient(500, "") && transient(503, ""))
        #expect(!transient(400, "") && !transient(404, ""))
        #expect(transient(403, ""))
        #expect(HTTP.isTransient(status: 403, body: Data("not json".utf8)))
        #expect(HTTP.isStrayRefusal(status: 403, body: Data(#"{"error":{"message":"Request refused"}}"#.utf8)))
        let denied = Data(#"{"error":{"message":"The caller does not have permission"}}"#.utf8)
        #expect(!HTTP.isTransient(status: 403, body: denied) && !HTTP.isStrayRefusal(status: 403, body: denied))
        #expect(!HTTP.isStrayRefusal(status: 404, body: Data()))
        #expect(InnerTube.retries == 2)
        for _ in 0..<20 {
            #expect((Duration.seconds(1)...Duration.milliseconds(1500)).contains(HTTP.retryDelay(after: 0)))
            #expect((Duration.milliseconds(2400)...Duration.milliseconds(4500)).contains(HTTP.retryDelay(after: 1)))
            #expect(HTTP.retryDelay(after: 8) == .seconds(60), "at most a minute")
        }
    }
}

@Suite struct RefusalsTests {
    @Test func pausesOnlyAfterARunOfRefusals() {
        #expect(Refusals.pause(after: Refusals.run - 1) == nil, "stray ones only retry")
        #expect(Refusals.pause(after: Refusals.run) == .seconds(5))
        #expect(Refusals.pause(after: Refusals.run + 1) == .seconds(10))
        #expect(Refusals.pause(after: .max) == .seconds(40), "capped")
    }

    @Test func anAnswerEndsTheRun() async {
        let refusals = Refusals()
        for refused in Array(repeating: true, count: Refusals.run - 1) + [false] + Array(repeating: true, count: Refusals.run - 1) {
            refusals.answered(refused: refused)
        }
        #expect(await !refusals.waitForTurn())
    }

    @Test func aRunPausesAndAPauseIsOnlyExtended() async {
        // Shorter past the run, so a later refusal would cut the first pause short.
        let refusals = Refusals { $0 >= Refusals.run ? .milliseconds($0 == Refusals.run ? 300 : 1) : nil }
        for _ in 0...Refusals.run { refusals.answered(refused: true) }
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await refusals.waitForTurn())
        #expect(clock.now - started > .milliseconds(200))
    }
}

@Suite struct VisitorDataTests {
    private actor Issuer {
        private(set) var fetches = 0
        func issue() -> String {
            fetches += 1
            return "v\(fetches)"
        }
    }

    @Test func keepsAFreshIDOnlyOnceItWorks() async throws {
        let issuer = Issuer()
        let store = FileStore(directory: .temporaryDirectory.appending(path: "ytm-visitor-\(UUID().uuidString)"))
        let visitor = VisitorData(store: store) { await issuer.issue() }
        #expect(try await visitor.value() == "v1")
        #expect(try await visitor.candidate(replacing: "v1") == "v2")
        #expect(try await visitor.value() == "v1", "a candidate that failed too isn't kept")
        await visitor.adopt("v2", replacing: "v1")
        #expect(try await visitor.value() == "v2")
        #expect(try await visitor.candidate(replacing: "v1") == "v2", "another caller replaced it already")
        await visitor.adopt("v3", replacing: "v1")
        #expect(try await visitor.value() == "v2", "a late adoption changes nothing")
        #expect(await issuer.fetches == 2)
    }

    @Test func forgettingFetchesANewIDAndDropsAnAdoptionStartedBefore() async throws {
        let issuer = Issuer()
        let store = FileStore(directory: .temporaryDirectory.appending(path: "ytm-visitor-\(UUID().uuidString)"))
        let visitor = VisitorData(store: store) { await issuer.issue() }
        #expect(try await visitor.value() == "v1")
        let candidate = try await visitor.candidate(replacing: "v1")
        await visitor.forget()
        await visitor.adopt(candidate, replacing: "v1")
        #expect(try await visitor.value() == "v3", "neither the forgotten ID nor its candidate is sent")
        #expect(store.load(Saved.self, from: .visitor)?.value == "v3")
    }

    @Test func ignoresASavedIDThatIsNoHeader() async throws {
        let issuer = Issuer()
        let store = FileStore(directory: .temporaryDirectory.appending(path: "ytm-visitor-\(UUID().uuidString)"))
        store.save(Saved(value: "a\r\nb", fetched: .now), to: .visitor)
        let visitor = VisitorData(store: store) { await issuer.issue() }
        #expect(try await visitor.value() == "v1")
    }

    /// VisitorData's saved file, in the same shape.
    private struct Saved: Codable, Sendable {
        let value: String
        let fetched: Date
    }

    @Test(.timeLimit(.minutes(1))) func sendsADayOldIDWhileANewOneIsFetched() async throws {
        let issuer = Issuer()
        let store = FileStore(directory: .temporaryDirectory.appending(path: "ytm-visitor-\(UUID().uuidString)"))
        store.save(Saved(value: "old", fetched: .now.addingTimeInterval(-2 * 86_400)), to: .visitor)
        let visitor = VisitorData(store: store) { await issuer.issue() }
        var value = try await visitor.value()
        #expect(value == "old", "no request waits on the refresh")
        while value == "old" {
            await Task.yield()
            value = try await visitor.value()
        }
        #expect(value == "v1")
        #expect(await issuer.fetches == 1)
    }

    @Test func asksAsRustypipesDefaults() {
        #expect(InnerTube.language == "en" && InnerTube.country == "US")
    }
}

@Suite struct GoogleAuthTests {
    @Test func buildsSAPISIDAuthorization() {
        let cookie = "SID=a; SAPISID=abc; __Secure-3PAPISID=def"
        let auth = GoogleAuth.authorization(cookie: cookie, origin: "https://music.youtube.com", time: 1_700_000_000)
        // sha1("1700000000 abc https://music.youtube.com").
        #expect(auth == "SAPISIDHASH 1700000000_2f3ec011e870f3fbd0238c090c2062c208cead32 "
            + "SAPISID3PHASH 1700000000_b38b56d67b7362e62fd452ce74b55b7cce306020")
        #expect(GoogleAuth.authorization(cookie: "SID=a", origin: "https://x", time: 0) == nil)
        #expect(GoogleAuth.authorization(cookie: "__Secure-3PAPISID=def", origin: "https://x", time: 1)?.hasPrefix("SAPISIDHASH 1_") == true,
                "SAPISIDHASH falls back to the 3P cookie")
    }

    private func cookie(_ name: String, _ value: String, _ domain: String, expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if let expires { properties[.expires] = expires }
        return try #require(HTTPCookie(properties: properties))
    }

    @Test func keepsOnlyGoogleAndYouTubeCookiesOnce() throws {
        let header = try #require(GoogleAuth.cookieHeader([
            try cookie("SAPISID", "g", ".google.com"),
            try cookie("SAPISID", "y", ".youtube.com"),
            try cookie("HSID", "h", "accounts.google.com"),
            try cookie("TRACK", "t", ".example.com"),
            try cookie("OLD", "o", ".youtube.com", expires: .distantPast),
        ]))
        let pairs = Set(header.components(separatedBy: "; "))
        #expect(pairs == ["SAPISID=y", "HSID=h"])
        #expect(try GoogleAuth.cookieHeader([cookie("SID", "s", ".youtube.com")]) == nil, "no session cookie to sign with")
    }

    @Test func signsRequestsOnlyWhenSignedIn() async throws {
        let auth = GoogleAuth()
        await auth.signOut()
        #expect(await auth.headers(origin: "https://music.youtube.com") == nil)
        try await auth.signIn(cookies: [try cookie("SAPISID", "abc", ".youtube.com")])
        let headers = try #require(await auth.headers(origin: "https://music.youtube.com"))
        #expect(headers["Cookie"] == "SAPISID=abc")
        #expect(headers["X-Goog-AuthUser"] == "0")
        #expect(headers["X-Origin"] == "https://music.youtube.com")
        #expect(headers["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
        await auth.signOut()
        #expect(await !auth.isSignedIn)
    }

    private func setCookies(_ lines: [String]) throws -> [HTTPCookie] {
        let url = try #require(URL(string: "https://music.youtube.com/"))
        // As URLSession hands over several Set-Cookie headers: joined by commas.
        return HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": lines.joined(separator: ", ")], for: url)
    }

    @Test func takesRenewedCookiesButNotDeletions() throws {
        let cookie = "SID=a; __Secure-1PSIDTS=old; SAPISID=s"
        let cookies = try setCookies([
            "__Secure-1PSIDTS=new; Domain=.youtube.com; Path=/; Secure; HttpOnly",
            "SIDCC=c; expires=Fri, 19-Nov-2099 10:00:00 GMT; path=/; domain=youtube.com",
            "SID=EXPIRED; Domain=.youtube.com; Expires=Thu, 01-Jan-1970 00:00:10 GMT",
            "SAPISID=gone; Domain=.youtube.com; Max-Age=0",
            "YSC=host-only; Path=/",
            "NID=z; Domain=.google.com",
        ])
        #expect(GoogleAuth.merge(cookie, setting: cookies, now: .now) == "SID=a; __Secure-1PSIDTS=new; SAPISID=s; SIDCC=c")
        #expect(try GoogleAuth.merge(cookie, setting: setCookies(["SID=a; Domain=.youtube.com"]), now: .now) == nil, "nothing changed")
        #expect(try GoogleAuth.merge(cookie, setting: setCookies(["SID=; Domain=.youtube.com"]), now: .now) == nil)
    }

    @Test func takesOnlyTheSameLoginsCookies() async throws {
        let auth = GoogleAuth()
        try await auth.signIn(cookies: [try cookie("SAPISID", "abc", ".youtube.com")])
        let url = try #require(URL(string: "https://music.youtube.com/youtubei/v1/browse"))
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "SIDCC=new; Domain=.youtube.com"]
        ))
        await auth.take(response, sent: "SAPISID=xyz")
        #expect(await auth.sessionCookie == "SAPISID=abc", "another login's answer")
        await auth.take(response, sent: "SAPISID=abc")
        #expect(await auth.sessionCookie == "SAPISID=abc; SIDCC=new")
        await auth.signOut()
    }

    @Test func noticesAnswersServedSignedOut() {
        let context = { (loggedIn: String) in
            Data(#"""
            {"responseContext":{"serviceTrackingParams":[{"service":"GFEEDBACK",
            "params":[{"key":"browse_id","value":"FEmusic_home"},
            {"key":"logged_in","value":"\#(loggedIn)"}]}]}}
            """#.utf8)
        }
        #expect(GoogleAuth.answeredSignedOut(context("0")))
        #expect(!GoogleAuth.answeredSignedOut(context("1")))
        #expect(!GoogleAuth.answeredSignedOut(Data("{}".utf8)))
    }
}
