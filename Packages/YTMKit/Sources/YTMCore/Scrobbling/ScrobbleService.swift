import Foundation
import os

/// Last.fm or ListenBrainz. Plays are queued on disk until the service takes them, the session is in the Keychain.
/// When a play counts is the player's to judge.
public actor ScrobbleService {
    public static let lastFM = ScrobbleService(
        name: "Last.fm", client: LastFMAPI.Keys.builtIn.map(Client.lastFM), item: "lastfm.session", file: .scrobbles, store: .shared
    )
    public static let listenBrainz = ScrobbleService(
        name: "ListenBrainz", client: .listenBrainz, item: "listenbrainz.session", file: .listens, store: .shared
    )

    /// Each service's requests, with what they need beyond the account.
    enum Client: Sendable {
        case lastFM(LastFMAPI.Keys)
        case listenBrainz
    }

    /// Last.fm's token lasts an hour, and signing up first can take a while.
    static let pollEvery = Duration.seconds(3)
    static let pollFor = Duration.seconds(20 * 60)
    /// After a failure or a refused play, doubling while the service stays down, so an outage wakes the phone rarely.
    static let retryAfter = Duration.seconds(60)
    static let retryAtMost = Duration.seconds(30 * 60)
    /// Nil outside the app, as in ytmcheck.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    /// "Lily/1.0", as Lily for Windows names itself; plain "Lily" without a version.
    static let userAgent = version.map { "Lily/\($0)" } ?? "Lily"

    private static let log = Logger(subsystem: "Lily", category: "Scrobbling")

    public nonisolated let name: String
    /// Nil for Last.fm in a build without its API keys.
    private nonisolated let client: Client?
    private let item: String
    private let file: StoreFile
    private let store: FileStore
    // Read on first use rather than at launch, so neither the Keychain nor the disk is touched on the main actor.
    private lazy var session: Session? = Self.read(Session.self, from: item)
    private lazy var pending = loadPending()
    private var sending = false
    /// After a refused batch, this many go one by one to find the bad play.
    private var singles = 0
    /// Bumped on connect and disconnect, so late replies are ignored.
    private var generation: UInt64 = 0
    private var retry: Task<Void, Never>?
    private var retryWait = ScrobbleService.retryAfter
    private let revoked: AsyncStream<Void>.Continuation

    /// Yields when the service revokes access; the account is signed out with its plays kept for when it connects
    /// again. One consumer.
    public nonisolated let accessRevoked: AsyncStream<Void>

    /// Sends the plays left from an earlier run; the player makes the shared instances at launch.
    init(name: String, client: Client?, item: String, file: StoreFile, store: FileStore) {
        self.name = name
        self.client = client
        self.item = item
        self.file = file
        self.store = store
        (accessRevoked, revoked) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task { await self.send() }
    }

    public var username: String? { session?.name }
    /// Without the build's API keys, Settings offers no Connect for Last.fm.
    public nonisolated var isAvailable: Bool { client != nil }

    /// Last.fm: opens the page where the user allows access, then polls until they have.
    public func signIn(open: @Sendable (URL) async -> Void) async throws {
        guard case .lastFM(let keys) = client else {
            throw YTMError(.refused, "\(name) isn't available in this build.")
        }
        let generation = begin()
        let deadline = ContinuousClock.now + Self.pollFor
        do {
            let (page, token) = try await LastFMAPI.authorise(keys: keys)
            try current(generation)
            await open(page)
            while true {
                do {
                    let session = try await LastFMAPI.session(token: token, keys: keys)
                    try current(generation)
                    connect(session)
                    return
                } catch let failure as Failure where ContinuousClock.now < deadline {
                    switch failure {
                    case .notYetAllowed, .failed: break
                    case .signedOut, .rejected, .invalidKeys: throw failure
                    }
                }
                try current(generation)
                try await Task.sleep(for: Self.pollEvery)
            }
        } catch let failure as Failure {
            throw notConnected(failure)
        }
    }

    /// ListenBrainz: checks the user token from its settings.
    public func signIn(token: String) async throws {
        guard case .listenBrainz = client else {
            throw YTMError(.refused, "\(name) doesn't sign in with a token.")
        }
        let generation = begin()
        do {
            let session = try await ListenBrainzAPI.validate(token)
            try current(generation)
            connect(session)
        } catch Failure.signedOut {
            throw YTMError(.refused, "\(name) didn't accept that token.")
        } catch let failure as Failure {
            throw notConnected(failure)
        }
    }

    /// Forgets the account, or stops waiting for one. A connected account's unsent plays are dropped, so none reach
    /// the next one; stopping a wait keeps those of an account whose access was revoked.
    public func signOut() {
        let connected = session != nil
        end()
        if connected {
            pending.clear()
            store.save(pending, to: file)
        }
    }

    public func nowPlaying(_ track: Track) async {
        guard let session, let client, let play = Play(track, at: .now) else { return }
        let generation = generation
        do {
            try await client.nowPlaying(play, session: session)
        } catch {
            failed(error, generation: generation)
        }
    }

    public func scrobble(_ track: Track, startedAt: Date) async {
        guard session != nil, let play = Play(track, at: startedAt) else { return }
        pending.push(play)
        store.save(pending, to: file)
        send()
    }

    // MARK: - Sending

    private func send() {
        guard !sending, session != nil, !pending.isEmpty else { return }
        sending = true
        retry?.cancel()
        retry = nil
        Task { await drain() }
    }

    /// Oldest first, until none are left or the service can't take them for now.
    private func drain() async {
        defer { sending = false }
        while let session, let client, !pending.isEmpty {
            let generation = generation
            let batch = pending.batch(one: singles > 0)
            var wait = false
            do {
                for reason in try await client.scrobble(batch, session: session) {
                    Self.log.warning("\(self.name, privacy: .public) ignored a play: \(reason, privacy: .public)")
                }
                if generation == self.generation { sent(batch) }
            } catch Failure.rejected(let message) where generation == self.generation {
                if batch.count > 1 {
                    // One play spoils a batch; find it, and drop it alone.
                    singles = batch.count
                } else {
                    // Waits before the next, so a refusal that isn't about the play costs a play a minute, not all.
                    Self.log.warning("\(self.name, privacy: .public) refused a play: \(message, privacy: .public)")
                    sent(batch)
                    wait = true
                }
            } catch {
                failed(error, generation: generation)
                // An earlier account's reply, whose plays are gone, goes straight on to the plays behind it; a revoked
                // account, ended by `failed`, waits for nothing.
                wait = generation == self.generation
            }
            if wait {
                retryLater()
                return
            }
        }
    }

    /// Drops `batch`, which the service has taken or refused. Saved only here, so a pass that changes nothing, as
    /// offline, rewrites nothing.
    private func sent(_ batch: [Play]) {
        pending.remove(batch)
        singles = max(singles - 1, 0)
        retryWait = Self.retryAfter
        store.save(pending, to: file)
    }

    /// Nothing else may send the plays until another play counts.
    private func retryLater() {
        let wait = retryWait
        retryWait = min(wait * 2, Self.retryAtMost)
        retry = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.send()
        }
    }

    // MARK: - Account

    /// Starts an attempt to connect, overtaking any other.
    private func begin() -> UInt64 {
        generation += 1
        return generation
    }

    private func connect(_ session: Session) {
        self.session = session
        Self.write(session, to: item)
        pending.hold(for: session.name)
        store.save(pending, to: file)
        send()
    }

    private func notConnected(_ failure: Failure) -> YTMError {
        Self.log.error("Could not connect \(self.name, privacy: .public): \(String(describing: failure), privacy: .public)")
        return switch failure {
        case .invalidKeys: YTMError(.refused, "\(name) didn't accept this build's API key.")
        default: YTMError(.network, "Couldn't connect to \(name). Try again in a moment.")
        }
    }

    /// Forgets the account's session, and any reply on its way for it.
    private func end() {
        generation += 1
        session = nil
        singles = 0
        retry?.cancel()
        retry = nil
        retryWait = Self.retryAfter
        Self.write(Session?.none, to: item)
    }

    /// Signs out an account whose access was revoked, keeping its plays. Replies for an earlier account change nothing.
    private func failed(_ error: any Error, generation: UInt64) {
        guard generation == self.generation, let failure = error as? Failure else { return }
        switch failure {
        case .signedOut:
            end()
            revoked.yield()
        case .rejected:
            break
        case .notYetAllowed, .invalidKeys, .failed:
            Self.log.warning("\(self.name, privacy: .public): \(String(describing: failure), privacy: .public)")
        }
    }

    /// Sign-ins end here once cancelled, or overtaken by another sign-in or a sign-out.
    private func current(_ generation: UInt64) throws {
        if generation != self.generation || Task.isCancelled { throw CancellationError() }
    }

    private func loadPending() -> Pending {
        var pending = store.load(Pending.self, from: file) ?? Pending()
        if let name = session?.name { pending.hold(for: name) }
        return pending
    }

    private static func read<T: Decodable>(_ type: T.Type, from item: String) -> T? {
        Keychain.data(for: item).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func write(_ value: (some Encodable)?, to item: String) {
        Keychain.set(value.flatMap { try? JSONEncoder().encode($0) }, for: item)
    }

    /// Not through `HTTP.data`, which fails on the status alone: the services' 4xx errors say whether to retry. The
    /// host check and the guarded `HTTP.api` session still apply. Returns the body and status.
    @concurrent
    static func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url, HTTP.isAllowed(url) else {
            throw Failure.failed("The app blocked a request to a site it doesn't use.")
        }
        var request = request
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await HTTP.api.data(for: request, delegate: NoRedirects.shared)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                throw Failure.failed("The answer couldn't be read.")
            }
            return (data, status)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Failure.failed(YTMError(error).message)
        }
    }
}

/// Keys and tokens go only to the host asked, never on through a redirect, which then fails as an error status.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirects()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

extension ScrobbleService {
    /// Last.fm's session key or a ListenBrainz token. Neither expires, but either can be revoked (`Failure.signedOut`).
    struct Session: Codable, Sendable {
        var name: String
        var key: String
    }

    struct Play: Codable, Hashable, Sendable {
        var artist: String
        var track: String
        var album: String?
        /// In seconds.
        var duration: Int?
        /// The play's start, in Unix seconds.
        var timestamp: Int64
    }

    enum Failure: Error, Equatable {
        /// The account's access was revoked, or its token refused; it has to connect again.
        case signedOut
        case notYetAllowed
        /// Refused as sent (bad parameters, an expired token); retrying won't help.
        case rejected(String)
        /// Last.fm's built-in keys are unknown, suspended or mismatched. Plays wait, as for `failed`, but connecting
        /// stops.
        case invalidKeys
        /// The service could not be reached or could not answer; try again later.
        case failed(String)
    }
}

extension ScrobbleService.Play {
    /// Nil without the artist or title both services refuse a play without.
    init?(_ track: Track, at start: Date) {
        // The first artist, as Last.fm's catalogue lists features in the title rather than as artists.
        artist = track.artists.first?.name ?? ""
        self.track = track.title
        album = track.album?.name
        duration = track.duration
        timestamp = Int64(start.timeIntervalSince1970)
        if artist.isEmpty || self.track.isEmpty { return nil }
    }
}

extension ScrobbleService.Client {
    func nowPlaying(_ play: ScrobbleService.Play, session: ScrobbleService.Session) async throws {
        switch self {
        case .lastFM(let keys): try await LastFMAPI.nowPlaying(play, session: session, keys: keys)
        case .listenBrainz: try await ListenBrainzAPI.nowPlaying(play, session: session)
        }
    }

    /// At most a batch; returns why the service ignored any, which will never be taken, so they go like the others.
    func scrobble(_ plays: [ScrobbleService.Play], session: ScrobbleService.Session) async throws -> [String] {
        switch self {
        case .lastFM(let keys):
            return try await LastFMAPI.scrobble(plays, session: session, keys: keys)
        case .listenBrainz:
            try await ListenBrainzAPI.scrobble(plays, session: session)
            return []
        }
    }
}
