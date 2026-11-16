import Foundation
import os

/// Scrobbling to Last.fm, as ytm-native's `lastfm.rs` and `app/scrobble.rs`:
/// connecting an account through the browser, showing what is playing, and
/// logging plays, queued on disk until Last.fm takes them.
///
/// The API keys are built in, as ytm-native's, and the account's session
/// lives in the Keychain. When a play counts is the player's to judge; this
/// sends what it is given.
public actor LastFM {
    public static let shared = LastFM(store: .shared)

    /// How often to ask whether the user has allowed access, and for how
    /// long before giving up. The token lasts an hour, and someone who first
    /// has to sign up or reset a password can take a while.
    static let pollEvery = Duration.seconds(3)
    static let pollFor = Duration.seconds(20 * 60)
    /// How long to wait before sending again after Last.fm could not take
    /// the plays, or refused one.
    static let retryAfter = Duration.seconds(60)

    private static let sessionItem = "lastfm.session"
    private static let log = Logger(subsystem: "YTMusic", category: "LastFM")

    private let store: FileStore
    private let keys = Keys.builtIn
    // Read on first use rather than at launch, so neither the Keychain nor
    // the disk is touched on the main actor.
    private lazy var session: Session? = Self.read(Session.self, from: Self.sessionItem)
    private lazy var pending = loadPending()
    /// A batch is on its way to Last.fm.
    private var sending = false
    /// Last.fm refused a batch as invalid, so this many of its plays go one
    /// at a time, to find the one it refuses and drop it alone.
    private var singles = 0
    /// Bumped by connecting and disconnecting, so replies for an earlier
    /// account or attempt are ignored.
    private var generation: UInt64 = 0
    private var retry: Task<Void, Never>?
    private let revoked: AsyncStream<Void>.Continuation

    /// Yields when Last.fm stops allowing access to the account, which is
    /// then signed out with its plays kept for when it connects again. The
    /// app says so, as ytm-native's toast does. One consumer.
    public nonisolated let accessRevoked: AsyncStream<Void>

    /// Sends the plays left over from a run that couldn't reach Last.fm, as
    /// ytm-native's `start` does: the player makes the shared instance as
    /// the app starts.
    init(store: FileStore) {
        self.store = store
        (accessRevoked, revoked) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task { await self.send() }
    }

    public var username: String? { session?.name }
    /// Whether this build has the API keys, without which Settings offers
    /// no Connect, as ytm-native's `available`.
    public static var isAvailable: Bool { Keys.builtIn != nil }

    /// Connects an account: opens the page where the user allows access,
    /// then asks every few seconds whether they have, through any brief
    /// failure to reach Last.fm. Ends with the task's cancellation, or with
    /// another sign-in or a sign-out.
    public func signIn(open: @Sendable (URL) async -> Void) async throws {
        guard let keys else {
            throw YTMError(.refused, "Last.fm isn't available in this build.")
        }
        generation += 1
        let generation = generation
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
            Self.log.error("Could not connect Last.fm: \(String(describing: failure), privacy: .public)")
            throw failure == .invalidKeys
                ? YTMError(.refused, "Last.fm didn't accept this build's API key.")
                : YTMError(.network, "Couldn't connect to Last.fm. Try again in a moment.")
        }
    }

    /// Forgets the account, or stops waiting for one to connect. Plays not
    /// yet sent are dropped with an account, so none reach the next one;
    /// stopping a wait keeps those of an account whose access was revoked.
    public func signOut() {
        let connected = session != nil
        end()
        if connected {
            pending.clear()
            store.save(pending, to: .scrobbles)
        }
    }

    /// Shows `track`, just started, as what the account is listening to.
    public func nowPlaying(_ track: Track) async {
        guard let session, let keys, let play = Play(track, at: .now) else { return }
        let generation = generation
        do {
            try await LastFMAPI.nowPlaying(play, session: session, keys: keys)
        } catch {
            failed(error, generation: generation)
        }
    }

    /// Logs a play that counted, queued on disk until Last.fm takes it.
    public func scrobble(_ track: Track, startedAt: Date) async {
        guard session != nil, let play = Play(track, at: startedAt) else { return }
        pending.push(play)
        store.save(pending, to: .scrobbles)
        send()
    }

    // MARK: - Sending

    /// Starts sending the plays Last.fm has yet to take, unless already.
    private func send() {
        guard !sending, session != nil, !pending.isEmpty else { return }
        sending = true
        retry?.cancel()
        retry = nil
        Task { await drain() }
    }

    /// Sends the oldest plays, then the rest, saving them as each answer
    /// comes, until none are left or Last.fm can't take them for now.
    private func drain() async {
        defer { sending = false }
        while let session, let keys, !pending.isEmpty {
            let generation = generation
            let batch = pending.batch(one: singles > 0)
            var wait = false
            do {
                for reason in try await LastFMAPI.scrobble(batch, session: session, keys: keys) {
                    Self.log.warning("Last.fm ignored a play: \(reason, privacy: .public)")
                }
                if generation == self.generation { sent(batch) }
            } catch Failure.rejected(let message) where generation == self.generation {
                if batch.count > 1 {
                    // One play spoils a batch; find it, and drop it alone.
                    singles = batch.count
                } else {
                    // Waits before the next, so a refusal that isn't about
                    // the play costs a play a minute, not them all.
                    Self.log.warning("Last.fm refused a play: \(message, privacy: .public)")
                    sent(batch)
                    wait = true
                }
            } catch {
                // An earlier account's reply, whose plays are gone, goes
                // straight on to the plays that waited behind it.
                wait = generation == self.generation
                failed(error, generation: generation)
            }
            store.save(pending, to: .scrobbles)
            if wait {
                retryLater()
                return
            }
        }
    }

    /// Drops `batch`, which Last.fm has taken or refused.
    private func sent(_ batch: [Play]) {
        pending.remove(batch)
        singles = max(singles - 1, 0)
    }

    /// Tries the plays again in a while, as nothing else may send them until
    /// another play counts.
    private func retryLater() {
        retry = Task { [weak self] in
            try? await Task.sleep(for: Self.retryAfter)
            guard !Task.isCancelled else { return }
            await self?.send()
        }
    }

    // MARK: - Account

    private func connect(_ session: Session) {
        self.session = session
        Self.write(session, to: Self.sessionItem)
        pending.hold(for: session.name)
        store.save(pending, to: .scrobbles)
        send()
    }

    /// Forgets the account's session, and any reply on its way for it.
    private func end() {
        generation += 1
        session = nil
        singles = 0
        retry?.cancel()
        retry = nil
        Self.write(Session?.none, to: Self.sessionItem)
    }

    /// Forgets an account whose access was revoked, keeping its plays;
    /// other failures keep the plays for the next attempt. Replies for an
    /// earlier account change nothing.
    private func failed(_ error: any Error, generation: UInt64) {
        guard generation == self.generation, let failure = error as? Failure else { return }
        switch failure {
        case .signedOut:
            end()
            revoked.yield()
        case .rejected:
            break
        case .notYetAllowed, .invalidKeys, .failed:
            Self.log.warning("Last.fm: \(String(describing: failure), privacy: .public)")
        }
    }

    /// Throws when a sign-in or sign-out has overtaken the attempt.
    private func current(_ generation: UInt64) throws {
        if generation != self.generation { throw CancellationError() }
    }

    private func loadPending() -> Pending {
        var pending = store.load(Pending.self, from: .scrobbles) ?? Pending()
        if let name = session?.name { pending.hold(for: name) }
        return pending
    }

    private static func read<T: Decodable>(_ type: T.Type, from item: String) -> T? {
        Keychain.data(for: item).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func write(_ value: (some Encodable)?, to item: String) {
        Keychain.set(value.flatMap { try? JSONEncoder().encode($0) }, for: item)
    }
}
