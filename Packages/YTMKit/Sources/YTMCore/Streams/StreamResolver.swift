import Foundation
import os
import Synchronization

/// The free path: asks the clients YouTube hands plain URLs to, so playing needs no player script. Each is tried only
/// once the one before fails, as YouTube tends to break one at a time.
struct StreamResolver: Sendable {
    let innerTube: InnerTube

    private static let log = Logger(subsystem: "Lily", category: "Streams")

    /// Clients whose URLs googlevideo cuts off here, as it does past the first megabyte on networks where it wants a
    /// PO token, the one refused longest ago first. Kept for the session.
    private static let cutOffClients = Mutex<[String]>([])

    static func cutOff(client: String) {
        guard ClientProfile.plainStreamClients.contains(where: { $0.name == client }),
              cutOffClients.withLock({ mark(&$0, client) }) else { return }
        log.warning("\(client, privacy: .public) streams are cut off here; asking other clients first from now on")
    }

    /// Moves `client` to the back of `cut`, returning whether it is new there.
    static func mark(_ cut: inout [String], _ client: String) -> Bool {
        let new = !cut.contains(client)
        cut.removeAll { $0 == client }
        cut.append(client)
        return new
    }

    /// Clients whose `player` request failed for a song a later client then played, by when: they are asked after the
    /// rest for `demotedFor`, rather than costing every song a round trip.
    private static let failedClients = Mutex<[String: ContinuousClock.Instant]>([:])
    static let demotedFor: Duration = .seconds(10 * 60)

    /// The clients not cut off, then those that are, refused longest ago first: one may still resolve a song the
    /// others refuse, and a download walking on from refusal to refusal reaches each before coming back to any. Of
    /// those not cut off, ones `failed` within `demotedFor` go after the rest, failed longest ago first.
    static func clients(
        cut: [String], failed: [String: ContinuousClock.Instant] = [:], at now: ContinuousClock.Instant = .now
    ) -> [ClientProfile] {
        let all = ClientProfile.plainStreamClients
        let open = all.filter { !cut.contains($0.name) }
        let demoted = { (client: ClientProfile) in failed[client.name].flatMap { now - $0 < Self.demotedFor ? $0 : nil } }
        let sunk = open.compactMap { client in demoted(client).map { (client, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        return open.filter { demoted($0) == nil } + sunk + cut.compactMap { name in all.first { $0.name == name } }
    }

    /// After a pass that `played` with one client, the ones asked before it that failed are demoted and it is not. A
    /// pass where all fail says nothing of any one client: the song, the visitor ID or the network failed.
    static func record(_ failed: inout [String: ContinuousClock.Instant], failing: [String], played: String, at now: ContinuousClock.Instant) {
        failed = failed.filter { now - $0.value < demotedFor }
        for name in failing { failed[name] = now }
        failed[played] = nil
    }

    /// YouTube sometimes bot-checks a visitor ID, so when every client fails they are asked once more with a fresh one,
    /// kept only if it works. With `itag`, that format only.
    func resolve(videoId: String, maxKbps: Int?, itag: Int? = nil) async throws -> ResolvedStream {
        let visitor = try await innerTube.visitorData()
        do {
            return try await resolveWithClients(videoId: videoId, maxKbps: maxKbps, itag: itag, visitorData: visitor)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fresh = try await innerTube.candidateVisitorData(replacing: visitor)
            let stream = try await resolveWithClients(videoId: videoId, maxKbps: maxKbps, itag: itag, visitorData: fresh)
            await innerTube.adoptVisitorData(fresh, replacing: visitor)
            return stream
        }
    }

    /// Fails with the first client's reason, as the first is the usual one.
    private func resolveWithClients(videoId: String, maxKbps: Int?, itag: Int?, visitorData: String) async throws -> ResolvedStream {
        var firstError: (any Error)?
        var failing: [String] = []
        for client in Self.clients(cut: Self.cutOffClients.withLock { $0 }, failed: Self.failedClients.withLock { $0 }) {
            do {
                let stream = try await resolve(videoId: videoId, as: client, maxKbps: maxKbps, itag: itag, visitorData: visitorData)
                // A client without one format isn't broken, so a refresh for an itag demotes none.
                if itag == nil, !failing.isEmpty {
                    Self.failedClients.withLock { Self.record(&$0, failing: failing, played: client.name, at: .now) }
                }
                return stream
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                failing.append(client.name)
            }
        }
        throw firstError ?? Self.noAudio
    }

    func resolve(
        videoId: String, as client: ClientProfile, maxKbps: Int?, itag: Int? = nil, visitorData: String? = nil
    ) async throws -> ResolvedStream {
        var stream = try Self.stream(
            in: await player(videoId: videoId, as: client, visitorData: visitorData),
            userAgent: client.userAgent, maxKbps: maxKbps, itag: itag
        )
        stream.client = client.name
        return stream
    }

    /// Asked signed out, with `visitorData` or else the saved visitor ID.
    func player(videoId: String, as client: ClientProfile, visitorData: String? = nil) async throws -> JSON {
        // Not retried: the next client is the retry, so a broken one costs a request rather than the song.
        try await innerTube.post(
            "player",
            body: ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true],
            client: client,
            authenticated: false,
            visitorData: visitorData,
            retries: 0
        )
    }

    /// The best plain-URL stream, or with `itag`, that one. A client that answers with scrambled URLs only has none.
    static func stream(in json: JSON, userAgent: String, maxKbps: Int?, itag: Int? = nil) throws -> ResolvedStream {
        let response = try PlayerResponse(json: json)
        let chosen = if let itag {
            response.formats.first { $0.itag == itag && $0.url != nil && $0.isPlain }
        } else {
            bestAudio(response.formats, maxKbps: maxKbps)
        }
        guard let format = chosen,
              let url = format.url.flatMap(URL.init(string:)), HTTP.isAllowed(url)
        else { throw noAudio }
        return makeStream(format, url: url, userAgent: userAgent, response: response, isPremium: false)
    }

    static let noAudio = YTMError(.unplayable, "YouTube offered no audio the app can play.")
}
