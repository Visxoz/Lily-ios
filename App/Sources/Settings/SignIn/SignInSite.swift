import Foundation
import YTMCore

/// A site whose own page signs in, and what its cookies hand the app once it has.
struct SignInSite<Session> {
    let title: String
    let startURL: URL?
    /// Begins the sentence shown when the page can't go on.
    let failure: String
    /// Whether the page may show `url`.
    let allows: (URL) -> Bool
    /// Which refused links open in the browser.
    let opensInBrowser: (URL) -> Bool
    /// Pages on these hosts come once signed in, so the session is looked for before they load.
    let isSignedInHost: (String) -> Bool
    /// The session among the page's cookies; nil while it is still signing in.
    let session: ([HTTPCookie]) -> Session?
}

extension SignInSite<[HTTPCookie]> {
    /// YouTube Music's cookies, HttpOnly ones included, once Google has set a session among them.
    static var google: Self {
        Self(
            title: "Sign in",
            startURL: URL(
                string: "https://accounts.google.com/ServiceLogin?service=youtube&passive=true"
                    + "&continue=https%3A%2F%2Fmusic.youtube.com%2F"
            ),
            failure: "Couldn't sign in with Google:",
            allows: SignInHosts.allows,
            opensInBrowser: SignInHosts.opensInBrowser,
            isSignedInHost: SignInHosts.isYouTube,
            session: SignInHosts.session
        )
    }
}

extension SignInSite<String> {
    /// The web player's session cookie, the only sign-in Spotify gives Canvas to.
    static var spotify: Self {
        Self(
            title: "Spotify",
            startURL: URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F"),
            failure: "Couldn't sign in to Spotify:",
            allows: SpotifyHosts.allows,
            opensInBrowser: SpotifyHosts.opensInBrowser,
            isSignedInHost: { $0 == SpotifyHosts.player },
            session: { $0.first(where: SpotifyHosts.isSession)?.value }
        )
    }
}

/// The hosts Spotify's sign-in may show, its login partners' among them.
private nonisolated enum SpotifyHosts {
    static let player = "open.spotify.com"
    private static let domain = "spotify.com"
    /// Exact hosts, so lookalikes such as accounts.spotify.com.example.com are refused.
    private static let hosts: Set<String> = [
        "accounts.spotify.com", "challenge.spotify.com", player, "www.spotify.com",
        "appleid.apple.com", "www.facebook.com", "m.facebook.com",
    ]
    /// Never handed to the system: sign-in hops carry tokens in their URLs; iOS gives player links to Spotify's app.
    private static let keptDomains = [player, "google.com", "youtube.com", "apple.com", "facebook.com"]

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host() else { return false }
        // Continuing with Google passes through its own sign-in's hosts.
        return hosts.contains(host) || SignInHosts.isGoogleSignIn(host)
    }

    static func opensInBrowser(_ url: URL) -> Bool {
        guard url.scheme == "https" || url.scheme == "http", let host = url.host() else { return false }
        return !host.hasPrefix("accounts.") && !keptDomains.contains { HostAllowlist.isHost(host, within: $0) }
    }

    static func isSession(_ cookie: HTTPCookie) -> Bool {
        cookie.name == "sp_dc" && !cookie.value.isEmpty && HostAllowlist.isHost(cookie.domain.trimmingPrefix("."), within: domain)
    }
}
