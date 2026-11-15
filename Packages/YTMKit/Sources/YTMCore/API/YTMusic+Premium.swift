import Foundation

/// What the Premium path found for a song.
public enum PremiumOutcome: Sendable {
    /// A Premium stream, or with `anyFormat` the best the web client has.
    case stream(ResolvedStream)
    /// No Premium version of this song: music videos and uploads often have
    /// none, so this says nothing about the account on its own.
    case noPremiumFormats
}

extension YTMusic {
    /// The Premium path (signed in, High): 774/141 via the web clients and the JavaScriptCore solver.
    /// `anyFormat` takes the web client's best when it has no Premium format, as ytm-native's last resort.
    /// `maxKbps` caps that best, for the last resort at Low and Normal quality; a cap rules out Premium formats.
    @concurrent
    public func premiumStream(videoId: String, anyFormat: Bool, maxKbps: Int? = nil) async throws -> PremiumOutcome {
        let player: PlayerScript
        do {
            player = try await PlayerScripts.shared.player(store: store)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // `PlayerScripts` has logged the real reason already.
            throw YTMError.playerUnprepared
        }
        return try await PremiumResolver(innerTube: innerTube, player: player).resolve(
            videoId: videoId, signedIn: auth.isSignedIn, anyFormat: anyFormat, maxKbps: maxKbps
        )
    }

    /// Prepares the Premium path's player script ahead of the first song, as
    /// ytm-native's `warm_premium`, so that song doesn't wait for it. A
    /// failure is left for the song to meet, after the script's own back-off.
    @concurrent
    public func preparePremium() async {
        _ = try? await PlayerScripts.shared.player(store: store)
    }
}

extension YTMError {
    /// The Premium path's player script couldn't be had, which says nothing
    /// about the account, so the player doesn't count it as a Premium
    /// failure, as ytm-native's `premium_player`.
    public static let playerUnprepared = YTMError(.unplayable, "YouTube's player couldn't be prepared; trying again in a few minutes.")
}
