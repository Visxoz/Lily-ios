import Foundation

extension YTMusic {
    /// YouTube's lyrics, or another site's better ones that agree with them. Nil when there are none.
    /// Only YouTube's failure throws, so the song is asked again rather than shown unchecked.
    @concurrent
    public func lyrics(for song: Track) async throws -> Lyrics? {
        // A music video's timing is its own, which other sites' songs needn't share.
        guard !song.isVideo else { return try await youtubeLyrics(videoId: song.id) }
        let (track, next) = try await withLength(song)
        async let sites = Self.otherSites(for: track)
        let own = try await youtubeLyrics(videoId: track.id, next: next)
        let found = await sites
        var apple = found.apple.compactMap { Lyrics.checked($0, against: own) }
        var others = found.others.compactMap { Lyrics.checked($0, against: own) }
        let agreed = apple + others
        // KuGou is slow and often has another version, so it's asked only for word timing the rest lack, where
        // YouTube's lyrics can vouch for it. The hub's KuGou lyrics are timed by the line alone.
        let wantsWords = own != nil && !agreed.contains(where: \.isWordSynced)
        // LRCLIB only for timing YouTube's lyrics lack, unless the hub asked it already.
        let wantsLines = own?.isSynced != true && !found.answered.contains("lrclib") && !agreed.contains(where: \.isSynced)
        // The hub stops at word timing before checking it, so when that disagreed before lrc.red answered, it's
        // asked here.
        let wantsLrcRed = wantsWords && !found.answered.contains("binimum")
        // Held to a few seconds, as the lyrics wait on them; LRCLIB's may take a search after a miss.
        async let kugou = wantsWords ? LyricsSite.within(.seconds(4)) { try await KuGou.lyrics(for: track) } : nil
        async let lrclib = wantsLines ? LyricsSite.within(.seconds(7)) { try await LRCLIB.lyrics(for: track) } : nil
        async let lrcRed = wantsLrcRed ? LyricsSite.within(.seconds(4)) { try await LrcRed.lyrics(for: track) } : nil
        others += await [kugou, lrclib].compactMap { Lyrics.checked($0, against: own) }
        if let late = Lyrics.checked(await lrcRed, against: own) { apple.append(late) }
        // The other sites fold a cancellation into nil, which mustn't pass for their having none.
        try Task.checkCancellation()
        return Lyrics.chosen(youtube: own, apple: apple, others: others)
    }

    /// The track with its length, which every other site's search and match need but home tiles and quick picks
    /// don't give, and YouTube's answer for the song when the length had to be read from its queue.
    private func withLength(_ track: Track) async throws -> (Track, JSON?) {
        guard track.duration == nil else { return (track, nil) }
        let next = try await innerTube.next(["videoId": track.id], authenticated: false)
        var known = track
        known.duration = (try? Renderers.queue(in: next))?.first { $0.id == track.id }?.duration
        return (known, next)
    }

    /// The hub's lyrics, and lrc.red's when the hub has no word timing of Apple Music's kind. Neither waits on
    /// YouTube's, so both run alongside them.
    private static func otherSites(for track: Track) async -> LyricsHub.Found {
        var found = await LyricsHub.lyrics(for: track) ?? LyricsHub.Found()
        guard !found.apple.contains(where: \.isWordSynced), !hubMissedLrcRed(found, for: track) else { return found }
        if let lrcRed = try? await LrcRed.lyrics(for: track) { found.apple.append(lrcRed) }
        // Its own answer stands for the hub's, so it isn't asked again once YouTube's lyrics are in.
        found.answered.insert("binimum")
        return found
    }

    /// The hub's binimum is lrc.red, so its having nothing is lrc.red's answer, unless lrc.red would be asked under
    /// other names than the hub was.
    static func hubMissedLrcRed(_ found: LyricsHub.Found, for track: Track) -> Bool {
        found.answered.contains("binimum") && !found.apple.contains { $0.source == LrcRed.source } && LrcRed.searchesAsGiven(track)
    }

    /// Timed lines as the Android app is given them, else the web client's block of text. Nil when the song has none.
    /// `fetched` is YouTube's answer for the song when it was already asked.
    private func youtubeLyrics(videoId: String, next fetched: JSON? = nil) async throws -> Lyrics? {
        let next = if let fetched { fetched } else { try await innerTube.next(["videoId": videoId], authenticated: false) }
        guard let browseId = Lyrics.browseId(in: next) else { return nil }
        do {
            // Not retried: the web lyrics are the fallback.
            let android = try await innerTube.post(
                "browse", body: ["browseId": browseId], client: .androidMusic, authenticated: false, retries: 0
            )
            if let timed = Lyrics(timed: android) { return timed }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The web client's lyrics follow, which are the same words.
        }
        return try Lyrics(plain: await innerTube.browse(browseId, authenticated: false))
    }
}

extension Lyrics {
    /// Word timing, Apple Music's kind first; then timed lines, Apple Music's kind, YouTube's, then the others';
    /// then YouTube's text, or any. The other sites' have passed `checked`, and come best first.
    static func chosen(youtube own: Lyrics?, apple: [Lyrics], others: [Lyrics]) -> Lyrics? {
        let timed = (apple + others).first(where: \.isWordSynced)
            ?? (apple + [own].compactMap(\.self) + others).first(where: \.isSynced)
        return timed ?? own ?? others.first ?? apple.first
    }

    /// Another site's lyrics where they agree with YouTube's, which are always the recording playing, or where
    /// YouTube has none to hold them to.
    static func checked(_ other: Lyrics?, against own: Lyrics?) -> Lyrics? {
        guard let other, let own else { return other }
        return LyricsMatch.agrees(own, other) ? other : nil
    }

    /// The Lyrics tab's browse ID, which a song without lyrics leaves out.
    static func browseId(in next: JSON) -> String? {
        Renderers.watchNextTabs(next).lazy.compactMap { tab -> String? in
            let endpoint = tab["endpoint"]
            guard Renderers.pageType(endpoint) == "MUSIC_PAGE_TYPE_TRACK_LYRICS" else { return nil }
            return endpoint["browseEndpoint", "browseId"].string
        }.first
    }

    /// Nil when the answer isn't in the shape expected or has no lines. Synced only if every line has its time.
    init?(timed response: JSON) {
        let data = response["contents", "elementRenderer", "newElement", "type", "componentType", "model", "timedLyricsModel", "lyricsData"]
        let timed = data["timedLyricsData"].array
        guard !timed.isEmpty else { return nil }
        var lines: [String] = []
        var starts: [Double] = []
        lines.reserveCapacity(timed.count)
        starts.reserveCapacity(timed.count)
        for line in timed {
            guard let text = line["lyricLine"].string else { return nil }
            lines.append(text)
            if let ms = line["cueRange", "startTimeMilliseconds"].string.flatMap({ UInt64($0) }) {
                starts.append(Double(ms) / 1000)
            }
        }
        self.init(lines: lines, starts: starts.count == lines.count ? starts : [], source: data["sourceMessage"].string ?? "")
    }

    /// Nil when YouTube answers with a message, such as "Lyrics not available", instead.
    init?(plain response: JSON) throws {
        let contents = response["contents"]
        if contents["messageRenderer"].exists { return nil }
        guard let shelf = contents["sectionListRenderer", "contents"].array.lazy
            .map({ $0["musicDescriptionShelfRenderer"] }).first(where: \.exists),
            let body = shelf["description"].text
        else { throw YTMError(.parse, "YouTube's lyrics couldn't be read.") }
        self.init(lines: Self.lines(body), source: shelf["footer"].text ?? "")
    }

    /// Keeps the blank lines between verses; `\r\n` is one break, and a final break ends the last line rather than
    /// starting an empty one.
    static func lines(_ body: String) -> [String] {
        var lines = body.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
