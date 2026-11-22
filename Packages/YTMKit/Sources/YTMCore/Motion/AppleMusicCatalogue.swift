import Foundation
import os

/// Apple Music's catalogue, read as its web player reads it, with the token shipped in that player's script.
actor AppleMusicCatalogue {
    /// Shipped to every visitor of music.apple.com, so no secret, but never logged all the same.
    struct Token: Sendable {
        let jwt: String
        let expires: Date
        /// When it was read from Apple's script; nil for the last launch's file.
        var fetched: ContinuousClock.Instant?
    }

    /// How long Apple is left alone after its script held no token, as each try costs the 3.3 MB script; also how
    /// long a token counts as fresh, so a refusal of it is final.
    private static let backoff: Duration = .seconds(10 * 60)

    private let storefront: String
    /// Kept across launches, so a launch needn't fetch the script.
    private let tokenFile: URL
    private var token: Token?
    private var fetching: Task<Token, any Error>?
    private var failed: ContinuousClock.Instant?
    /// Apple refused a token fresh from its own script, so it isn't asked again this launch.
    private var withdrawn = false

    init(storefront: String, tokenFile: URL) {
        self.storefront = storefront
        self.tokenFile = tokenFile
    }

    /// The album's moving covers by shape: empty when Apple has none that surely match, nil when it couldn't be asked.
    func covers(album: String, artist: String, cellular: Bool) async -> [MotionShape: MotionCover]? {
        for attempt in 0..<2 {
            guard let token = await bearer(cellular: cellular) else { return nil }
            do {
                let request = try searchRequest("\(artist) \(album)", jwt: token.jwt, cellular: cellular)
                let data = try await HTTP.data(for: request).0
                return Self.covers(in: try JSON(data: data)["results", "albums", "data"].array, album: album, artist: artist)
            } catch let error as YTMError where error.status == 401 {
                // A token kept a while may have been withdrawn, so the script's current one is tried; a fresh one refused is final.
                refuse(token.jwt)
                guard attempt == 0, token.fetched.map({ .now - $0 > Self.backoff }) ?? true else {
                    withdrawn = true
                    break
                }
            } catch {
                Logger.motion.error("Apple Music's search failed: \(sentence(for: error), privacy: .public)")
                return nil
            }
        }
        Logger.motion.error("Apple Music refused its web player's token.")
        return nil
    }

    /// The album whose name and artist surely match, first among those with a moving cover: a wrong cover is worse
    /// than none, so nothing looser is tried.
    static func covers(in albums: [JSON], album: String, artist: String) -> [MotionShape: MotionCover] {
        let album = MotionLookup.normalised(album)
        let artist = MotionLookup.normalised(artist)
        // A name of only symbols, as "÷", would match every other such name.
        guard !album.isEmpty, !artist.isEmpty else { return [:] }
        for item in albums {
            let attributes = item["attributes"]
            guard let name = attributes["name"].string, MotionLookup.normalised(name) == album,
                  let by = attributes["artistName"].string, MotionLookup.credits(by).contains(artist)
            else { continue }
            var covers: [MotionShape: MotionCover] = [:]
            for shape in MotionShape.allCases {
                let cover = attributes["editorialVideo", shape.editorialKey]
                if let video = cover["video"].string.flatMap(URL.init(string:)), HTTP.isAllowed(video) {
                    covers[shape] = MotionCover(video: video, still: cover["previewFrame", "url"].string.flatMap(shape.still))
                }
            }
            if !covers.isEmpty { return covers }
        }
        return [:]
    }

    private func searchRequest(_ term: String, jwt: String, cellular: Bool) throws -> URLRequest {
        var search = URLComponents()
        search.scheme = "https"
        search.host = "amp-api.music.apple.com"
        search.path = "/v1/catalog/\(storefront)/search"
        search.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "albums"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "extend", value: "editorialVideo"),
            // Only what the match reads: a quarter of the answer.
            URLQueryItem(name: "fields[albums]", value: "name,artistName,editorialVideo"),
        ]
        // Left as it is, a "+" in a name would be read as a space.
        search.percentEncodedQuery = search.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = search.url else { throw YTMError(.parse, "The search's address couldn't be made.") }
        var request = MotionLookup.request(url, cellular: cellular)
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        // Apple refuses the token from anywhere but its own player.
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        return request
    }

    // MARK: - Token

    /// One fetch shared by every search waiting, and none while backing off.
    private func bearer(cellular: Bool) async -> Token? {
        if let token, token.expires > .now { return token }
        if withdrawn { return nil }
        if let failed, ContinuousClock.now - failed < Self.backoff { return nil }
        let task = fetching ?? Task { [storefront, tokenFile] in
            try await Self.fetchToken(storefront: storefront, savedAt: tokenFile, cellular: cellular)
        }
        fetching = task
        let result = await task.result
        if fetching == task {
            fetching = nil
            token = try? result.get()
            if case .failure(let error) = result {
                Logger.motion.error("Apple Music's token couldn't be had: \(sentence(for: error), privacy: .public)")
                // Only a script without one is waited out; a network that failed, or wasn't allowed, may be back
                // by the next song, and the script's slow download has no deadline but silence.
                if (error as? YTMError)?.kind == .parse { failed = .now }
            }
        }
        return try? result.get()
    }

    /// Unless a fresher token has replaced it since.
    private func refuse(_ jwt: String) {
        guard token?.jwt == jwt else { return }
        token = nil
        try? FileManager.default.removeItem(at: tokenFile)
    }

    /// The saved token while it lasts, else the one in the web player's script, which its page names.
    @concurrent
    private static func fetchToken(storefront: String, savedAt file: URL, cellular: Bool) async throws -> Token {
        if let saved = try? String(contentsOf: file, encoding: .utf8), let expires = webPlayExpiry(saved),
           expires > .now {
            return Token(jwt: saved, expires: expires)
        }
        guard let page = URL(string: "https://music.apple.com/\(storefront)/new") else {
            throw YTMError(.parse, "Apple Music's address couldn't be made.")
        }
        let html = String(decoding: try await MotionLookup.fetch(page, cellular: cellular), as: UTF8.self)
        guard let path = scriptPath(inPage: html), let script = URL(string: "https://music.apple.com" + path) else {
            throw YTMError(.parse, "Apple Music's player script wasn't found.")
        }
        guard var token = webPlayToken(in: try await MotionLookup.fetch(script, cellular: cellular)) else {
            throw YTMError(.parse, "Apple Music's player script held no token.")
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(token.jwt.utf8).write(to: file, options: .atomic)
        token.fetched = .now
        return token
    }

    /// The player's module script; the legacy one for old browsers is passed over.
    static func scriptPath(inPage html: String) -> String? {
        var rest = html[...]
        while let quote = rest.range(of: "\"/assets/index")?.lowerBound {
            let path = rest[rest.index(after: quote)...].prefix { $0 != "\"" }
            if path.hasSuffix(".js"), !path.contains("legacy") { return String(path) }
            rest = rest[path.endIndex...]
        }
        return nil
    }

    /// The script holds several tokens, as `eyJ…` header.payload.signature; Apple's catalogue takes only the web
    /// player's.
    static func webPlayToken(in script: Data) -> Token? {
        let marker = Array("eyJ".utf8)
        var rest = script[...]
        while let start = rest.firstRange(of: marker)?.lowerBound {
            let jwt = rest[start...].prefix(while: isTokenByte)
            let text = String(decoding: jwt, as: UTF8.self)
            if let expires = webPlayExpiry(text) { return Token(jwt: text, expires: expires) }
            rest = rest[jwt.endIndex...]
        }
        return nil
    }

    /// When the web player's token lapses, from its payload; nil for any other token.
    static func webPlayExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = Data(base64URLEncoded: parts[1]), let claims = try? JSON(data: data),
              claims["iss"].string == "AMPWebPlay", let expires = claims["exp"].double
        else { return nil }
        return Date(timeIntervalSince1970: expires)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        let character = Character(Unicode.Scalar(byte))
        return (character.isASCII && (character.isLetter || character.isNumber)) || "-_.".contains(character)
    }
}

extension MotionShape {
    /// The key of the shape's clip in an album's `editorialVideo`.
    var editorialKey: String {
        switch self {
        case .square: "motionDetailSquare"
        case .tall: "motionDetailTall"
        }
    }

    /// Apple's still from its address template, at the size Now Playing and the lock screen draw it.
    func still(_ template: String) -> URL? {
        let size = self == .tall ? "720x960" : "720x720"
        let address = template.replacingOccurrences(of: "{w}x{h}", with: size)
            .replacingOccurrences(of: "{c}", with: "bb").replacingOccurrences(of: "{f}", with: "jpg")
        return URL(string: address).flatMap { HTTP.isAllowed($0) ? $0 : nil }
    }
}
