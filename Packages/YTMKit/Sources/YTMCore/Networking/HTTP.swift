import Foundation

/// The app's own HTTP sessions, limited to the hosts YouTube Music and
/// Last.fm need.
///
/// Every URL taken from a response (artwork, streams, the player script) is
/// checked with `isAllowed` before it is requested, and every redirect is too,
/// so a hostile or broken response can never send the app elsewhere.
enum HTTP {
    /// Domains requested with their subdomains: YouTube's API and player, the
    /// audio streams and artwork, as ytm-native's `ALLOWED_DOMAINS`.
    private static let domains = [
        "youtube.com",
        "googlevideo.com",
        "ytimg.com",
        "googleusercontent.com",
        "ggpht.com",
        // Built-in artwork, such as Liked music's.
        "gstatic.com",
    ]
    /// Last.fm's API and its sign-in page, on these hosts only.
    private static let hosts: Set<String> = ["ws.audioscrobbler.com", "www.last.fm"]

    /// Whether the app may request `url`: HTTPS on an allowed host.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), !host.isEmpty else {
            return false
        }
        return hosts.contains(host) || domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// InnerTube and Last.fm calls. Nothing is cached and no cookie is kept:
    /// the signed-in Cookie header is set per request from the Keychain.
    /// URLSession decompresses gzip and Brotli on its own.
    static let api: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        // As ytm-native's client: a request that has not answered in 15 s is
        // not going to.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    /// Artwork: a disk cache that outlives launches, so rows scroll in from
    /// disk rather than the network, kept small as a screen's images are a
    /// few kilobytes each, and more connections per host, as a screen of
    /// cards asks for many images at once.
    static let media: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 8 << 20,
            diskCapacity: 20 << 20,
            directory: URL.cachesDirectory.appending(path: "artwork", directoryHint: .isDirectory)
        )
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    /// Performs `request` after checking its host, and fails on any status
    /// outside 2xx. Errors say what went wrong without the URL, which may
    /// carry stream signatures.
    ///
    /// With `retries`, a server error, a 429 or a timeout is asked again up
    /// to that many times, after about 1 s, then 3 s, as rustypipe's
    /// `http_request` rides them out.
    static func data(
        for request: URLRequest, session: URLSession = api, retries: Int = 0
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, isAllowed(url) else {
            throw YTMError(.refused, "The app blocked a request to a site it doesn't use.")
        }
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw YTMError(.network, "The server's answer couldn't be read.")
                }
                if (200..<300).contains(http.statusCode) { return (data, http) }
                guard attempt < retries, isTransient(status: http.statusCode) else {
                    throw YTMError(status: http.statusCode)
                }
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard attempt < retries, error.code == .timedOut else { throw YTMError(error) }
            }
            try await Task.sleep(for: retryDelay(after: attempt))
            attempt += 1
        }
    }

    /// A status worth asking again for: the server's own trouble, or its
    /// asking the app to slow down.
    static func isTransient(status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }

    /// rustypipe's `retry_delay(n, 1000, 60000, 3)`: 3^n seconds with a
    /// jitter of 0.8 to 1.5, so callers refused together don't ask again
    /// together, kept within 1 s to 60 s.
    static func retryDelay(after attempt: Int) -> Duration {
        let milliseconds = pow(3, Double(attempt)) * Double.random(in: 800..<1500)
        return .milliseconds(Int(min(max(milliseconds, 1000), 60_000)))
    }
}

/// The host allowlist, for the modules that request URLs YTMCore handed
/// them: the audio engine's stream downloads can't import YTMCore, so the
/// player checks each stream URL, refreshed ones too, before passing it on.
public enum HostAllowlist {
    public static func allows(_ url: URL) -> Bool { HTTP.isAllowed(url) }
}

/// Follows a redirect only to an allowed host; any other ends the request
/// with the redirect's own status, which `HTTP.data` reports as refused.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectGuard()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url.map(HTTP.isAllowed) == true ? request : nil
    }
}

extension YTMError {
    /// A transport failure, in words fit to show.
    init(_ error: URLError) {
        let message = switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            "You're offline."
        case .timedOut:
            "The server took too long to answer."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            "The server couldn't be reached."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "A secure connection couldn't be made."
        default:
            "The connection failed."
        }
        self.init(.network, message)
    }

    /// A status outside 2xx. A redirect only gets here when `RedirectGuard`
    /// refused to follow it.
    init(status: Int) {
        let message = switch status {
        case 300..<400: "The server sent the app to a site it doesn't use."
        case 401, 403: "The server refused the request (\(status))."
        case 404: "The server couldn't find that (404)."
        case 429: "The server is limiting requests; try again in a moment."
        case 500...: "The server had a problem (\(status))."
        default: "The request failed (\(status))."
        }
        self.init(.http, message, status: status)
    }
}
