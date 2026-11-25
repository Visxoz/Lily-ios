import Foundation

// Every model is Sendable and Codable: it crosses actors and is saved as is (session, history, the cached Home feed).

public struct ArtistRef: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AlbumRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Track: Codable, Hashable, Sendable, Identifiable {
    /// The video ID.
    public var id: String
    public var title: String
    public var artists: [ArtistRef]
    public var album: AlbumRef?
    /// Length in seconds, when YouTube said.
    public var duration: Int?
    public var thumbnail: String?
    public var trackNumber: Int?
    /// A music video, which may have an audio-only song version YouTube Music plays instead.
    public var isVideo: Bool
    /// The entry's own ID in the account's playlist it was read from, which removing or moving it takes. Never
    /// saved, as it means nothing away from that playlist's page.
    public var setVideoId: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, artists, album, duration, thumbnail, trackNumber, isVideo
    }

    public init(
        id: String, title: String, artists: [ArtistRef] = [], album: AlbumRef? = nil,
        duration: Int? = nil, thumbnail: String? = nil, trackNumber: Int? = nil,
        isVideo: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.thumbnail = thumbnail
        self.trackNumber = trackNumber
        self.isVideo = isVideo
    }

    public var artistNames: String { ArtistRef.joined(artists) }
    public var firstArtistId: String? { artists.lazy.compactMap(\.id).first }
    public var seconds: Double { Double(duration ?? 0) }

    /// Quick with none to match, the usual case, as this runs over whole queues and batches.
    public func isBy(anyOf artists: [ArtistRef]) -> Bool {
        !artists.isEmpty && self.artists.contains { mine in artists.contains(where: mine.matches) }
    }
}

extension ArtistRef {
    public static func joined(_ artists: [ArtistRef]) -> String {
        artists.lazy.map(\.name).joined(separator: ", ")
    }

    /// The same artist by ID or by name, as some rows carry no ID and others an alias or a video uploader's channel.
    public func matches(_ other: ArtistRef) -> Bool {
        if let id, id == other.id { return true }
        return name.caseInsensitiveCompare(other.name) == .orderedSame
    }
}

extension [Track] {
    /// Without `blocked` artists' songs; the same array, uncopied, with none blocked.
    public func leavingOut(_ blocked: [ArtistRef]) -> [Track] {
        blocked.isEmpty ? self : filter { !$0.isBy(anyOf: blocked) }
    }

    /// Leaves out `blocked` artists' songs but the one at `sparing`, answering its new index.
    public func removingSongs(by blocked: [ArtistRef], sparing: Int?) -> (tracks: [Track], index: Int?) {
        guard !blocked.isEmpty else { return (self, sparing) }
        var kept: [Track] = []
        var index: Int?
        for (at, track) in enumerated() where at == sparing || !track.isBy(anyOf: blocked) {
            if at == sparing { index = kept.count }
            kept.append(track)
        }
        return (kept, index)
    }
}

public enum CardKind: String, Codable, Hashable, Sendable {
    case album, playlist, artist, genre
    /// A single song, played with a radio after it.
    case song
}

public struct Card: Codable, Hashable, Sendable, Identifiable {
    public var kind: CardKind
    /// Browse ID of an album or artist, playlist ID, genre params, or the video ID of a song.
    public var id: String
    public var title: String
    public var subtitle: String
    public var thumbnail: String?
    /// Genre chips carry YouTube's colour for them, as 0xRRGGBB.
    public var color: UInt32?
    /// The song a song card plays.
    public var track: Track?

    public init(
        kind: CardKind, id: String, title: String, subtitle: String = "",
        thumbnail: String? = nil, color: UInt32? = nil, track: Track? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnail = thumbnail
        self.color = color
        self.track = track
    }

    /// A song card that plays `track`.
    public init(song track: Track) {
        self.init(
            kind: .song, id: track.id, title: track.title, subtitle: track.artistNames,
            thumbnail: track.thumbnail.map { Thumbnail.resized($0, edge: Thumbnail.card) }, track: track
        )
    }

    /// An album, playlist or artist page as a card, for pinning; nil for other pages, or one without a title yet.
    public init?(pinning route: Route, _ header: PageHeader) {
        let (kind, id): (CardKind, String)
        switch route {
        case .album(let album): (kind, id) = (.album, album)
        case .playlist(let playlist): (kind, id) = (.playlist, playlist)
        // The artist's own ID, as Library's card and its songs name it, should the route be an alias.
        case .artist(let artist): (kind, id) = (.artist, header.artistId ?? artist)
        default: return nil
        }
        guard !header.title.isEmpty else { return nil }
        // A banner stays wide, as the image pipeline asks for it in its own shape.
        let art = header.banner ? header.thumbnail : header.thumbnail.map { Thumbnail.resized($0, edge: Thumbnail.card) }
        self.init(kind: kind, id: id, title: header.title, subtitle: header.subtitle, thumbnail: art)
    }

    /// An artist's card as the artist, for blocking.
    public var artist: ArtistRef? {
        kind == .artist ? ArtistRef(id: id, name: title) : nil
    }

    /// The same song, album, playlist or artist, whichever page's card it is.
    public func matches(_ other: Card) -> Bool {
        kind == other.kind && id == other.id
    }

    /// The page the card opens, if it opens one rather than playing.
    public var route: Route? {
        switch kind {
        case .album: .album(id)
        case .playlist: .playlist(id)
        case .artist: .artist(id)
        case .genre: .genre(id)
        case .song: nil
        }
    }
}

public enum Rating: String, Codable, Hashable, Sendable {
    case none = "INDIFFERENT"
    case like = "LIKE"
    case dislike = "DISLIKE"
}

/// One of the user's playlists, offered by "Save to playlist".
public struct PlaylistOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var thumbnail: String?
    /// The song is in it already.
    public var contains: Bool

    public init(id: String, title: String, thumbnail: String? = nil, contains: Bool = false) {
        self.id = id
        self.title = title
        self.thumbnail = thumbnail
        self.contains = contains
    }
}

public struct Lyrics: Codable, Hashable, Sendable {
    /// A word or syllable as sung, its text keeping any space after it.
    public struct Word: Codable, Hashable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
    }

    public var lines: [String]
    /// Each line's start in seconds when synced, else empty.
    public var starts: [Double]
    /// Each line's words when sung word by word, else empty; a line may still have none.
    public var words: [[Word]]
    /// Each line's translation, "" where it has none; empty without any.
    public var translations: [String]
    /// Each line in Latin letters, likewise.
    public var romanised: [String]
    /// Where they come from, such as "Source: Musixmatch".
    public var source: String

    public init(
        lines: [String], starts: [Double] = [], words: [[Word]] = [], translations: [String] = [],
        romanised: [String] = [], source: String = ""
    ) {
        self.lines = lines
        self.starts = starts
        self.words = words
        self.translations = translations
        self.romanised = romanised
        self.source = source
    }

    public var isSynced: Bool { !starts.isEmpty && starts.count == lines.count }
    public var isWordSynced: Bool { isSynced && words.count == lines.count }
    public var hasTranslations: Bool { !translations.isEmpty && translations.count == lines.count }
    public var isRomanised: Bool { !romanised.isEmpty && romanised.count == lines.count }

    /// The line playing at `time`, for synced lyrics.
    public func lineIndex(at time: Double) -> Int? {
        guard isSynced else { return nil }
        // Binary search: the last start at or before `time`.
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}

public struct Account: Codable, Hashable, Sendable {
    public var name: String
    public var handle: String?
    public var photo: String?

    public init(name: String, handle: String? = nil, photo: String? = nil) {
        self.name = name
        self.handle = handle
        self.photo = photo
    }
}

/// A failure fit to show: a sentence, never a URL or cookie.
public struct YTMError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable {
        case network, http, parse, unplayable, notSignedIn, notFound, refused
    }

    public var kind: Kind
    public var message: String
    /// The HTTP status, when the failure was one.
    public var status: Int?

    public init(_ kind: Kind, _ message: String, status: Int? = nil) {
        self.kind = kind
        self.message = message
        self.status = status
    }

    public var description: String { message }
}

/// The sentence to show for a failure: YTMCore's own words, or the system's.
public func sentence(for error: any Error) -> String {
    (error as? YTMError)?.message ?? error.localizedDescription
}
