import CryptoKit
import Foundation
import os

/// Spotify's Canvas, the looping clip behind a song, read as its web player reads it with the user's session cookie.
actor SpotifyCanvas {
    /// What the web player's script holds: the newest key its token codes are made with, and the search's hash.
    struct Config: Codable, Equatable, Sendable {
        let version: Int
        let secret: String
        let search: String
    }

    struct Token: Sendable {
        let bearer: String
        let expires: Date
    }

    struct Session: Sendable {
        let config: Config
        let token: Token
    }

    /// A song as Spotify's search answers it.
    struct Candidate: Sendable {
        let uri: String
        let name: String
        let artists: [String]
        let album: String?
        let seconds: Double?
    }

    private static let keychainKey = "spotify"
    /// How long Spotify's 4.6 MB script is left alone once read, found or not, so a refusal soon after is final.
    private static let backoff: Duration = .seconds(10 * 60)
    private static let notSession = YTMError(.notSignedIn, "Spotify didn't sign you in: try again.")
    private static let searchMoved = YTMError(.parse, "Spotify's search has moved.")
    private static let unread = YTMError(.parse, "Spotify's player script held no key.")

    /// Kept across launches, so a launch needn't fetch the script.
    private let configFile: URL
    /// Read lazily, on this actor rather than whichever thread made the instance.
    private lazy var cookie: String? = Keychain.data(for: Self.keychainKey).map { String(decoding: $0, as: UTF8.self) }
    private var config: Config?
    private var scraped: ContinuousClock.Instant?
    /// When the script last held no key, kept apart as the key then in use isn't fresh.
    private var failed: ContinuousClock.Instant?
    private var token: Token?
    private var minting: Task<Session, any Error>?
    /// Spotify refused what was fresh from its script, so it isn't asked again until sign-in or relaunch.
    private var withdrawn = false

    init(configFile: URL) {
        self.configFile = configFile
    }

    var isSignedIn: Bool { cookie != nil }

    /// Keeps the `sp_dc` cookie once Spotify mints a signed-in token with it.
    func signIn(cookie text: String) async throws {
        var cookie = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cookie.hasPrefix("sp_dc=") { cookie.removeFirst(6) }
        // It goes into a header, so nothing that could end or split one.
        guard !cookie.isEmpty, cookie.unicodeScalars.allSatisfy({ (0x21..<0x7f).contains($0.value) && $0 != ";" && $0 != "," })
        else { throw YTMError(.notSignedIn, "That isn't an sp_dc cookie.") }
        let session = try await mint(cookie: cookie, stale: nil, cellular: true)
        self.cookie = cookie
        token = session.token
        minting = nil
        withdrawn = false
        Keychain.set(Data(cookie.utf8), for: Self.keychainKey)
    }

    func signOut() {
        cookie = nil
        token = nil
        minting = nil
        Keychain.set(nil, for: Self.keychainKey)
    }

    /// The song's Canvas under `.tall`: empty when Spotify surely has none, nil when it couldn't be asked.
    func covers(title: String, artists: [String], album: String?, duration: Int?, cellular: Bool) async -> [MotionShape: MotionCover]? {
        guard cookie != nil, !withdrawn else { return nil }
        guard let artist = artists.first else { return [:] }
        var stale: Config?
        var asked: Session?
        for attempt in 0..<2 {
            let used = cookie
            do {
                let session = try await session(cellular: cellular, stale: stale)
                asked = session
                let found = try await Self.search("\(title) \(artist)", session: session, cellular: cellular)
                let uris = Self.matches(found, title: title, artist: artist, album: album, duration: duration)
                if uris.isEmpty { return [:] }
                return try await Self.canvas(for: uris, bearer: session.token.bearer, cellular: cellular).map { [.tall: $0] } ?? [:]
            } catch let error as YTMError where error == Self.notSession {
                Logger.motion.error("Spotify's cookie no longer signs in.")
                // Unless signed in again since.
                if cookie == used { signOut() }
                return nil
            } catch let error as YTMError where attempt == 0 && error == Self.searchMoved {
                stale = asked?.config
            } catch let error as YTMError where attempt == 0 && error.kind == .http && error.status == 401 {
                // A token can lapse before its time, so a fresh one is tried.
                if let asked, token?.bearer == asked.token.bearer { token = nil }
            } catch {
                // Refused fresh, or a script without a key: it would fail again this launch.
                if let error = error as? YTMError, error.kind == .refused || error.status == 401 || [Self.searchMoved, Self.unread].contains(error) {
                    withdrawn = true
                }
                Logger.motion.error("Spotify's Canvas couldn't be had: \(sentence(for: error), privacy: .public)")
                return nil
            }
        }
        return nil
    }

    // MARK: - Token

    /// One mint shared by every caller waiting; `stale` is a config Spotify's search no longer takes.
    private func session(cellular: Bool, stale: Config?) async throws -> Session {
        if let config, config != stale, let token, token.expires > .now { return Session(config: config, token: token) }
        guard let cookie else { throw YTMError(.notSignedIn, "Spotify isn't signed in.") }
        // A caller with a stale config mints its own, as one under way may keep that config.
        let task = (stale == nil ? minting : nil) ?? Task { try await self.mint(cookie: cookie, stale: stale, cellular: cellular) }
        minting = task
        let result = await task.result
        // Unless signed out or in again since.
        if minting == task {
            minting = nil
            if self.cookie == cookie, case .success(let session) = result { token = session.token }
        }
        return try result.get()
    }

    private func mint(cookie: String, stale: Config?, cellular: Bool) async throws -> Session {
        guard var config = try await self.config(cellular: cellular, replacing: stale) else { throw Self.unread }
        while true {
            do {
                return Session(config: config, token: try await Self.token(cookie: cookie, config: config, cellular: cellular))
            } catch let error as YTMError where [400, 401, 403].contains(error.status) {
                // A code refused may mean Spotify moved to a newer key, so its script is read again, once.
                guard let fresh = try await self.config(cellular: cellular, replacing: config) else {
                    // Refused with a key fresh from the script: an unauthorised one means the cookie no longer signs in.
                    if error.status == 401 { throw Self.notSession }
                    throw YTMError(.refused, "Spotify refused its web player's key.", status: error.status)
                }
                config = fresh
            }
        }
    }

    /// The config in use unless `stale`, else last launch's, else the script's; nil when the script was just read.
    private func config(cellular: Bool, replacing stale: Config?) async throws -> Config? {
        if let config, config != stale { return config }
        if config == nil, let saved = await Self.load(configFile), saved != stale {
            config = saved
            return saved
        }
        if let scraped, .now - scraped < Self.backoff { return nil }
        if let failed, .now - failed < Self.backoff { throw Self.unread }
        do {
            let fresh = try await Self.scrape(savingTo: configFile, cellular: cellular)
            scraped = .now
            config = fresh
            return fresh
        } catch {
            // Only a script without one is waited out; a network that failed may be back by the next song.
            if (error as? YTMError)?.kind == .parse { failed = .now }
            throw error
        }
    }

    @concurrent
    private static func load(_ file: URL) async -> Config? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    }

    @concurrent
    private static func scrape(savingTo file: URL, cellular: Bool) async throws -> Config {
        let page = try await HTTP.data(for: request("https://open.spotify.com/", cellular: cellular)).0
        guard let script = scriptURL(inPage: String(decoding: page, as: UTF8.self)) else {
            throw YTMError(.parse, "Spotify's player script wasn't found.")
        }
        guard let config = config(inScript: try await MotionLookup.fetch(script, cellular: cellular)) else { throw unread }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(config).write(to: file, options: .atomic)
        return config
    }

    @concurrent
    private static func token(cookie: String, config: Config, cellular: Bool) async throws -> Token {
        let code = totp(key: key(fromSecret: config.secret), at: .now)
        var request = try request(
            "https://open.spotify.com/api/token?reason=init&productType=web-player&totp=\(code)&totpServer=\(code)&totpVer=\(config.version)",
            cellular: cellular
        )
        request.setValue("sp_dc=\(cookie)", forHTTPHeaderField: "Cookie")
        let answer = try JSON(data: try await HTTP.data(for: request).0)
        if answer["isAnonymous"].bool == true { throw notSession }
        guard let bearer = answer["accessToken"].string, let expires = answer["accessTokenExpirationTimestampMs"].double else {
            throw YTMError(.parse, "Spotify's token answer couldn't be read.")
        }
        // Dropped a minute early, so none lapses mid-request.
        return Token(bearer: bearer, expires: Date(timeIntervalSince1970: expires / 1000 - 60))
    }

    // MARK: - Search and Canvas

    @concurrent
    private static func search(_ query: String, session: Session, cellular: Bool) async throws -> [Candidate] {
        let body: [String: Any] = [
            "operationName": "searchSuggestions",
            "variables": [
                "query": query, "limit": 10, "numberOfTopResults": 10, "offset": 0, "includeAuthors": false,
                "includeEpisodeContentRatingsV2": false,
            ],
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": session.config.search]],
        ]
        var request = try request("https://api-partner.spotify.com/pathfinder/v2/query", cellular: cellular, bearer: session.token.bearer)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WebPlayer", forHTTPHeaderField: "App-Platform")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do {
            data = try await HTTP.data(for: request).0
        } catch let error as YTMError where error.status == 400 || error.status == 412 {
            // Spotify answers a hash it no longer knows with 412 "Invalid query hash".
            throw searchMoved
        }
        let answer = try JSON(data: data)
        if answer["errors"].array.contains(where: { $0["message"].string?.contains("PersistedQueryNotFound") == true }) {
            throw searchMoved
        }
        guard let found = candidates(in: answer) else { throw YTMError(.parse, "Spotify's search answer couldn't be read.") }
        return found
    }

    /// The tracks among the top results; nil for an answer in another shape, so it isn't taken for none.
    static func candidates(in answer: JSON) -> [Candidate]? {
        let items = answer["data", "searchV2", "topResultsV2", "itemsV2"]
        guard items.isArray else { return nil }
        return items.array.compactMap { item in
            let track = item["item", "data"]
            guard track["__typename"].string == "Track", let uri = track["uri"].string, let name = track["name"].string else {
                return nil
            }
            return Candidate(
                uri: uri, name: name, artists: track["artists", "items"].array.compactMap { $0["profile", "name"].string },
                album: track["albumOfTrack", "name"].string,
                seconds: track["duration", "totalMilliseconds"].double.map { $0 / 1000 }
            )
        }
    }

    /// The tracks that surely are the song, its album's first: a wrong Canvas is worse than none.
    static func matches(_ candidates: [Candidate], title: String, artist: String, album: String?, duration: Int?) -> [String] {
        let title = MotionLookup.normalised(title)
        let artist = MotionLookup.normalised(artist)
        // A name of only symbols would match every other such name.
        guard !title.isEmpty, !artist.isEmpty else { return [] }
        let sure = candidates.filter { candidate in
            MotionLookup.normalised(candidate.name) == title
                && candidate.artists.contains { MotionLookup.credits($0).contains(artist) }
                && duration.map { duration in candidate.seconds.map { abs($0 - Double(duration)) <= 3 } ?? false } ?? true
        }
        let album = album.map(MotionLookup.normalised).flatMap { $0.isEmpty ? nil : $0 }
        var seen = Set<String>()
        // On-album first; `seen` drops their second copy and Spotify's own repeats.
        return (sure.filter { $0.album.map(MotionLookup.normalised) == album } + sure).map(\.uri).filter { seen.insert($0).inserted }
    }

    /// One request for every match; the first of them, in order, with a looping video.
    @concurrent
    private static func canvas(for uris: [String], bearer: String, cellular: Bool) async throws -> MotionCover? {
        var request = try request("https://spclient.wg.spotify.com/canvaz-cache/v0/canvases", cellular: cellular, bearer: bearer)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/protobuf", forHTTPHeaderField: "Accept")
        request.httpBody = canvasRequest(uris)
        guard let canvases = canvases(in: try await HTTP.data(for: request).0) else {
            throw YTMError(.parse, "Spotify's Canvas answer couldn't be read.")
        }
        return uris.lazy.compactMap { canvases[$0] }.first
    }

    private static func request(_ address: String, cellular: Bool, bearer: String? = nil) throws -> URLRequest {
        guard let url = URL(string: address) else { throw YTMError(.parse, "Spotify's address couldn't be made.") }
        var request = MotionLookup.request(url, cellular: cellular)
        request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

// MARK: - Script, codes and protobuf

extension SpotifyCanvas {
    /// The web player's main script, as its page names it; its stylesheet of the same name comes first.
    static func scriptURL(inPage html: String) -> URL? {
        let prefix = "https://open.spotifycdn.com/cdn/build/web-player/web-player."
        var rest = html[...]
        while let start = rest.range(of: prefix)?.upperBound {
            let name = rest[start...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }
            if !name.isEmpty, rest[name.endIndex...].hasPrefix(".js") { return URL(string: prefix + name + ".js") }
            rest = rest[name.endIndex...]
        }
        return nil
    }

    /// The newest of the script's `{secret:'…',version:N}` keys and the search's hash, read from its bytes in place.
    static func config(inScript script: Data) -> Config? {
        var best: (version: Int, secret: String)?
        var rest = script[...]
        let field = Array("secret:".utf8)
        let tag = Array(",version:".utf8)
        while let marker = rest.firstRange(of: field) {
            rest = rest[marker.upperBound...]
            // Most are a variable's name, not a literal.
            guard let quote = rest.first, quote == UInt8(ascii: "'") || quote == UInt8(ascii: "\"") else { continue }
            var secret: [UInt8] = []
            var index = rest.startIndex + 1
            while index < rest.endIndex, rest[index] != quote {
                // An escaped character is taken as it is.
                if rest[index] == UInt8(ascii: "\\") { index += 1 }
                if index < rest.endIndex { secret.append(rest[index]) }
                index += 1
            }
            guard index < rest.endIndex else { break }
            rest = rest[(index + 1)...]
            guard rest.starts(with: tag) else { continue }
            let digits = rest.dropFirst(tag.count).prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
            if let version = Int(String(decoding: digits, as: UTF8.self)), version > best?.version ?? .min {
                best = (version, String(decoding: secret, as: UTF8.self))
            }
        }
        guard let best, let start = script.firstRange(of: Array(#""searchSuggestions","query",""#.utf8))?.upperBound else {
            return nil
        }
        let hash = script[start...].prefix(65)
        let isHex = { (byte: UInt8) in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
        guard hash.count == 65, hash.last == UInt8(ascii: "\""), hash.dropLast().allSatisfy(isHex) else { return nil }
        return Config(version: best.version, secret: best.secret, search: String(decoding: hash.dropLast(), as: UTF8.self))
    }

    /// As the web player derives it: each character's code XOR a rolling 9 to 41, written out in decimal.
    static func key(fromSecret secret: String) -> Data {
        Data(secret.utf16.enumerated().map { String($0.element ^ UInt16($0.offset % 33 + 9)) }.joined().utf8)
    }

    /// RFC 6238 with SHA-1, 30 s steps and six digits.
    static func totp(key: Data, at date: Date) -> String {
        let counter = withUnsafeBytes(of: UInt64(max(date.timeIntervalSince1970, 0) / 30).bigEndian) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: counter, using: SymmetricKey(data: key)))
        // SHA-1 is 20 bytes, so the offset's four bytes are always within.
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let code = mac[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) } & 0x7fff_ffff
        let digits = String(code % 1_000_000)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// `EntityCanvazRequest`: an `Entity { entity_uri = 1 }` in field 1 for each track.
    static func canvasRequest(_ uris: [String]) -> Data {
        uris.reduce(into: Data()) { body, uri in body += Protobuf.field(1, Protobuf.field(1, Data(uri.utf8))) }
    }

    /// `EntityCanvazResponse`'s looping videos by track; nil when it isn't protobuf. Spotify's 9:16 stills are passed
    /// over, as the still is made from the clip once cropped to 3:4.
    static func canvases(in response: Data) -> [String: MotionCover]? {
        guard let fields = Protobuf.fields(of: Array(response)[...]) else { return nil }
        var covers: [String: MotionCover] = [:]
        for case (1, .bytes(let canvas)) in fields {
            guard let fields = Protobuf.fields(of: canvas) else { return nil }
            var video: URL?, uri: String?, type: UInt64 = 0
            for field in fields {
                switch field {
                case (2, .bytes(let bytes)): video = URL(string: String(decoding: bytes, as: UTF8.self))
                case (4, .varint(let value)): type = value
                case (5, .bytes(let bytes)): uri = String(decoding: bytes, as: UTF8.self)
                default: break
                }
            }
            // 1 to 3 are videos; 0 is a still image and 4 a GIF.
            guard let uri, covers[uri] == nil, (1...3).contains(type), let video, video.pathExtension == "mp4", HTTP.isAllowed(video)
            else { continue }
            covers[uri] = MotionCover(video: video, still: nil)
        }
        return covers
    }
}
