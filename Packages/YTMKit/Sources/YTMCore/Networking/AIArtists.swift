import Foundation
import os

/// Artists a community list names as making AI-generated music, kept for a day beside the settings. Nothing is read
/// or fetched until `load` is called.
public enum AIArtists {
    /// A copy this old is asked for again.
    public static let freshFor: Duration = .seconds(24 * 60 * 60)

    /// Kept out of the shared allowlist, so a YouTube response or a redirect can never point at GitHub's user files.
    private static let host = "raw.githubusercontent.com"
    private static let url = URL(string: "https://\(host)/CennoxX/spotify-ai-blocker/main/SpotifyAiArtists.csv")
    /// Ten times the list's size today; the download stops past it, so a bigger body is never held.
    private static let limit = 4 << 20
    /// Fewer is a cut-off or wrong answer, which never replaces a good copy.
    static let minNames = 100
    private static let unread = YTMError(.parse, "The list of AI artists couldn't be read.")
    private static let log = Logger(subsystem: "Lily", category: "AIArtists")

    /// The list, with how long until the next fetch is wanted, zero for a stale copy. Fetched once `ready` returns
    /// unless the kept copy is under a day old, or is any age while none is `held`.
    @concurrent
    public static func load(
        held: Bool, store: FileStore, after ready: @Sendable () async -> Void
    ) async throws -> (listed: ListedArtists, due: Duration) {
        let file = store.aiArtists
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let due = dueAfter(GoogleAuth.due(after: modified, now: .now, every: freshFor))
        if due != nil || !held, let csv = try? Data(contentsOf: file), let listed = parse(csv) {
            return (listed, due ?? .zero)
        }
        guard let url else { throw unread }
        await ready()
        // A load replaced or switched off while waiting never starts its fetch.
        try Task.checkCancellation()
        let bytes = try await HTTP.bytes(for: URLRequest(url: url), allowing: host)
        // Ends the download when reading stops early.
        defer { bytes.task.cancel() }
        guard let csv = try await HTTP.body(of: bytes, limit: limit), let listed = parse(csv) else { throw unread }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try csv.write(to: file, options: .atomic)
        } catch {
            log.error("ai-artists.csv could not be saved: \(error.localizedDescription, privacy: .public)")
        }
        return (listed, freshFor)
    }

    /// With no timer, a copy within a minute of lapsing is fetched now rather than at the next return to the app.
    static func dueAfter(_ left: Duration) -> Duration? {
        left > .seconds(60) ? left : nil
    }

    static func parse(_ csv: Data) -> ListedArtists? {
        let listed = ListedArtists(names(String(decoding: csv, as: UTF8.self)))
        return listed.count >= minNames ? listed : nil
    }

    /// `artist,id` lines under a header, the ID Spotify's; split at the last comma, as a name may hold one. By
    /// scalar, so a CRLF line's `\r` falls in its ID.
    static func names(_ csv: String) -> some Sequence<Substring> {
        csv.unicodeScalars.split(separator: "\n").dropFirst().lazy.compactMap { line in
            guard let comma = line.lastIndex(of: ","),
                  let first = line[..<comma].firstIndex(where: { !$0.properties.isWhitespace }),
                  let last = line[..<comma].lastIndex(where: { !$0.properties.isWhitespace })
            else { return nil }
            return Substring(line[first...last])
        }
    }
}
