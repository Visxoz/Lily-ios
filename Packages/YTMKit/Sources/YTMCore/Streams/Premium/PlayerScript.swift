import Foundation
import os

/// YouTube's web player for one version, cut down to the code that
/// unscrambles stream URLs, as ytm-native's `streams/premium/player.rs`.
struct PlayerScript: Codable, Sendable {
    /// The player version, eight hex digits.
    let id: String
    /// The signature timestamp, which player requests must quote.
    let signatureTimestamp: Int
    /// `PlayerTrimmer`'s script.
    let code: String

    /// Unscrambles an `n` value and a signature, in a throwaway context.
    func solve(n: String?, signature: String?) async throws -> Solver.Solution {
        try await Solver.solve(code, n: n, signature: signature)
    }

    private static let iframeAPI = "https://www.youtube.com/iframe_api"

    /// Inputs the player must change, solved before a new version is
    /// trusted, as it is cached until YouTube's next one, and Premium
    /// formats always need the signature.
    static let checkN = "abcdefghijklmnop"
    static let checkSignature = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz"

    /// The current player: from the store unless YouTube has a newer one,
    /// else fetched, trimmed, checked and saved.
    @concurrent
    static func load(store: FileStore) async throws -> PlayerScript {
        let iframe = try await fetch(iframeAPI)
        guard let id = playerId(inIframeAPI: String(decoding: iframe, as: UTF8.self)) else {
            throw YTMError(.parse, "The version of YouTube's player wasn't found.")
        }
        if let cached = store.load(PlayerScript.self, from: .player), cached.id == id { return cached }

        let clock = ContinuousClock()
        let started = clock.now
        let source = try await [UInt8](fetch("https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js"))
        let fetched = clock.now
        guard let timestamp = signatureTimestamp(in: source) else {
            throw YTMError(.parse, "The signature timestamp wasn't found in YouTube's player.")
        }
        let player = PlayerScript(id: id, signatureTimestamp: timestamp, code: try PlayerTrimmer.trim(source))
        let trimmed = clock.now
        let check = try await player.solve(n: checkN, signature: checkSignature)
        guard check.n != checkN, check.signature != checkSignature else {
            throw YTMError(.unplayable, "YouTube's player didn't unscramble a test URL.")
        }
        Logger.premium.info("""
            player \(id, privacy: .public): fetched in \(fetched - started, privacy: .public), \
            trimmed from \(source.count >> 10) to \(player.code.utf8.count >> 10) KB in \(trimmed - fetched, privacy: .public)
            """)
        store.save(player, to: .player)
        return player
    }

    /// The player version in `iframe_api`, which names it in its script URL.
    static func playerId(inIframeAPI text: String) -> String? {
        for marker in [#"player\/"#, "player/"] {
            guard let start = text.range(of: marker)?.upperBound else { continue }
            let id = text[start...].prefix(8)
            if id.count == 8, id.allSatisfy(\.isHexDigit) { return String(id) }
        }
        return nil
    }

    static func signatureTimestamp(in source: [UInt8]) -> Int? {
        for marker in ["signatureTimestamp:", "sts:"] {
            guard let start = source.firstRange(of: Array(marker.utf8))?.upperBound else { continue }
            let digits = source[start...].prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
            if let value = Int(String(decoding: digits, as: UTF8.self)) { return value }
        }
        return nil
    }

    private static func fetch(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw YTMError(.parse, "The player's address couldn't be made.") }
        var request = URLRequest(url: url)
        request.setValue(ClientProfile.browserUserAgent, forHTTPHeaderField: "User-Agent")
        return try await HTTP.data(for: request).0
    }
}

/// The player the session solves with, as ytm-native's `premium_player`:
/// loaded once and shared by every song, with a pause after a failure so a
/// broken player isn't fetched again for each one. A phone app can run for
/// days, so the version is checked again after a few hours, in the
/// background, while the known player keeps solving.
actor PlayerScripts {
    static let shared = PlayerScripts()

    private static let backoff: Duration = .seconds(10 * 60)
    private static let recheck: Duration = .seconds(6 * 60 * 60)

    private var current: (script: PlayerScript, checked: ContinuousClock.Instant)?
    /// The load in flight, which callers await only while no player is known.
    private var loading: Task<PlayerScript, any Error>?
    private var failed: ContinuousClock.Instant?

    func player(store: FileStore) async throws -> PlayerScript {
        let now = ContinuousClock.now
        let backingOff = failed.map { now - $0 < Self.backoff } ?? false
        if let current {
            // A known script keeps solving while a newer one is fetched behind
            // it, as ytm-native keeps its player for the whole run, so no song
            // waits for the recheck.
            if now - current.checked >= Self.recheck, loading == nil, !backingOff { refresh(store: store) }
            return current.script
        }
        if backingOff {
            throw YTMError.playerUnprepared
        }
        return try await (loading ?? refresh(store: store)).value
    }

    /// Starts the load on the actor, which records its outcome for every
    /// caller. The task can't run before `loading` is set, as the actor is
    /// busy until this returns.
    @discardableResult
    private func refresh(store: FileStore) -> Task<PlayerScript, any Error> {
        let task = Task {
            defer { loading = nil }
            do {
                let script = try await PlayerScript.load(store: store)
                current = (script, .now)
                failed = nil
                return script
            } catch {
                failed = .now
                Logger.premium.error("could not prepare the player: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        loading = task
        return task
    }
}

extension Logger {
    /// What the Premium path did, for Console; never cookies or URLs.
    package static let premium = Logger(subsystem: "YTMusic", category: "Premium")
}
