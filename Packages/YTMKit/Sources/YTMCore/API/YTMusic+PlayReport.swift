import Foundation

extension YTMusic {
    /// Pings the signed-in player response's stats URL so the play shows in the account's history.
    ///
    /// As ytm-native's `api/history.rs` and YouTube Music's website: the
    /// account's player response for the song carries a stats URL, which is
    /// requested with the account's cookie, so the song shapes its
    /// recommendations too.
    @concurrent
    public func reportPlay(videoId: String) async throws {
        let client = ClientProfile.webRemix
        guard let origin = client.origin, let cookie = await auth.headers(origin: origin)?["Cookie"] else {
            throw YTMError(.notSignedIn, "Sign in to keep a YouTube history.")
        }
        let player = try await innerTube.post("player", body: ["videoId": videoId], client: client)
        guard let url = PlayReport.pingURL(in: player, client: client.name) else {
            throw YTMError(.parse, "YouTube didn't say where to report the play.")
        }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = ["User-Agent": client.userAgent, "Cookie": cookie]
        _ = try await HTTP.data(for: request)
    }
}

/// The stats ping the web player sends as a song starts.
enum PlayReport {
    /// The response's playback stats URL with the parameters the web player
    /// adds. Nil without one, or when it is anywhere but youtube.com: it is
    /// sent the account's cookie.
    static func pingURL(in player: JSON, client: String) -> URL? {
        guard let base = player["playbackTracking", "videostatsPlaybackUrl", "baseUrl"].string,
              var parts = URLComponents(string: base),
              let host = parts.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com")
        else { return nil }
        parts.percentEncodedQueryItems = (parts.percentEncodedQueryItems ?? []) + [
            URLQueryItem(name: "ver", value: "2"),
            URLQueryItem(name: "c", value: client),
            URLQueryItem(name: "cpn", value: cpn()),
        ]
        return parts.url.flatMap { HTTP.isAllowed($0) ? $0 : nil }
    }

    /// A client playback nonce: 16 random characters from the alphabet the
    /// web player draws them from.
    static func cpn() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}
