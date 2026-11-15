import Foundation

/// YouTube's internal API, `youtubei/v1`, as the app speaks it: one POST per
/// call, with the client's context, the visitor ID and, signed in, the
/// account's cookies and hashes.
final class InnerTube: Sendable {
    let auth: GoogleAuth
    private let visitor: VisitorData

    /// English, so parsers can read YouTube's labels ("Song", "1.2M"), and
    /// the US, which picks charts and catalogue: rustypipe's defaults, which
    /// ytm-native never changes.
    static let language = "en"
    static let country = "US"

    /// How many times a 5xx, a 429 or a timeout is asked again, as
    /// rustypipe's default `n_http_retries`.
    static let retries = 2

    /// The consent cookie a browser that dismissed YouTube's banner sends,
    /// so signed-out web requests from Europe get pages, not the banner.
    static let consentCookie = "SOCS=CAISAiAD"

    init(auth: GoogleAuth, store: FileStore) {
        self.auth = auth
        visitor = VisitorData(store: store, request: VisitorData.request)
    }

    /// POSTs `body` to `endpoint` (such as "browse", "next", "search") as
    /// `client`, and returns the parsed answer.
    ///
    /// The client's `context.client` is merged in under any keys `body`
    /// gives there itself. `authenticated` sends the account's cookies when
    /// signed in, for web clients; signed out, or with it false, the request
    /// is anonymous. `visitorData` stands in for the saved visitor ID, to
    /// try one before keeping it. `retries` is how many times a 5xx, a 429
    /// or a timeout is asked again; requests with a fallback of their own
    /// pass 0. Runs, and parses, off the caller's actor.
    @concurrent
    func post(
        _ endpoint: String, body: [String: Any] = [:], client: ClientProfile = .webRemix,
        authenticated: Bool = true, visitorData: String? = nil, retries: Int = InnerTube.retries
    ) async throws -> JSON {
        guard let url = client.url(endpoint) else {
            throw YTMError(.parse, "The request couldn't be made.")
        }
        let visitorData = if let visitorData { visitorData } else { try await visitor.value() }
        var body = body
        var context = body["context"] as? [String: Any] ?? [:]
        context["client"] = client.context(hl: Self.language, gl: Self.country, visitorData: visitorData)
            .merging(context["client"] as? [String: Any] ?? [:]) { $1 }
        body["context"] = context
        guard JSONSerialization.isValidJSONObject(body) else {
            throw YTMError(.parse, "The request couldn't be made.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var headers = client.headers(visitorData: visitorData)
        if client.isWeb {
            if authenticated, let origin = client.origin, let account = await auth.headers(origin: origin) {
                headers.merge(account) { $1 }
            } else {
                headers["Cookie"] = Self.consentCookie
            }
        }
        request.allHTTPHeaderFields = headers
        let (data, _) = try await HTTP.data(for: request, retries: retries)
        return try JSON(data: data)
    }

    /// A browse page by its ID, with `params` when the page wants them.
    func browse(_ browseId: String, params: String? = nil, authenticated: Bool = true) async throws -> JSON {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await post("browse", body: body, authenticated: authenticated)
    }

    /// The page after `token` of a browse list.
    func continuation(_ token: String, authenticated: Bool = true) async throws -> JSON {
        try await post("browse", body: ["continuation": token], authenticated: authenticated)
    }

    /// The visitor ID requests are sent with; streams' players want it too.
    func visitorData() async throws -> String {
        try await visitor.value()
    }

    /// A visitor ID to try in place of `refused`, which YouTube may have
    /// refused, without keeping it yet. Callers asking together share one
    /// fetch.
    func candidateVisitorData(replacing refused: String) async throws -> String {
        try await visitor.candidate(replacing: refused)
    }

    /// Keeps `candidate`, which worked where `refused` failed, for every
    /// request after.
    func adoptVisitorData(_ candidate: String, replacing refused: String) async {
        await visitor.adopt(candidate, replacing: refused)
    }
}

/// The visitor ID YouTube identifies a signed-out browser by, which
/// InnerTube wants with every request. Fetched from YouTube Music's
/// `visitor_id` endpoint as the patched rustypipe's `util/visitor_data.rs`
/// does, and saved, so a launch needs no fetch; once a day old it is
/// replaced in the background.
///
/// A fresh ID only replaces the saved one once it has worked where the
/// saved one failed, as ytm-native's `forget_visitor`: both failing points
/// at the song, not the ID.
actor VisitorData {
    private struct Saved: Codable, Sendable {
        let value: String
        let fetched: Date
    }

    private static let maxAge: TimeInterval = 24 * 60 * 60
    private let store: FileStore
    private let request: @Sendable () async throws -> String
    private lazy var saved: Saved? = store.load(Saved.self, from: .visitor)
    /// The fetch in flight, which every caller arriving meanwhile awaits.
    private var fetching: Task<String, any Error>?

    init(store: FileStore, request: @escaping @Sendable () async throws -> String) {
        self.store = store
        self.request = request
    }

    /// The saved ID, or, with none saved, a new one, kept. A saved ID a day
    /// old is still sent while a new one is fetched behind it, as rustypipe
    /// refreshes its pool, so no request waits on the refresh.
    func value() async throws -> String {
        guard let saved else {
            let value = try await fetch()
            // Callers that shared the fetch keep it once.
            if self.saved.map(Self.isFresh) != true { keep(value) }
            return value
        }
        if !Self.isFresh(saved), fetching == nil {
            Task { try? await refresh() }
        }
        return saved.value
    }

    /// Replaces a day-old ID; a failed fetch leaves it in use.
    private func refresh() async throws {
        // Requests arriving before the first refresh starts each queue one;
        // those behind a finished refresh have nothing to do.
        guard saved.map(Self.isFresh) != true else { return }
        let value = try await fetch()
        if saved.map(Self.isFresh) != true { keep(value) }
    }

    /// An ID to try in place of `refused`: the saved one if another caller
    /// has replaced it already, else a new one, not kept.
    func candidate(replacing refused: String) async throws -> String {
        if let saved, saved.value != refused { return saved.value }
        return try await fetch()
    }

    /// Keeps `candidate` in place of `refused`, unless another caller has
    /// replaced it already.
    func adopt(_ candidate: String, replacing refused: String) {
        guard saved.map({ $0.value == refused }) ?? true else { return }
        keep(candidate)
    }

    private func fetch() async throws -> String {
        if let fetching { return try await fetching.value }
        let request = request
        let task = Task { try await request() }
        fetching = task
        defer { fetching = nil }
        return try await task.value
    }

    private func keep(_ value: String) {
        let saved = Saved(value: value, fetched: .now)
        self.saved = saved
        store.save(saved, to: .visitor)
    }

    private static func isFresh(_ saved: Saved) -> Bool {
        -saved.fetched.timeIntervalSinceNow < maxAge
    }

    /// The endpoint's answer, or YouTube Music's home page when the endpoint
    /// answers in another shape. A refusal (an HTTP error or a redirect)
    /// fails at once: the page, on the same host, would be refused too.
    static func request() async throws -> String {
        let client = ClientProfile.webRemix
        guard let url = client.url("visitor_id"), let home = URL(string: "https://music.youtube.com/") else {
            throw YTMError(.parse, "The request couldn't be made.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": client.name, "clientVersion": client.version]],
        ])
        request.allHTTPHeaderFields = client.headers(visitorData: nil).merging(["Cookie": InnerTube.consentCookie]) { $1 }
        let (data, _) = try await HTTP.data(for: request)
        if let value = try? JSON(data: data)["responseContext", "visitorData"].string, isUsable(value) {
            return value
        }

        var page = URLRequest(url: home)
        page.allHTTPHeaderFields = ["User-Agent": client.userAgent, "Cookie": InnerTube.consentCookie]
        let (html, _) = try await HTTP.data(for: page)
        guard let value = visitorData(inPage: String(decoding: html, as: UTF8.self)) else {
            throw YTMError(.parse, "YouTube didn't give the app a visitor ID.")
        }
        return value
    }

    /// The first `"visitorData":"…"` in YouTube's page.
    static func visitorData(inPage html: String) -> String? {
        let marker = #""visitorData":""#
        guard let start = html.range(of: marker)?.upperBound,
              let end = html[start...].firstIndex(of: "\"")
        else { return nil }
        let value = String(html[start..<end])
        return isUsable(value) ? value : nil
    }

    /// Sent as a header with every request, so it must be one: base64url
    /// and percent escapes only.
    private static func isUsable(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-%=".contains($0)) }
    }
}
