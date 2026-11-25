import Foundation

/// ListenBrainz's listens, sent with the user token from its settings page.
enum ListenBrainzAPI {
    typealias Play = ScrobbleService.Play
    typealias Session = ScrobbleService.Session
    typealias Failure = ScrobbleService.Failure

    private static let submitURL = URL(string: "https://api.listenbrainz.org/1/submit-listens")
    private static let validateURL = URL(string: "https://api.listenbrainz.org/1/validate-token")

    struct Submission: Encodable {
        let listenType: String
        let payload: [Listen]
    }

    struct Listen: Encodable {
        struct Metadata: Encodable {
            let artistName: String
            let trackName: String
            let releaseName: String?
            let additionalInfo: Info
        }

        struct Info: Encodable {
            var mediaPlayer = "Lily"
            var submissionClient = "Lily"
            var submissionClientVersion = ScrobbleService.version
            var musicService = "music.youtube.com"
            let durationMs: Int?
        }

        /// Nil while playing now.
        let listenedAt: Int64?
        let trackMetadata: Metadata

        init(_ play: Play, listenedAt: Int64?) {
            self.listenedAt = listenedAt
            trackMetadata = Metadata(
                artistName: play.artist, trackName: play.track, releaseName: play.album,
                // Left out at 0 s, which it refuses.
                additionalInfo: Info(durationMs: play.duration.flatMap { $0 > 0 ? $0 * 1000 : nil })
            )
        }
    }

    /// Tokens are UUIDs; anything else is refused before it reaches a header.
    static func isToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Checks a token pasted by the user, returning the account it is for.
    static func validate(_ token: String) async throws -> Session {
        guard isToken(token) else { throw Failure.signedOut }
        guard let reply = try await call(validateURL, token: token) else {
            throw Failure.failed("ListenBrainz's answer couldn't be read.")
        }
        guard reply["valid"].bool == true, let name = reply["user_name"].string, !name.isEmpty else {
            throw Failure.signedOut
        }
        return Session(name: name, key: token)
    }

    static func nowPlaying(_ play: Play, session: Session) async throws {
        try await submit(Submission(listenType: "playing_now", payload: [Listen(play, listenedAt: nil)]), session: session)
    }

    static func scrobble(_ plays: [Play], session: Session) async throws {
        let listens = plays.map { Listen($0, listenedAt: $0.timestamp) }
        try await submit(Submission(listenType: listens.count == 1 ? "single" : "import", payload: listens), session: session)
    }

    static func body(_ submission: Submission) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(submission)
    }

    private static func submit(_ submission: Submission, session: Session) async throws {
        // Something other than ListenBrainz answering, as a captive portal's page, would otherwise pass for a listen.
        guard try await call(submitURL, body: body(submission), token: session.key)?["status"].string == "ok" else {
            throw Failure.failed("ListenBrainz's answer couldn't be read.")
        }
    }

    /// The body of a success, as JSON when it reads as such.
    @concurrent
    private static func call(_ url: URL?, body: Data? = nil, token: String) async throws -> JSON? {
        guard let url else { throw Failure.failed("ListenBrainz's address couldn't be read.") }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await ScrobbleService.fetch(request)
        let json = try? JSON(data: data)
        if (200..<300).contains(status) { return json }
        throw failure(status: status, error: json?["error"].string ?? "")
    }

    static func failure(status: Int, error: String) -> Failure {
        let message = "ListenBrainz answered \(status): \(error)"
        return switch status {
        case 401: .signedOut
        // Only the listens it can't read; rate limits and outages wait.
        case 400: .rejected(message)
        default: .failed(message)
        }
    }
}
