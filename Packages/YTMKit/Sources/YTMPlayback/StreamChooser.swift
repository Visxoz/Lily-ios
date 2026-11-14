import Foundation
import os
import Synchronization
import YTMCore

/// Whether the signed-in account plays Premium's 256 kbps streams, as the
/// player has found out so far.
public enum PremiumStatus: Sendable {
    case unknown, premium, notPremium

    /// Settings' line about Premium audio, in ytm-native's words.
    public var summary: String {
        switch self {
        case .premium: "Active: playing 256 kbps Premium streams."
        case .notPremium: "This account has no Premium; playing standard streams."
        case .unknown: "When signed in with YouTube Premium, plays 256 kbps Opus."
        }
    }
}

/// What the Premium path has learnt across songs, as ytm-native's
/// `PremiumShared`: how many songs in a row had no Premium formats, how many
/// requests in a row failed, and the cool-offs that follow.
struct PremiumCounters {
    /// Songs in a row without Premium formats before an account not yet
    /// known to have Premium counts as without it, as some songs simply have
    /// no Premium version.
    static let notPremiumAfter = 3
    /// The same for an account known to have Premium: only a long run of
    /// uploads reaches it, and a lapsed subscription soon does.
    static let lapsedAfter = 20
    /// Cool-off after Premium keeps failing, and between background checks
    /// of an account taken as without Premium.
    static let backoff = Duration.seconds(10 * 60)
    static let maxErrors = 3

    private(set) var status: PremiumStatus
    /// Songs in a row that offered no Premium formats.
    private var misses = 0
    /// Premium requests in a row that failed outright.
    private var errors = 0
    /// The Premium path is skipped until then, after repeated errors.
    private var pausedUntil: ContinuousClock.Instant?
    /// When an account taken as without Premium is next checked, in the
    /// background. A run of music videos, which never have Premium formats,
    /// can mistake a Premium account for one. Unset, a remembered "no" is
    /// checked on the first song.
    var recheckAt: ContinuousClock.Instant?

    /// `known` says the account has been served Premium formats before, and
    /// `none` that it was last taken as without Premium.
    init(known: Bool, none: Bool) {
        status = known ? .premium : none ? .notPremium : .unknown
    }

    /// Whether to go straight to the free stream.
    func skipped(at now: ContinuousClock.Instant) -> Bool {
        status == .notPremium || pausedUntil.map { now < $0 } == true
    }

    /// Whether an account taken as without Premium is due a background
    /// check, claiming it so only one runs.
    mutating func takeRecheck(at now: ContinuousClock.Instant) -> Bool {
        guard status == .notPremium, recheckAt.map({ now >= $0 }) ?? true else { return false }
        recheckAt = now + Self.backoff
        return true
    }

    mutating func recordPremium() {
        status = .premium
        misses = 0
        errors = 0
    }

    mutating func recordMiss(at now: ContinuousClock.Instant) {
        misses += 1
        if misses >= (status == .premium ? Self.lapsedAfter : Self.notPremiumAfter) {
            status = .notPremium
            recheckAt = now + Self.backoff
        }
    }

    /// Returns whether this error started a cool-off.
    mutating func recordError(at now: ContinuousClock.Instant) -> Bool {
        errors += 1
        guard errors >= Self.maxErrors else { return false }
        errors = 0
        pausedUntil = now + Self.backoff
        return true
    }
}

/// Chooses between the Premium and the free stream for a song, as
/// ytm-native's `resolve.rs`, and keeps the Premium path's counters across
/// songs. Safe to call from anywhere: the counters sit behind a lock that is
/// never held across an await.
final class StreamChooser: Sendable {
    private let music: any MusicService
    private let counters = Mutex(PremiumCounters(known: false, none: false))

    init(music: any MusicService) {
        self.music = music
    }

    var status: PremiumStatus { counters.withLock(\.status) }

    /// Starts from what the settings remember of the account.
    func seed(known: Bool, none: Bool) {
        counters.withLock { $0 = PremiumCounters(known: known, none: none) }
    }

    /// A new sign-in, or signing out, says nothing yet about Premium.
    func reset() {
        seed(known: false, none: false)
    }

    /// Premium when `wantPremium` (signed in, High quality) and the account
    /// has it, otherwise the first plain-URL client that answers, and signed
    /// in, the web client as a last resort.
    @concurrent
    func resolve(videoId: String, wantPremium: Bool, signedIn: Bool, quality: AudioQuality) async throws -> ResolvedStream {
        if wantPremium {
            if !counters.withLock({ $0.skipped(at: .now) }) {
                if let stream = try await premium(videoId) { return stream }
            } else if counters.withLock({ $0.takeRecheck(at: .now) }) {
                // Checked off the playback path: this song plays the free
                // stream at once, and the next one gets Premium if it is back.
                Task { [self] in await recheck(videoId) }
            }
        }
        return try await free(videoId, signedIn: signedIn, quality: quality)
    }

    /// A fresh URL for a stream this resolved, asked for by the path that
    /// gave it so it comes back as the same file. Counts nothing towards the
    /// Premium counters, as the song already counted when first resolved.
    @concurrent
    func refresh(videoId: String, wasPremium: Bool, signedIn: Bool, quality: AudioQuality) async throws -> ResolvedStream {
        Logger.playback.info("\(videoId, privacy: .public): stream refused partway; asking for a fresh URL")
        guard wasPremium else { return try await free(videoId, signedIn: signedIn, quality: quality) }
        guard signedIn, case .stream(let stream) = try await music.premiumStream(videoId: videoId, anyFormat: false, maxKbps: nil) else {
            throw YTMError(.unplayable, "The Premium stream couldn't be had again.")
        }
        return stream
    }

    /// The Premium path's answer, counted; nil to play the free stream. An
    /// account known to have Premium plays a song without a Premium version
    /// from the same answer, which saves asking the free clients; one not yet
    /// known counts the song as a miss instead.
    private func premium(_ videoId: String) async throws -> ResolvedStream? {
        let known = status == .premium
        do {
            switch try await music.premiumStream(videoId: videoId, anyFormat: known, maxKbps: nil) {
            case .stream(let stream):
                counters.withLock { stream.isPremium ? $0.recordPremium() : $0.recordMiss(at: .now) }
                return stream
            case .noPremiumFormats:
                counters.withLock { $0.recordMiss(at: .now) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.playback.info("\(videoId, privacy: .public): Premium path failed, using the free stream: \(sentence(for: error), privacy: .public)")
            if counters.withLock({ $0.recordError(at: .now) }) {
                Logger.playback.info("Premium requests keep failing; using free streams for 10 minutes")
            }
        }
        return nil
    }

    /// Asks whether an account taken as without Premium has it after all.
    private func recheck(_ videoId: String) async {
        do {
            switch try await music.premiumStream(videoId: videoId, anyFormat: false, maxKbps: nil) {
            case .stream: counters.withLock { $0.recordPremium() }
            case .noPremiumFormats: counters.withLock { $0.recordMiss(at: .now) }
            }
        } catch {
            Logger.playback.info("\(videoId, privacy: .public): Premium check failed: \(sentence(for: error), privacy: .public)")
        }
    }

    /// The first plain-URL client that answers (YTMCore retries a
    /// bot-checked visitor ID itself), and signed in, the web client's
    /// scrambled URLs through the Premium path's solver as a last resort,
    /// whether or not the account has Premium.
    private func free(_ videoId: String, signedIn: Bool, quality: AudioQuality) async throws -> ResolvedStream {
        do {
            return try await music.stream(videoId: videoId, quality: quality)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard signedIn else { throw error }
            do {
                if case .stream(let stream) = try await music.premiumStream(videoId: videoId, anyFormat: true, maxKbps: quality.maxKbps) {
                    Logger.playback.info("\(videoId, privacy: .public): no client gave a plain URL; playing through the web client")
                    return stream
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.playback.debug("\(videoId, privacy: .public): web client fallback failed: \(sentence(for: error), privacy: .public)")
            }
            throw error
        }
    }
}
