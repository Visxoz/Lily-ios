import CryptoKit
import Foundation

enum LastFMAPI {
    typealias Params = [(name: String, value: String)]
    typealias Play = ScrobbleService.Play
    typealias Session = ScrobbleService.Session
    typealias Failure = ScrobbleService.Failure

    /// From the `LASTFM_API_KEY` and `LASTFM_API_SECRET` build settings.
    struct Keys: Sendable {
        var apiKey: String
        var apiSecret: String

        /// Nil in a build without them, whose settings expand to nothing.
        static let builtIn: Keys? = {
            func value(_ key: String) -> String? {
                (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            guard let apiKey = value("LastFMAPIKey"), let apiSecret = value("LastFMAPISecret") else { return nil }
            return Keys(apiKey: apiKey, apiSecret: apiSecret)
        }()
    }

    private static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")
    private static let authPage = "https://www.last.fm/api/auth/"

    /// Adds `api_sig`: the MD5 of every name and value in byte-wise name order, then the secret, as Last.fm requires.
    static func sign(_ params: inout Params, secret: String) {
        params.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        var md5 = Insecure.MD5()
        for (name, value) in params {
            md5.update(data: Data(name.utf8))
            md5.update(data: Data(value.utf8))
        }
        md5.update(data: Data(secret.utf8))
        let hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        params.append(("api_sig", hex))
    }

    /// `application/x-www-form-urlencoded`: unreserved bytes as they are, spaces as `+`, the rest escaped.
    static func form(_ params: Params) -> Data {
        var body = [UInt8]()
        for (index, (name, value)) in params.enumerated() {
            if index > 0 { body.append(UInt8(ascii: "&")) }
            escape(name, into: &body)
            body.append(UInt8(ascii: "="))
            escape(value, into: &body)
        }
        return Data(body)
    }

    private static func escape(_ string: String, into body: inout [UInt8]) {
        let hex = Array("0123456789ABCDEF".utf8)
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "*"):
                body.append(byte)
            case UInt8(ascii: " "):
                body.append(UInt8(ascii: "+"))
            default:
                body += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0xF)]]
            }
        }
    }

    @concurrent
    static func call(_ method: String, _ params: Params = [], keys: Keys) async throws -> JSON {
        var params = params
        params.append(("method", method))
        params.append(("api_key", keys.apiKey))
        sign(&params, secret: keys.apiSecret)
        // Unsigned, as Last.fm leaves it out of the signature.
        params.append(("format", "json"))

        guard let endpoint else { throw Failure.failed("Last.fm's address couldn't be read.") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = form(params)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, status) = try await ScrobbleService.fetch(request)
        let json = try? JSON(data: data)
        if let json, let code = json["error"].int {
            throw failure(code: code, message: json["message"].string ?? "", method: method)
        }
        // Something other than Last.fm answering, as a gateway's error page, which would otherwise pass for a scrobble.
        guard (200..<300).contains(status) else { throw Failure.failed("Last.fm answered with an error.") }
        guard let json else { throw Failure.failed("Last.fm's answer couldn't be read.") }
        return json
    }

    static func failure(code: Int, message: String, method: String) -> Failure {
        let message = "Last.fm error \(code): \(message)"
        switch code {
        // An invalid or expired token, so connecting has to start again, or invalid parameters.
        case 4 where method.hasPrefix("auth."), 15 where method.hasPrefix("auth."), 6:
            return .rejected(message)
        case 9: return .signedOut
        case 14: return .notYetAllowed
        // An unknown or suspended API key, or a secret that doesn't match it.
        case 10, 13, 26: return .invalidKeys
        // Anything else, 4 on a scrobble among them, is about the account or Last.fm rather than the play, so the
        // plays wait for later.
        default: return .failed(message)
        }
    }

    /// The page where the user allows access, and the token to ask for the session with once they have.
    static func authorise(keys: Keys) async throws -> (page: URL, token: String) {
        let reply = try await call("auth.getToken", keys: keys)
        guard let token = reply["token"].string, var page = URLComponents(string: authPage) else {
            throw Failure.failed("Last.fm's answer couldn't be read.")
        }
        page.queryItems = [URLQueryItem(name: "api_key", value: keys.apiKey), URLQueryItem(name: "token", value: token)]
        guard let url = page.url else { throw Failure.failed("Last.fm's answer couldn't be read.") }
        return (url, token)
    }

    static func session(token: String, keys: Keys) async throws -> Session {
        let reply = try await call("auth.getSession", [("token", token)], keys: keys)
        guard let name = reply["session", "name"].string, let key = reply["session", "key"].string else {
            throw Failure.failed("Last.fm's answer couldn't be read.")
        }
        return Session(name: name, key: key)
    }

    static func nowPlaying(_ play: Play, session: Session, keys: Keys) async throws {
        var params: Params = [("sk", session.key)]
        append(play, suffix: "", to: &params)
        _ = try await call("track.updateNowPlaying", params, keys: keys)
    }

    static func scrobble(_ plays: [Play], session: Session, keys: Keys) async throws -> [String] {
        var params: Params = [("sk", session.key)]
        for (index, play) in plays.enumerated() {
            let suffix = "[\(index)]"
            append(play, suffix: suffix, to: &params)
            params.append(("timestamp" + suffix, String(play.timestamp)))
        }
        return ignored(try await call("track.scrobble", params, keys: keys))
    }

    /// Each name followed by `suffix`, as `[0]` in a batch.
    private static func append(_ play: Play, suffix: String, to params: inout Params) {
        params.append(("artist" + suffix, play.artist))
        params.append(("track" + suffix, play.track))
        if let album = play.album { params.append(("album" + suffix, album)) }
        if let duration = play.duration { params.append(("duration" + suffix, String(duration))) }
    }

    /// One play comes back as an object and more as a list, with the codes as strings.
    static func ignored(_ reply: JSON) -> [String] {
        let plays = reply["scrobbles", "scrobble"]
        return (plays.isObject ? [plays] : plays.array).compactMap { play in
            let message = play["ignoredMessage"]
            guard let code = message["code"].int, code != 0 else { return nil }
            return "code \(code): \(message["#text"].string ?? "")"
        }
    }
}
