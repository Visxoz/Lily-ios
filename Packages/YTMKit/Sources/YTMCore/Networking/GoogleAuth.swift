import CryptoKit
import Foundation

/// The signed-in Google session: YouTube's cookies, kept in the Keychain as
/// one `Cookie` header, and the `Authorization` hashes YouTube's web client
/// derives from them for each request.
public actor GoogleAuth {
    public static let shared = GoogleAuth()

    private static let keychainKey = "google.cookie"
    /// The cookies the Authorization hashes are made from, in the order
    /// YouTube's web client sends the schemes.
    private static let sessionCookies = ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"]

    /// The `Cookie` header, read from the Keychain the first time it is
    /// needed, on this actor rather than whichever thread made the instance.
    private lazy var cookie: String? = Keychain.data(for: Self.keychainKey).map { String(decoding: $0, as: UTF8.self) }

    public init() {}

    public var isSignedIn: Bool { cookie != nil }

    /// Keeps the session cookies of .youtube.com / .google.com read from the sign-in web view.
    public func signIn(cookies: [HTTPCookie]) throws {
        guard let header = Self.cookieHeader(cookies) else {
            throw YTMError(.notSignedIn, "Signing in didn't finish: Google gave no session. Try again.")
        }
        cookie = header
        Keychain.set(Data(header.utf8), for: Self.keychainKey)
    }

    public func signOut() {
        cookie = nil
        Keychain.set(nil, for: Self.keychainKey)
    }

    /// What a request as the signed-in account carries to `origin`, such as
    /// `https://music.youtube.com`, or nil when signed out.
    func headers(origin: String) -> [String: String]? {
        guard let cookie else { return nil }
        var headers = ["Cookie": cookie, "X-Goog-AuthUser": "0", "X-Origin": origin, "Origin": origin]
        headers["Authorization"] = Self.authorization(cookie: cookie, origin: origin, time: Int(Date.now.timeIntervalSince1970))
        return headers
    }

    /// One `Cookie` header of the unexpired cookies set for youtube.com or
    /// google.com, each name once, YouTube's own first; nil without a
    /// session cookie to sign requests with.
    static func cookieHeader(_ cookies: [HTTPCookie]) -> String? {
        let now = Date.now
        func domain(_ cookie: HTTPCookie) -> String? {
            let host = cookie.domain.lowercased().trimmingPrefix(".")
            return ["youtube.com", "google.com"].first { host == $0 || host.hasSuffix("." + $0) }
        }
        let kept = cookies
            .filter { cookie in cookie.expiresDate.map { $0 > now } ?? true }
            .compactMap { cookie in domain(cookie).map { (cookie, $0) } }
            .sorted { $0.1 == "youtube.com" && $1.1 != "youtube.com" }
        var names = Set<String>()
        let pairs = kept.compactMap { cookie, _ in
            names.insert(cookie.name).inserted ? "\(cookie.name)=\(cookie.value)" : nil
        }
        guard !names.isDisjoint(with: sessionCookies) else { return nil }
        return pairs.joined(separator: "; ")
    }

    /// The `Authorization` header YouTube's web player sends: for each
    /// session cookie present, `SCHEME <time>_<sha1("<time> <cookie> <origin>")>`,
    /// space-separated. SAPISIDHASH falls back to the 3P cookie, as
    /// ytm-native's `authorization` does.
    static func authorization(cookie: String, origin: String, time: Int) -> String? {
        let value = { (name: String) in
            cookie.split(separator: ";").lazy.compactMap { pair -> Substring? in
                let pair = pair.trimmingPrefix(" ")
                guard let eq = pair.firstIndex(of: "="), pair[..<eq] == name else { return nil }
                return pair[pair.index(after: eq)...]
            }.first
        }
        let schemes: [(String, Substring?)] = [
            ("SAPISIDHASH", value("SAPISID") ?? value("__Secure-3PAPISID")),
            ("SAPISID1PHASH", value("__Secure-1PAPISID")),
            ("SAPISID3PHASH", value("__Secure-3PAPISID")),
        ]
        let parts = schemes.compactMap { scheme, id -> String? in
            guard let id else { return nil }
            let digest = Insecure.SHA1.hash(data: Data("\(time) \(id) \(origin)".utf8))
            return "\(scheme) \(time)_\(digest.map { String(format: "%02x", $0) }.joined())"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
