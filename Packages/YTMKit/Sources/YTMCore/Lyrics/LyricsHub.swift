import Foundation

/// Better Lyrics' hub: Apple Music's, Spicy Lyrics', lrc.red's, QQ Music's, KuGou's and LRCLIB's lyrics in one
/// answer, behind a day's pass got only by passing Cloudflare's check in a browser, which the app runs.
public enum LyricsHub {
    public static let host = "lyrics.api.dacubeking.com"

    /// How a run of Cloudflare's check went.
    public enum Check: Equatable, Sendable {
        case passed(token: String)
        case failed
        /// It couldn't run then, as with the app in the background, so it runs again with the next song.
        case skipped
    }

    public static func useCheck(_ check: @escaping @Sendable () async -> Check) async {
        await HubPass.shared.use(check)
    }

    struct Found: Equatable {
        /// Apple Music's lyrics and those like them, best first.
        var apple: [Lyrics] = []
        var others: [Lyrics] = []
        /// The sites the hub heard back from, with lyrics or without.
        var answered: Set<String> = []
    }

    /// Nil without a pass, which is then fetched for the songs after, or when the hub fails.
    static func lyrics(for track: Track) async -> Found? {
        guard let jwt = await HubPass.shared.current(), let url = URL(string: "https://\(host)/v2/lyrics") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = LyricsSite.query([
            "videoId": track.id, "song": track.title, "artist": track.artistNames, "duration": track.duration.map(String.init), "token": jwt,
        ]).map { Data($0.utf8) }
        do {
            return try await LyricsSite.send(request).map { found(in: $0) }
        } catch let error as YTMError where error.status == 403 {
            await HubPass.shared.refused(jwt)
            return nil
        } catch {
            return nil
        }
    }

    /// The answer's events, `data:` lines of `{"provider": …, "results": {…}}`.
    static func found(in stream: Data) -> Found {
        var byProvider: [String: Lyrics] = [:]
        var answered: Set<String> = []
        let text = String(decoding: stream, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for event in text.components(separatedBy: "\n\n") {
            let data = event.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5).drop(while: \.isWhitespace) }.joined()
            guard let json = try? JSON(data: Data(data.utf8)), let provider = json["provider"].string else { continue }
            answered.insert(provider)
            let results = json["results"]
            let lyrics: Lyrics? = switch provider {
            case "golyrics": results["lyrics"].string.flatMap { ttml(unwrapped($0, "ttml"), "Source: Better Lyrics") }
            case "spicy": results["lyrics"].string.flatMap { ttml($0, "Source: Spicy Lyrics") }
            case "binimum": results["lyrics"].string.flatMap { ttml($0, LrcRed.source) }
            case "qq": results["lyrics"].string.flatMap { qrc(unwrapped($0, "lyrics")) }
            case "kugou": results["lyrics"].string.flatMap { LRC.lyrics(unwrapped($0, "lyrics"), source: KuGou.source) }
            case "lrclib": LRCLIB.lyrics(synced: results["synced"].string, plain: results["plain"].string)
            default: nil
            }
            if let lyrics { byProvider[provider] = lyrics }
        }
        return Found(
            apple: ["golyrics", "spicy", "binimum"].compactMap { byProvider[$0] },
            others: ["qq", "kugou", "lrclib"].compactMap { byProvider[$0] },
            answered: answered
        )
    }

    /// QRC, bare or in QQ Music's XML.
    private static func qrc(_ text: String) -> Lyrics? {
        Tencent.qrc(Tencent.qrcContent(text) ?? text, source: "Source: QQ Music")
    }

    private static func ttml(_ text: String, _ source: String) -> Lyrics? {
        TTML.lyrics(Data(text.utf8), source: source)
    }

    /// Some sites' lyrics come as JSON holding them under `key`.
    private static func unwrapped(_ text: String, _ key: String) -> String {
        guard text.first == "{", let inner = (try? JSON(data: Data(text.utf8)))?[key].string else { return text }
        return inner
    }
}

/// The hub's pass: a JWT good for a day from one address, kept in the Keychain and renewed in the background.
actor HubPass {
    static let shared = HubPass()

    struct Saved: Codable, Equatable {
        var jwt: String
        var issued: Date
        var expiry: Date

        /// Nil unless the JWT says when it was issued and when it lapses.
        init?(jwt: String) {
            let parts = jwt.split(separator: ".")
            guard parts.count == 3 else { return nil }
            var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let data = Data(base64Encoded: base64), let claims = try? JSON(data: data),
                  let issued = claims["iat"].double, let expiry = claims["exp"].double
            else { return nil }
            self.jwt = jwt
            self.issued = Date(timeIntervalSince1970: issued)
            self.expiry = Date(timeIntervalSince1970: expiry)
        }
    }

    private static let key = "lyricsHubPass"
    /// After a check that didn't pass, or a pass refused at once, so a failing check isn't run song after song.
    private static let backOff = Duration.seconds(15 * 60)

    private var check: (@Sendable () async -> LyricsHub.Check)?
    private lazy var saved: Saved? = Keychain.data(for: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    private var renewing = false
    private var retryAfter = ContinuousClock.now

    func use(_ check: @escaping @Sendable () async -> LyricsHub.Check) {
        self.check = check
    }

    /// A pass good for another minute, else nil while a new one is fetched.
    func current() -> String? {
        if let saved, saved.expiry.timeIntervalSinceNow > 60 { return saved.jwt }
        renew()
        return nil
    }

    /// The hub refused `jwt`, as it does once the phone's address changes.
    func refused(_ jwt: String) {
        guard let refused = saved, refused.jwt == jwt else { return }
        if refused.issued.timeIntervalSinceNow > -60 { retryAfter = .now + Self.backOff }
        store(nil)
        renew()
    }

    private func renew() {
        guard !renewing, ContinuousClock.now >= retryAfter, let check else { return }
        renewing = true
        Task {
            let outcome = await check()
            let fresh: Saved? = if case .passed(let token) = outcome { await Self.pass(token) } else { nil }
            renewing = false
            if let fresh { store(fresh) } else if outcome != .skipped { retryAfter = .now + Self.backOff }
        }
    }

    private func store(_ pass: Saved?) {
        saved = pass
        Keychain.set(pass.flatMap { try? JSONEncoder().encode($0) }, for: Self.key)
    }

    private static func pass(_ token: String) async -> Saved? {
        guard let url = URL(string: "https://\(LyricsHub.host)/verify-turnstile"),
              let body = try? JSONSerialization.data(withJSONObject: ["token": token])
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let data = try? await LyricsSite.send(request), let jwt = (try? JSON(data: data))?["jwt"].string else { return nil }
        return Saved(jwt: jwt)
    }
}
