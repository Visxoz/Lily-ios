import Foundation

/// The free stream path, as ytm-native's `streams/mod.rs`: the `player`
/// endpoint asked as the clients YouTube hands plain URLs to, so playing
/// needs no player script.
///
/// The clients are tried in order, each only once the one before fails:
/// YouTube tends to change one at a time, so a song plays on the next while
/// the first is broken, and the rest cost nothing while it works.
struct StreamResolver: Sendable {
    let innerTube: InnerTube

    /// The best stream within `maxKbps`, from the first client that gives
    /// one. YouTube sometimes bot-checks a visitor ID, so when every client
    /// fails, they are asked once more with a fresh one, which is kept only
    /// if it works: both failing points at the song, not the ID.
    func resolve(videoId: String, maxKbps: Int?) async throws -> ResolvedStream {
        let visitor = try await innerTube.visitorData()
        do {
            return try await resolveWithClients(videoId: videoId, maxKbps: maxKbps, visitorData: visitor)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fresh = try await innerTube.candidateVisitorData(replacing: visitor)
            let stream = try await resolveWithClients(videoId: videoId, maxKbps: maxKbps, visitorData: fresh)
            await innerTube.adoptVisitorData(fresh, replacing: visitor)
            return stream
        }
    }

    /// Fails with the first client's reason when none gives a stream, as
    /// the first is the usual one.
    private func resolveWithClients(videoId: String, maxKbps: Int?, visitorData: String) async throws -> ResolvedStream {
        var firstError: (any Error)?
        for client in ClientProfile.plainStreamClients {
            do {
                return try await resolve(videoId: videoId, as: client, maxKbps: maxKbps, visitorData: visitorData)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? Self.noAudio
    }

    func resolve(videoId: String, as client: ClientProfile, maxKbps: Int?, visitorData: String? = nil) async throws -> ResolvedStream {
        try Self.stream(
            in: await player(videoId: videoId, as: client, visitorData: visitorData),
            userAgent: client.userAgent, maxKbps: maxKbps
        )
    }

    /// The `player` response for `videoId`, asked signed out as `client`,
    /// with `visitorData` or else the saved visitor ID.
    func player(videoId: String, as client: ClientProfile, visitorData: String? = nil) async throws -> JSON {
        // Not retried, as ytm-native's resolve_with: the next client is the
        // retry, so a broken one costs a request rather than the song.
        try await innerTube.post(
            "player",
            body: ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true],
            client: client,
            authenticated: false,
            visitorData: visitorData,
            retries: 0
        )
    }

    /// The best plain-URL stream of a player response. A client that
    /// answers with scrambled URLs only counts as having none.
    static func stream(in json: JSON, userAgent: String, maxKbps: Int?) throws -> ResolvedStream {
        let response = try PlayerResponse(json: json)
        guard let format = bestAudio(response.formats, maxKbps: maxKbps),
              let url = format.url.flatMap(URL.init(string:)), HTTP.isAllowed(url)
        else { throw noAudio }
        return makeStream(format, url: url, userAgent: userAgent, response: response, isPremium: false)
    }

    static let noAudio = YTMError(.unplayable, "YouTube offered no audio the app can play.")
}
